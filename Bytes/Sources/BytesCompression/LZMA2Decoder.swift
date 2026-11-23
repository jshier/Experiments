public import Bytes

/// An LZMA stream's parameters: the literal context bits (lc), literal position bits (lp), position bits (pb),
/// and dictionary size.
///
/// ```swift
/// let properties = try LZMAProperties(byte: 0x5D, dictionarySize: 1 << 23)  // lc 3, lp 0, pb 2
/// ```
public struct LZMAProperties: Hashable, Sendable {
    /// lc, 0 to 8: how many high bits of the previous byte select the probabilities for a literal.
    public var literalContextBits: Int
    /// lp, 0 to 4: how many low bits of the position select the probabilities for a literal.
    public var literalPositionBits: Int
    /// pb, 0 to 4: how many low bits of the position select the other probabilities.
    public var positionBits: Int
    /// The farthest a match may reach back, in bytes.
    public var dictionarySize: Int

    /// Creates properties from their values.
    ///
    /// - Throws: ``BytesError/invalidValue`` if lc is above 8, lp or pb above 4, or the dictionary size is
    ///   negative.
    public init(
        literalContextBits: Int = 3, literalPositionBits: Int = 0, positionBits: Int = 2, dictionarySize: Int = 1 << 23
    ) throws(BytesError) {
        guard (0...8).contains(literalContextBits), (0...4).contains(literalPositionBits), (0...4).contains(positionBits),
              dictionarySize >= 0
        else { throw .invalidValue }
        self.literalContextBits = literalContextBits
        self.literalPositionBits = literalPositionBits
        self.positionBits = positionBits
        self.dictionarySize = dictionarySize
    }

    /// Creates properties from the byte that `.lzma` files, ZIP's method 14, and LZMA2 chunks store them in,
    /// `(pb * 5 + lp) * 9 + lc`.
    ///
    /// - Throws: ``BytesError/invalidValue`` for a byte of 225 or more.
    public init(byte: UInt8, dictionarySize: Int) throws(BytesError) {
        guard byte < 9 * 5 * 5, dictionarySize >= 0 else { throw .invalidValue }
        let value = Int(byte)
        literalContextBits = value % 9
        literalPositionBits = value / 9 % 5
        positionBits = value / 45
        self.dictionarySize = dictionarySize
    }

    /// The properties byte, `(pb * 5 + lp) * 9 + lc`.
    public var byte: UInt8 { UInt8((positionBits * 5 + literalPositionBits) * 9 + literalContextBits) }
}

/// An LZMA, LZMA2, and `.xz` decoder: `.xz` files, raw LZMA2 streams, and raw LZMA (`.lzma` files, ZIP's
/// method 14).
///
/// ```swift
/// var decoder = LZMA2Decoder()
/// let consumed = try decoder.decompressXZ(compressed, into: &output)   // every stream, into `output`
/// ```
///
/// Each call decodes a whole stream into the caller's buffer, which is the dictionary: matches copy within it,
/// so any dictionary size works and nothing is allocated for it. The decoder's probability model is allocated
/// once, at creation (raw LZMA with more than 4 literal context and position bits together grows it once). Every
/// call starts a new stream: nothing carries over from earlier calls but that memory.
///
/// The decode loop is `LzmaDec.c`'s design in Swift, with the range decoder in registers: tree bits with
/// conditional selects, decisions with branches, a copy specialized for the default lc 3, lp 0, pb 2, input
/// read without checks while more than a symbol's worth remains, and matches copied 16 bytes at a time while
/// there's room; near the ends of a chunk's input and output, a careful copy of the loop checks every byte.
/// Malformed input throws; it never reads or writes outside the buffers. Single-threaded, it decodes `.xz`
/// files 1.1–1.3x as fast as Apple's Compression and 1.2–1.7x as fast as liblzma 5.8 on Apple silicon
/// (Benchmarks/RESULTS.md, 2026-11-18).
@safe
public struct LZMA2Decoder: ~Copyable {
    var workspace = LZMAWorkspace(count: LZMAProbabilities.count(lc: 4, lp: 0))

    /// Creates a decoder, allocating its probability model.
    public init() {}

    // MARK: Raw LZMA2

