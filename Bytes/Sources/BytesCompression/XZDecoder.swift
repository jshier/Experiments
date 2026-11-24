public import Bytes

/// An `.xz` decoder that streams: ZIP's method 95, `.xz` files of any size in bounded memory.
///
/// ```swift
/// var decoder = XZDecoder()
/// let progress = try decoder.decompress(compressed, into: &output)   // as much as fits; call again for more
/// decoder.reset()                                                     // the next file
/// ```
///
/// Checks everything ``LZMA2Decoder/decompressXZ(_:into:)`` does: stream headers, footers, block headers, and
/// indexes (their CRC-32s, each block's sizes against its header and the index, the footer against the
/// header), and each block's CRC-32 or CRC-64 of its content (SHA-256 checks are read, not verified). A file may
/// hold several streams, with stream padding between them. Blocks must use the LZMA2 filter alone.
///
/// The decoder works a unit at a time: a header, an LZMA2 chunk, a block's check, an index record. A unit is
/// decoded once all of it is in the input; until then, ``decompress(_:into:)`` consumes nothing more and asks
/// for input. The largest unit is an LZMA2 chunk, 65,542 bytes (``maximumUnitByteCount``), so a caller that
/// passes back what wasn't consumed, followed by more, needs that much room; passing the whole rest of the
/// file every time works as well. Chunks decode into a dictionary window the decoder owns, allocated when a block
/// starts at the block's dictionary (or its size, when its header states that, or the file's size hint from
/// ``reset(sizeHint:)``, whichever is smallest) plus room (as large as the dictionary up to `windowRoomLimit`,
/// and at least a chunk's 2 MiB), and kept across resets; only the pages the output reaches become resident.
///
/// The decode loops are ``LZMA2Decoder``'s, unchanged; decoding streams costs under 1% more instructions than
/// ``LZMA2Decoder/decompressXZ(_:into:)``, which decodes into the caller's whole output.
@safe
public struct XZDecoder: ~Copyable {
    /// The default ``maximumDictionarySize``: 256 MiB, four times what `xz -9` uses.
    public static var defaultMaximumDictionarySize: Int { LZMADecoder.defaultMaximumDictionarySize }

    /// The most dictionary the window keeps. A block whose dictionary is larger decodes until its output
    /// outgrows this plus the window's room (2 MiB or more), then throws ``BytesError/insufficientCapacity``.
    public let maximumDictionarySize: Int

    /// As `LZMADecoder.windowRoomLimit`: the most room the window keeps beyond the dictionary (it keeps at least
    /// a chunk's 2 MiB whatever this is).
    package var windowRoomLimit = LZMAWindow.defaultRoomLimit

    /// The file's decompressed size, if known: no window is larger.
    private var sizeHint: Int?

    private var workspace = LZMAWorkspace(count: LZMAProbabilities.count(lc: 4, lp: 0))
    var window = LZMAWindow()
    private var registers = LZMARegisters()
    private var model = LZMAModel(lc: 0, literalPositionMask: 0, positionMask: 0, dictionarySize: 0)
    private var stage = Stage.streamHeader
    private var failure: BytesError?

    // The stream.
    private var checkType = 0
    private var blocks = XZIndexSummary()
    // The block.
    private var block = Block()
    // The index.
    private var listed = XZIndexSummary()
    private var indexRemaining = 0
    private var indexSize = 0
    private var indexCRC = CRC32()

    private enum Stage {
        case streamHeader
        /// A block header, or the index's indicator.
        case blockStart
        case chunk
        /// A block's padding and check.
        case blockEnd
        case indexCount
        case indexRecords
        /// The index's padding and CRC-32.
        case indexEnd
        case footer
        /// After a stream: padding, another stream, or the end.
        case streamPadding
    }

    /// The current block's header and progress.
    private struct Block {
        var headerSize = 0
        var compressedSize: Int?
        var uncompressedSize: Int?
        var dictionarySize = 0
        /// LZMA2 bytes so far.
        var compressed = 0
        var uncompressed = 0
        var needsDictionaryReset = true
        var needsProperties = true
        var crc32 = CRC32()
        var crc64 = CRC64()
    }

    /// Creates a decoder, allocating its probability model.
    ///
    /// - Parameter maximumDictionarySize: The most dictionary the window may keep.
    public init(maximumDictionarySize: Int = XZDecoder.defaultMaximumDictionarySize) {
        self.maximumDictionarySize = maximumDictionarySize
    }

    /// Prepares to decode a new file, discarding output not yet delivered. Keeps the allocations, and the last
    /// ``reset(sizeHint:)``'s hint.
    public mutating func reset() {
        stage = .streamHeader
        failure = nil
        registers.position = 0
        window.restart()
    }

