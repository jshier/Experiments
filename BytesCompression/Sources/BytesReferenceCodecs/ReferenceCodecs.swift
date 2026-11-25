public import Compression
internal import zlib

// The SDK's codecs as references for differential tests and comparison benchmarks: zlib's DEFLATE and Apple's
// Compression, through their one-shot buffer APIs. Not tuned: they copy their inputs and outputs.

/// zlib's DEFLATE, in its three containers.
public enum Zlib {
    /// A DEFLATE container: zlib's `windowBits` for it.
    public enum Container: Sendable {
        /// Raw DEFLATE (RFC 1951): `windowBits` -15.
        case raw
        /// zlib (RFC 1950): 15.
        case zlib
        /// gzip (RFC 1952): 31.
        case gzip

        /// zlib's `windowBits` for the container, with the largest window.
        public var windowBits: Int32 {
            switch self {
            case .raw: -MAX_WBITS
            case .zlib: MAX_WBITS
            case .gzip: MAX_WBITS + 16
            }
        }
    }

    /// zlib's default level (6).
    public static let defaultLevel: Int32 = Z_DEFAULT_COMPRESSION
    /// zlib's default strategy.
    public static let defaultStrategy: Int32 = Z_DEFAULT_STRATEGY
    /// Huffman coding only, no matches (`Z_HUFFMAN_ONLY`).
    public static let huffmanOnlyStrategy: Int32 = Z_HUFFMAN_ONLY
    /// Matches of distance 1 only (`Z_RLE`).
    static let rleStrategy: Int32 = Z_RLE
    /// Fixed Huffman codes only (`Z_FIXED`).
    public static let fixedStrategy: Int32 = Z_FIXED
    /// More Huffman coding, fewer matches (`Z_FILTERED`).
    static let filteredStrategy: Int32 = Z_FILTERED

    /// zlib's encoding of `data`, in one call.
    ///
    /// - Parameters:
    ///   - data: The bytes.
    ///   - windowBits: zlib's `windowBits`: the container and window size (``Container/windowBits``).
    ///   - level: 0 through 9, or ``defaultLevel``.
    ///   - strategy: ``defaultStrategy`` or another strategy.
    /// - Returns: The stream.
    public static func compress(
        _ data: [UInt8], windowBits: Int32 = Container.raw.windowBits, level: Int32 = defaultLevel,
        strategy: Int32 = defaultStrategy
    ) -> [UInt8] {
        var stream = z_stream()
        precondition(deflateInit2_(&stream, level, Z_DEFLATED, windowBits, 8, strategy, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(data.count))) + 64)
        var input = data
        let status = input.withUnsafeMutableBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                stream.next_in = input.baseAddress
                stream.avail_in = uInt(input.count)
                stream.next_out = output.baseAddress
                stream.avail_out = uInt(output.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        precondition(status == Z_STREAM_END)
        return Array(output[..<Int(stream.total_out)])
    }

    /// A sync flush (`Z_SYNC_FLUSH`): the block ends, and an empty stored block aligns the stream to a byte.
    static let syncFlush: Int32 = Z_SYNC_FLUSH
    /// A full flush (`Z_FULL_FLUSH`): a sync flush that also forgets the history, so what follows decodes alone.
    package static let fullFlush: Int32 = Z_FULL_FLUSH