    /// Decodes a raw LZMA2 stream, from its first chunk through its end marker (a 0 control byte), into
    /// `output`'s free capacity.
    ///
    /// - Parameters:
    ///   - input: The stream, at its start. Bytes after its end marker are left alone.
    ///   - dictionarySize: The dictionary size the stream was made with (an `.xz` file's filter properties
    ///     say): matches reaching farther are rejected.
    ///   - output: Where to append the decompressed bytes; it needs room for all of them.
    /// - Returns: The number of input bytes decoded, through the end marker.
    /// - Throws: ``BytesError/insufficientData`` if the input ends early; ``BytesError/insufficientCapacity`` if
    ///   the output doesn't fit; ``BytesError/invalidValue`` for corrupt data.
    public mutating func decompressLZMA2(
        _ input: RawSpan, dictionarySize: Int, into output: inout OutputRawSpan
    ) throws(BytesError) -> Int {
        guard input.byteCount > 0 else { throw .insufficientData }
        return try output.withFreeCapacity { span, written throws(BytesError) -> Int in
            try span.withUnsafeMutableBytes { outputBuffer throws(BytesError) -> Int in
                try input.withUnsafeBytes { inputBuffer throws(BytesError) -> Int in
                    // Unsafe: base addresses of the buffers (a placeholder for an empty output, never written).
                    let result = try unsafe decodeLZMA2(
                        inputBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: inputBuffer.count,
                        output: (outputBuffer.baseAddress ?? UnsafeMutableRawPointer(bitPattern: 1)!).assumingMemoryBound(to: UInt8.self),
                        start: 0, capacity: outputBuffer.count, dictionarySize: dictionarySize
                    )
                    written = result.end
                    return result.consumed
                }
            }
        }
    }

    /// Decodes LZMA2 chunks from `input` into `output` from offset `start`.
    ///
    /// - Returns: The input consumed, through the end marker, and the output's new end.
    mutating func decodeLZMA2(
        _ input: UnsafePointer<UInt8>, count: Int, output: UnsafeMutablePointer<UInt8>, start: Int, capacity: Int,
        dictionarySize: Int
    ) throws(BytesError) -> (consumed: Int, end: Int) {
        var registers = LZMARegisters()
        var model = LZMAModel(lc: 0, literalPositionMask: 0, positionMask: 0, dictionarySize: dictionarySize)
        var dictionaryStart = start
        var needsDictionaryReset = true
        var needsProperties = true
        var position = 0
        var end = start

        // Unsafe: reads of the input and copies into the output. Safe: each chunk's header and data are read
        // only after checking that the input holds them, and its output after checking that it fits.
        while true {
            guard position < count else { throw .insufficientData }
            let control = Int(unsafe input[position])
            if control == 0 {
                return (position &+ 1, end)
            }
            if control >= 0xE0 || control == 1 {
                needsProperties = true
                needsDictionaryReset = false
                dictionaryStart = end
                registers.position = 0
            } else if needsDictionaryReset {
                throw .invalidValue
            }
            if control >= 0x80 {
                let headerSize = control >= 0xC0 ? 6 : 5
                guard count &- position >= headerSize else { throw .insufficientData }
                let unpacked = ((control & 0x1F) &<< 16 | Int(unsafe input[position &+ 1]) &<< 8 | Int(unsafe input[position &+ 2])) &+ 1
                let packed = (Int(unsafe input[position &+ 3]) &<< 8 | Int(unsafe input[position &+ 4])) &+ 1
                if control >= 0xC0 {
                    let properties = try LZMAProperties(byte: unsafe input[position &+ 5], dictionarySize: dictionarySize)
                    guard properties.literalContextBits &+ properties.literalPositionBits <= 4 else { throw .invalidValue }
                    model = LZMAModel(properties: properties)
                    needsProperties = false
                    resetState(&registers, model)
                } else if needsProperties {
                    throw .invalidValue
                } else if control >= 0xA0 {
                    resetState(&registers, model)
                }
                position &+= headerSize
                guard packed <= count &- position else { throw .insufficientData }
                guard unpacked <= capacity &- end else { throw .insufficientCapacity }
                try unsafe decodeChunk(
                    input + position, packed: packed, &registers, model: model, dictionary: output + dictionaryStart,
                    limit: registers.position &+ unpacked
                )
                position &+= packed
                end &+= unpacked
            } else {
                guard control <= 2 else { throw .invalidValue }
                guard count &- position >= 3 else { throw .insufficientData }
                let size = (Int(unsafe input[position &+ 1]) &<< 8 | Int(unsafe input[position &+ 2])) &+ 1
                position &+= 3
                guard size <= count &- position else { throw .insufficientData }
                guard size <= capacity &- end else { throw .insufficientCapacity }
                unsafe (output + end).update(from: input + position, count: size)
                position &+= size
                end &+= size
                registers.position &+= size
            }
        }
    }