    /// Prepares to decode a new file whose decompressed size the container records (zip does), discarding output
    /// not yet delivered.
    ///
    /// - Parameter sizeHint: The file's decompressed size, or `nil` if unknown. No block's window is made larger (one
    ///   an earlier file made larger stays), so a small file with a large dictionary costs only its size. A file that
    ///   outgrows a window smaller than its dictionary throws ``BytesError/insufficientCapacity``.
    public mutating func reset(sizeHint: Int?) {
        self.sizeHint = sizeHint.map { max($0, 0) }
        reset()
    }

    /// Whether the decoder is after a stream's end, with all its output delivered: the file may end here, or
    /// stream padding or another stream may follow.
    public var isFinished: Bool { stage == .streamPadding && window.delivered == registers.position }

    /// The most unconsumed input a call may need before it can make progress: the largest LZMA2 chunk, 6 bytes of
    /// header and 64 KiB of data.
    public static var maximumUnitByteCount: Int { 6 &+ 65_536 }

    /// Decodes as much of `input` as it can, appending to `output`, continuing the current file.
    ///
    /// Output can be split anywhere; input at unit boundaries (see ``XZDecoder``): a unit only partly in `input`
    /// isn't consumed, so pass the rest again, followed by more.
    ///
    /// - Parameters:
    ///   - input: The next compressed bytes, starting with any not consumed last time.
    ///   - output: Where to append decompressed bytes.
    /// - Returns: What was consumed and produced, and why it returned: ``TransformStatus/finished`` after a
    ///   stream's footer (and any stream padding) with all of `input` consumed and all output delivered (another
    ///   stream may follow). A file cut short keeps asking for input.
    /// - Throws: ``BytesError/mismatch`` for a wrong CRC, check, or size; ``BytesError/invalidValue`` for corrupt
    ///   data, bytes that aren't a stream, or an unsupported filter or check type; ``BytesError/insufficientData``
    ///   for a block header whose fields run past its end; ``BytesError/insufficientCapacity`` for a dictionary
    ///   larger than ``maximumDictionarySize`` once it's needed. After an error, every call throws it until the
    ///   next ``reset()``.
    public mutating func decompress(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> TransformProgress {
        if let failure { throw failure }
        do throws(BytesError) {
            return try step(input, into: &output)
        } catch {
            failure = error
            throw error
        }
    }

    /// The streaming loop over `input`.
    private mutating func step(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> TransformProgress {
        var position = 0
        var produced = 0
        let count = input.byteCount
        // Each unit is read only after checking that the input holds all of it (`available`), through checked
        // loads; the window is written after making room.
        while true {
            produced &+= window.deliver(upTo: registers.position, into: &output)
            guard window.delivered == registers.position else {
                return TransformProgress(consumed: position, produced: produced, status: .needsOutput)
            }
            let available = count &- position
            let needsInput = TransformProgress(consumed: position, produced: produced, status: .needsInput)
            if available == 0 {
                let status: TransformStatus = stage == .streamPadding ? .finished : .needsInput
                return TransformProgress(consumed: position, produced: produced, status: status)
            }
            let bytes = input.extracting(droppingFirst: position)
            switch stage {
            case .streamHeader:
                guard available >= XZ.headerSize else {
                    try XZ.checkHeaderPrefix(bytes)
                    return needsInput
                }
                checkType = try XZ.streamHeader(bytes)
                position &+= XZ.headerSize
                blocks = XZIndexSummary()
                stage = .blockStart

            case .blockStart:
                let sizeByte = Int(bytes.load(fromByteOffset: 0, as: UInt8.self))
                if sizeByte == 0 {
                    // The index's indicator.
                    indexCRC = CRC32()
                    indexCRC.update(bytes.extracting(first: 1))
                    indexSize = 1
                    position &+= 1
                    stage = .indexCount
                    continue
                }
                let headerSize = (sizeByte &+ 1) &* 4
                guard available >= headerSize else { return needsInput }
                let header = try XZ.blockHeader(bytes, headerSize: headerSize)
                position &+= headerSize
                block = Block(
                    headerSize: headerSize, compressedSize: header.compressedSize, uncompressedSize: header.uncompressedSize,
                    dictionarySize: header.dictionarySize
                )
                registers.position = 0
                let knownSize = switch (header.uncompressedSize, sizeHint) {
                case let (size?, hint?): min(size, hint)
                case let (size, hint): size ?? hint
                }
                window.start(
                    dictionarySize: max(header.dictionarySize, LZMAModel.minimumDictionarySize), knownSize: knownSize,
                    // Room for the largest chunk (2 MiB), which decodes whole, after a slide (which keeps up to 63
                    // bytes more than the dictionary).
                    maximumDictionarySize: maximumDictionarySize, minimumRoom: (2 << 20) &+ 64, roomLimit: windowRoomLimit
                )
                stage = .chunk

            case .chunk:
                let control = Int(bytes.load(fromByteOffset: 0, as: UInt8.self))
                if control == 0 {
                    position &+= 1
                    block.compressed &+= 1
                    if let size = block.compressedSize, block.compressed != size { throw .mismatch }
                    if let size = block.uncompressedSize, block.uncompressed != size { throw .mismatch }
                    stage = .blockEnd
                    continue
                }
                let resetsDictionary = control >= 0xE0 || control == 1
                if !resetsDictionary && block.needsDictionaryReset { throw .invalidValue }
                let needsProperties = resetsDictionary || block.needsProperties
                let headerSize: Int
                let packed: Int
                let unpacked: Int
                if control >= 0x80 {
                    if control < 0xC0 && needsProperties { throw .invalidValue }
                    headerSize = control >= 0xC0 ? 6 : 5
                    guard available >= headerSize else { return needsInput }
                    unpacked = ((control & 0x1F) &<< 16 | Int(UInt16(bigEndian: bytes.load(fromByteOffset: 1, as: UInt16.self)))) &+ 1
                    packed = Int(UInt16(bigEndian: bytes.load(fromByteOffset: 3, as: UInt16.self))) &+ 1
                } else {
                    guard control <= 2 else { throw .invalidValue }
                    headerSize = 3
                    guard available >= headerSize else { return needsInput }
                    unpacked = Int(UInt16(bigEndian: bytes.load(fromByteOffset: 1, as: UInt16.self))) &+ 1
                    packed = unpacked
                }
                guard packed <= available &- headerSize else { return needsInput }
                if let size = block.compressedSize, headerSize &+ packed > size &- block.compressed { throw .mismatch }
                if let size = block.uncompressedSize, unpacked > size &- block.uncompressed { throw .mismatch }

                // The whole chunk is here: apply its resets, then decode it.
                if resetsDictionary {
                    block.needsDictionaryReset = false
                    block.needsProperties = true
                    registers.position = 0
                    window.restart()
                }
                if control >= 0xC0 {
                    let properties = try LZMAProperties(byte: bytes.load(fromByteOffset: 5, as: UInt8.self), dictionarySize: block.dictionarySize)
                    guard properties.literalContextBits &+ properties.literalPositionBits <= 4 else { throw .invalidValue }
                    model = LZMAModel(properties: properties)
                    block.needsProperties = false
                    // Unsafe: the model's memory. Safe: the workspace holds the probabilities for lc + lp <= 4.
                    unsafe LZMALoop.resetState(&registers, model, probabilities: workspace.base)
                } else if control >= 0xA0 {
                    unsafe LZMALoop.resetState(&registers, model, probabilities: workspace.base)
                }
                try window.makeRoom(
                    unpacked, position: &registers.position, dictionarySize: max(block.dictionarySize, LZMAModel.minimumDictionarySize),
                    maximumDictionarySize: maximumDictionarySize
                )
                let start = registers.position
                let data = bytes.extracting(headerSize..<(headerSize &+ packed))
                if control >= 0x80 {
                    // Unsafe and safe as `LZMALoop.decodeChunk`: the input holds `packed` bytes after the header (the
                    // span's base address, as it isn't empty), and the window `unpacked` after the position
                    // (`makeRoom`).
                    let dictionary = unsafe window.base!
                    let probabilities = unsafe workspace.base
                    try data.withUnsafeBytes { chunk throws(BytesError) in
                        try unsafe LZMALoop.decodeChunk(
                            chunk.baseAddress!.assumingMemoryBound(to: UInt8.self), packed: packed, &registers, model: model,
                            dictionary: dictionary, limit: start &+ unpacked, probabilities: probabilities
                        )
                    }
                } else {
                    // Unsafe: a copy of the `unpacked` bytes after the header, which the window has room for.
                    let destination = unsafe UnsafeMutableRawPointer(window.base! + start)
                    data.withUnsafeBytes { chunk in
                        unsafe destination.copyMemory(from: chunk.baseAddress!, byteCount: unpacked)
                    }
                    registers.position &+= unpacked
                }
                switch checkType {
                case 1: block.crc32.update(window.bytes(from: start, to: registers.position))
                case 4: block.crc64.update(window.bytes(from: start, to: registers.position))
                default: break
                }
                block.compressed &+= headerSize &+ packed
                block.uncompressed &+= unpacked
                position &+= headerSize &+ packed

            case .blockEnd:
                let padding = (0 &- (block.headerSize &+ block.compressed)) & 3
                let checkSize = XZ.checkSize(checkType)
                guard available >= padding &+ checkSize else { return needsInput }
                for index in 0..<padding where bytes.load(fromByteOffset: index, as: UInt8.self) != 0 { throw .invalidValue }
                switch checkType {
                case 1:
                    let expected = UInt32(littleEndian: bytes.load(fromByteOffset: padding, as: UInt32.self))
                    guard block.crc32.value == expected else { throw .mismatch }
                case 4:
                    let expected = UInt64(littleEndian: bytes.load(fromByteOffset: padding, as: UInt64.self))
                    guard block.crc64.value == expected else { throw .mismatch }
                default:
                    break // None, or SHA-256: not verified.
                }
                blocks.add(
                    unpadded: UInt64(block.headerSize &+ block.compressed &+ checkSize), uncompressed: UInt64(block.uncompressed)
                )
                position &+= padding &+ checkSize
                stage = .blockStart

            case .indexCount:
                var cursor = XZCursor(bytes)
                let records: UInt64
                do throws(BytesError) {
                    records = try cursor.integer()
                } catch .insufficientData {
                    return needsInput
                }
                guard records == UInt64(blocks.count) else { throw .mismatch }
                consumeIndex(bytes.extracting(first: cursor.position), at: &position)
                listed = XZIndexSummary()
                indexRemaining = blocks.count
                stage = .indexRecords

            case .indexRecords:
                if indexRemaining == 0 {
                    guard listed == blocks else { throw .mismatch }
                    stage = .indexEnd
                    continue
                }
                var cursor = XZCursor(bytes)
                let unpadded: UInt64
                let uncompressed: UInt64
                do throws(BytesError) {
                    unpadded = try cursor.integer()
                    uncompressed = try cursor.integer()
                } catch .insufficientData {
                    return needsInput
                }
                listed.add(unpadded: unpadded, uncompressed: uncompressed)
                consumeIndex(bytes.extracting(first: cursor.position), at: &position)
                indexRemaining &-= 1

            case .indexEnd:
                let padding = (0 &- indexSize) & 3
                guard available >= padding &+ 4 else { return needsInput }
                for index in 0..<padding where bytes.load(fromByteOffset: index, as: UInt8.self) != 0 { throw .invalidValue }
                indexCRC.update(bytes.extracting(first: padding))
                guard indexCRC.value == UInt32(littleEndian: bytes.load(fromByteOffset: padding, as: UInt32.self)) else {
                    throw .mismatch
                }
                indexSize &+= padding &+ 4
                position &+= padding &+ 4
                stage = .footer

            case .footer:
                guard available >= XZ.headerSize else { return needsInput }
                try XZ.checkFooter(bytes, indexSize: indexSize, checkType: checkType)
                position &+= XZ.headerSize
                stage = .streamPadding

            case .streamPadding:
                // Zeros, four at a time; anything else starts another stream.
                if available >= 4 {
                    if bytes.load(fromByteOffset: 0, as: UInt32.self) == 0 {
                        position &+= 4
                    } else {
                        stage = .streamHeader
                    }
                    continue
                }
                for index in 0..<available where bytes.load(fromByteOffset: index, as: UInt8.self) != 0 {
                    stage = .streamHeader
                    break
                }
                if stage == .streamPadding { return needsInput } // Part of a group of zeros.
            }
        }
    }

    /// Consumes `bytes` of the index, adding them to its CRC and size.
    private mutating func consumeIndex(_ bytes: RawSpan, at position: inout Int) {
        indexCRC.update(bytes)
        indexSize &+= bytes.byteCount
        position &+= bytes.byteCount
    }
}

// It owns its memory (no references are shared), and being `~Copyable`, only one owner can use it.
extension XZDecoder: @unchecked Sendable {}

extension XZDecoder: ResettableByteTransform {
    public typealias Failure = BytesError

    /// Decodes as ``decompress(_:into:)`` does. At `.finish`, input that ends inside a stream throws
    /// ``BytesError/insufficientData``; otherwise the end of a stream reads as ``TransformStatus/needsInput``,
    /// since another may follow.
    public mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(BytesError) -> TransformProgress {
        var progress = try decompress(input, into: &output)
        if flush == .finish {
            if progress.status == .needsInput { throw .insufficientData } // The input ended inside a stream.
        } else if progress.status == .finished {
            progress.status = .needsInput
        }
        return progress
    }
}