    /// zlib's encoding of `data` as one stream, flushed after every `every` bytes of input.
    ///
    /// - Parameters:
    ///   - data: The bytes.
    ///   - windowBits: zlib's `windowBits`: the container and window size.
    ///   - level: 0 through 9, or ``defaultLevel``.
    ///   - every: The input between flushes.
    ///   - flushes: The flush after each piece, in turn (``syncFlush``, ``fullFlush``); the last piece finishes.
    /// - Returns: The stream.
    public static func compress(
        _ data: [UInt8], windowBits: Int32 = Container.raw.windowBits, level: Int32 = defaultLevel, flushingEvery every: Int,
        flushes: [Int32]
    ) -> [UInt8] {
        var stream = z_stream()
        precondition(deflateInit2_(&stream, level, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(data.count))) + (data.count / every + 1) * 16)
        var input = data
        var produced = 0
        input.withUnsafeMutableBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                var offset = 0
                var piece = 0
                repeat {
                    let end = min(offset + every, input.count)
                    stream.next_in = input.baseAddress.map { $0 + offset }
                    stream.avail_in = uInt(end - offset)
                    stream.next_out = output.baseAddress! + produced
                    stream.avail_out = uInt(output.count - produced)
                    let flush = end == input.count ? Z_FINISH : flushes[piece % flushes.count]
                    let status = deflate(&stream, flush)
                    precondition(status == (flush == Z_FINISH ? Z_STREAM_END : Z_OK) && stream.avail_in == 0)
                    produced = output.count - Int(stream.avail_out)
                    offset = end
                    piece += 1
                } while offset < input.count
            }
        }
        return Array(output[..<produced])
    }

    /// zlib's decoding of `data`, which must be one whole stream with nothing after it.
    ///
    /// - Parameters:
    ///   - data: The stream.
    ///   - windowBits: zlib's `windowBits` for its container.
    /// - Returns: The bytes, or `nil` if the stream is invalid, truncated, or followed by more bytes.
    public static func decompress(_ data: [UInt8], windowBits: Int32 = Container.raw.windowBits) -> [UInt8]? {
        var stream = z_stream()
        precondition(inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        defer { inflateEnd(&stream) }
        var result: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        var input = data
        return input.withUnsafeMutableBufferPointer { input in
            stream.next_in = input.baseAddress
            stream.avail_in = uInt(input.count)
            while true {
                let (status, produced) = chunk.withUnsafeMutableBufferPointer { output in
                    stream.next_out = output.baseAddress
                    stream.avail_out = uInt(output.count)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    return (status, output.count - Int(stream.avail_out))
                }
                result += chunk[..<produced]
                switch status {
                case Z_STREAM_END: return stream.avail_in == 0 ? result : nil
                case Z_OK: continue
                default: return nil // Including Z_BUF_ERROR: truncated.
                }
            }
        }
    }

    /// zlib's decoding of a gzip file of one member or more (RFC 1952 §2.2), member by member as `gunzip` does: after
    /// each member's end, `inflateReset` and on with the next.
    ///
    /// - Parameter data: The members, end to end, and nothing else.
    /// - Returns: The members' bytes, or `nil` if a member is invalid or truncated, or bytes after one don't start
    ///   another.
    package static func decompressMembers(_ data: [UInt8]) -> [UInt8]? {
        var stream = z_stream()
        precondition(inflateInit2_(&stream, Container.gzip.windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        defer { inflateEnd(&stream) }
        var result: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        var input = data
        return input.withUnsafeMutableBufferPointer { input in
            stream.next_in = input.baseAddress
            stream.avail_in = uInt(input.count)
            while true {
                let (status, produced) = chunk.withUnsafeMutableBufferPointer { output in
                    stream.next_out = output.baseAddress
                    stream.avail_out = uInt(output.count)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    return (status, output.count - Int(stream.avail_out))
                }
                result += chunk[..<produced]
                switch status {
                case Z_STREAM_END:
                    if stream.avail_in == 0 { return result }
                    inflateReset(&stream) // Another member.
                case Z_OK: continue
                default: return nil // Including Z_BUF_ERROR: truncated.
                }
            }
        }
    }
}

/// Apple's Compression, through its buffer API (`compression_encode_buffer`, `compression_decode_buffer`).
public enum AppleCompression {
    /// Raw LZVN: `compression_encode_buffer`'s undocumented algorithm 0x900 (APFS `decmpfs` type 8).
    package static let lzvnRaw = compression_algorithm(rawValue: 0x900)

    /// Compression's encoding of `data` with `algorithm`, given room for any input.
    ///
    /// - Parameters:
    ///   - data: The bytes.
    ///   - algorithm: The codec.
    /// - Returns: The stream. Traps if Compression fails.
    public static func encode(_ data: [UInt8], _ algorithm: compression_algorithm) -> [UInt8] {
        let result = encode(data, algorithm, capacity: data.count + data.count / 8 + 4096)
        precondition(result != nil || data.isEmpty, "compression_encode_buffer failed")
        return result ?? []
    }

    /// Compression's encoding of `data` with `algorithm` into exactly `capacity` bytes of room.
    ///
    /// - Parameters:
    ///   - data: The bytes.
    ///   - algorithm: The codec.
    ///   - capacity: The room it gets (an encoder's output can depend on it).
    ///   - scratch: A scratch buffer of `compression_encode_scratch_buffer_size(algorithm)` bytes, or `nil` for
    ///     Compression to allocate one.
    /// - Returns: The stream, or `nil` where Compression fails (returns 0).
    public static func encode(
        _ data: [UInt8], _ algorithm: compression_algorithm, capacity: Int, scratch: UnsafeMutableRawPointer? = nil
    ) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: max(capacity, 1))
        let size = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { output in
                compression_encode_buffer(
                    output.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                    (input.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!).assumingMemoryBound(to: UInt8.self), input.count,
                    scratch, algorithm
                )
            }
        }
        return size == 0 ? nil : Array(output[..<size])
    }

    /// Compression's decoding of `data` into at most `capacity` bytes. (Its buffer API stops when the output is
    /// full and returns that count, so a stream missing its end still "decodes"; 0 is its only failure.)
    ///
    /// - Parameters:
    ///   - data: The stream.
    ///   - capacity: The most bytes to decode.
    ///   - algorithm: The codec.
    /// - Returns: The bytes Compression produced (none if it failed).
    public static func decode(_ data: [UInt8], capacity: Int, _ algorithm: compression_algorithm) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: max(capacity, 1))
        let size = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { output in
                compression_decode_buffer(
                    output.baseAddress!.assumingMemoryBound(to: UInt8.self), output.count,
                    (input.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!).assumingMemoryBound(to: UInt8.self), input.count,
                    nil, algorithm
                )
            }
        }
        return Array(output[..<size])
    }
}