    /// Sets every probability to one half and the state and distances to their start.
    private func resetState(_ registers: inout LZMARegisters, _ model: LZMAModel) {
        // Unsafe: the model's memory. Safe: the workspace holds the probabilities for lc + lp <= 4 (LZMA2), and
        // raw LZMA grows it first.
        unsafe LZMALoop.resetState(&registers, model, probabilities: workspace.base)
    }

    /// Decodes one LZMA chunk of `packed` bytes into `dictionary` up to position `limit`: it must fill the
    /// chunk exactly, consume its input exactly, and leave the range decoder finished.
    private func decodeChunk(
        _ input: UnsafePointer<UInt8>, packed: Int, _ registers: inout LZMARegisters, model: LZMAModel,
        dictionary: UnsafeMutablePointer<UInt8>, limit: Int
    ) throws(BytesError) {
        // Unsafe and safe as `LZMALoop.decodeChunk`: the caller checked the input and output.
        try unsafe LZMALoop.decodeChunk(
            input, packed: packed, &registers, model: model, dictionary: dictionary, limit: limit, probabilities: workspace.base
        )
    }

    // MARK: Raw LZMA

    /// Decodes a raw LZMA (LZMA1) stream into `output`'s free capacity: the data of a `.lzma` file after its
    /// 13-byte header, or of a ZIP method-14 entry after its 9-byte one.
    ///
    /// - Parameters:
    ///   - input: The stream, starting with the range decoder's first byte. Bytes after its end are left alone.
    ///   - properties: lc, lp, pb, and the dictionary size, from the container.
    ///   - uncompressedSize: The decompressed size, if the container states it; the stream may then end with
    ///     an end marker or without one. With `nil`, it must end with an end marker.
    ///   - output: Where to append the decompressed bytes; it needs room for all of them.
    /// - Returns: The number of input bytes decoded.
    /// - Throws: ``BytesError/insufficientData`` if the input ends early; ``BytesError/insufficientCapacity`` if
    ///   the output doesn't fit; ``BytesError/invalidValue`` for corrupt data, or an end marker before
    ///   `uncompressedSize` bytes.
    public mutating func decompressLZMA(
        _ input: RawSpan, properties: LZMAProperties, uncompressedSize: Int? = nil, into output: inout OutputRawSpan
    ) throws(BytesError) -> Int {
        guard input.byteCount >= 5 else { throw .insufficientData }
        if let uncompressedSize {
            guard uncompressedSize >= 0 else { throw .invalidValue }
            guard uncompressedSize <= output.freeCapacity else { throw .insufficientCapacity }
        }
        let model = LZMAModel(properties: properties)
        workspace.reserve(LZMAProbabilities.count(lc: properties.literalContextBits, lp: properties.literalPositionBits))
        return try output.withFreeCapacity { span, written throws(BytesError) -> Int in
            try span.withUnsafeMutableBytes { outputBuffer throws(BytesError) -> Int in
                try input.withUnsafeBytes { inputBuffer throws(BytesError) -> Int in
                    // Unsafe: base addresses of the buffers (a placeholder for an empty output, never written).
                    let result = try unsafe decodeLZMA(
                        inputBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: inputBuffer.count,
                        output: (outputBuffer.baseAddress ?? UnsafeMutableRawPointer(bitPattern: 1)!).assumingMemoryBound(to: UInt8.self),
                        capacity: outputBuffer.count, model: model, uncompressedSize: uncompressedSize
                    )
                    written = result.end
                    return result.consumed
                }
            }
        }
    }

    private func decodeLZMA(
        _ input: UnsafePointer<UInt8>, count: Int, output: UnsafeMutablePointer<UInt8>, capacity: Int, model: LZMAModel,
        uncompressedSize: Int?
    ) throws(BytesError) -> (consumed: Int, end: Int) {
        var registers = LZMARegisters()
        resetState(&registers, model)
        // Unsafe: the first five bytes (the caller checked there are five), and the input's end.
        guard unsafe input[0] == 0 else { throw .invalidValue }
        let code = unsafe UInt32(input[1]) &<< 24 | UInt32(input[2]) &<< 16 | UInt32(input[3]) &<< 8 | UInt32(input[4])
        var decoder = unsafe LZMARangeDecoder(
            range: 0xFFFF_FFFF, code: code, input: input + 5, end: input + count, probabilities: workspace.base, careful: true
        )
        let limit = uncompressedSize ?? capacity
        let endMarker = try unsafe LZMALoop.decode(
            &registers, &decoder, dictionary: output, limit: limit, model: model, allowsEndMarker: true,
            overrun: uncompressedSize == nil ? .insufficientCapacity : .invalidValue
        )
        if unsafe decoder.input > decoder.end { throw .insufficientData }
        if !endMarker {
            guard registers.position == limit else { throw .insufficientData }
            if uncompressedSize == nil {
                // The output is full: the end marker must be next, or the stream needs more room.
                do throws(BytesError) {
                    try LZMALoop.decodeEndMarker(&registers, &decoder, model: model)
                } catch {
                    throw unsafe decoder.input > decoder.end ? .insufficientData : .insufficientCapacity
                }
                if unsafe decoder.input > decoder.end { throw .insufficientData }
            } else if decoder.code != 0 {
                // The size is reached; the range decoder isn't finished, so an end marker must follow.
                try LZMALoop.decodeEndMarker(&registers, &decoder, model: model)
                if unsafe decoder.input > decoder.end { throw .insufficientData }
            }
        } else if let uncompressedSize, registers.position != uncompressedSize {
            throw .invalidValue
        }
        guard decoder.code == 0 else { throw .invalidValue }
        return unsafe (decoder.input - input, registers.position)
    }

    /// Decodes a `.lzma` file (LZMA-Alone, what `xz --format=lzma` and the LZMA SDK's `lzma` write): a
    /// 13-byte header (the properties byte, the dictionary size, and the decompressed size or all ones for
    /// none), then a raw LZMA stream.
    ///
    /// - Returns: The number of input bytes decoded.
    /// - Throws: As ``decompressLZMA(_:properties:uncompressedSize:into:)``.
    public mutating func decompressLZMAFile(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> Int {
        guard input.byteCount >= 13 else { throw .insufficientData }
        let dictionarySize = Int(UInt32(littleEndian: unsafe input.unsafeLoadUnaligned(fromByteOffset: 1, as: UInt32.self)))
        let properties = try LZMAProperties(byte: input.load(fromByteOffset: 0, as: UInt8.self), dictionarySize: dictionarySize)
        let size = UInt64(littleEndian: unsafe input.unsafeLoadUnaligned(fromByteOffset: 5, as: UInt64.self))
        let uncompressedSize: Int?
        if size == .max {
            uncompressedSize = nil
        } else {
            guard size <= UInt64(Int.max) else { throw .insufficientCapacity }
            uncompressedSize = Int(size)
        }
        return try 13 + decompressLZMA(
            input.extracting(13...), properties: properties, uncompressedSize: uncompressedSize, into: &output
        )
    }
}

// It owns its memory (no references are shared), and being `~Copyable`, only one owner can use it.
extension LZMA2Decoder: @unchecked Sendable {}

/// The decoder's probability model, allocated once, growing only for raw LZMA's larger literal contexts.
@safe @usableFromInline // Exported for clients' destroys, as `ZstdWorkspace`.
struct LZMAWorkspace: ~Copyable {
    private var memory: CodecWorkspace
    private(set) var count: Int

    init(count: Int) {
        memory = Self.allocate(count)
        self.count = count
    }

    /// The probabilities.
    var base: UnsafeMutablePointer<UInt16> {
        // Unsafe: the allocation as `UInt16`s. Safe: it holds `count` of them, initialized by `allocate`.
        unsafe memory.base.assumingMemoryBound(to: UInt16.self)
    }

    /// Makes room for at least `count` probabilities.
    mutating func reserve(_ count: Int) {
        guard count > self.count else { return }
        memory = Self.allocate(count)
        self.count = count
    }

    /// `count` probabilities, each at its initial value.
    private static func allocate(_ count: Int) -> CodecWorkspace {
        let memory = CodecWorkspace(byteCount: count &* 2, zeroed: false)
        // Unsafe: initializing fresh memory. Safe: it holds `count` `UInt16`s; the top slot is below `count`.
        let base = unsafe memory.base.initializeMemory(as: UInt16.self, repeating: LZMAProbabilities.initial, count: count)
        unsafe base[LZMAProbabilities.topSlot] = LZMAProbabilities.topValue
        return memory
    }
}
