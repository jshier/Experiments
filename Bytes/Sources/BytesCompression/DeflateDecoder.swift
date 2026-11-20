public import Bytes

/// A DEFLATE (RFC 1951) decoder for raw, zlib (RFC 1950), and gzip (RFC 1952) streams, in one call or as
/// input arrives.
///
/// ```swift
/// var decoder = DeflateDecoder(format: .gzip)          // allocates its tables and window once
/// let size = try decoder.decompressAll(body, into: &output)   // a whole stream, straight into `output`
///
/// decoder.reset()                                     // the next stream, in pieces
/// let progress = try decoder.decompress(chunk, into: &output)
/// // progress.consumed bytes of `chunk` are used: pass the rest again with the next chunk.
/// ```
///
/// Decoding allocates nothing after initialization. ``decompressAll(_:into:)`` decodes into the caller's
/// buffer, as libdeflate does; ``decompress(_:into:)`` decodes into a window of its own, which keeps the
/// 32 KB that back-references can reach, and copies out.
///
/// The decode loop is libdeflate's design on `Bytes`' ``BitBuffer``: packed table entries holding a
/// length's base and extra-bit count, the next entry looked up before the current symbol is finished, up
/// to three literals per refill, and matches copied 16 bytes at a time with an overrun. It runs while at
/// least 32 bytes of input remain, so it never checks for the end; within 32 bytes of the end a careful
/// loop decodes one symbol at a time, and stops at the start of a code that isn't all there.
@safe
public struct DeflateDecoder: ~Copyable {
    /// The stream's state and tables: separate from the window, so decoding can borrow both.
    private var stream: InflateStream

    /// Room the fast loop needs before each symbol: three literals, a longest match, and the copy's overrun.
    static var fastRoom: Int { 3 + Deflate.maximumMatch + AlignedBytesWriter.copyOverrun }
    /// The window: 32 KB of history, then room to decode into, until it slides.
    static var windowCapacity: Int { 160 << 10 }

    private var window: UniqueArray<UInt8>
    /// The end of the decoded bytes in ``window``.
    private var windowEnd = 0
    /// The first decoded byte not yet delivered.
    private var windowDelivered = 0

    /// Creates a decoder, allocating its tables and window.
    ///
    /// - Parameter format: The container the streams come in.
    public init(format: DeflateFormat = .raw) {
        stream = InflateStream(format: format)
        window = UniqueArray(repeating: 0, count: Self.windowCapacity)
    }

    /// The container format.
    public var format: DeflateFormat { stream.format }

    /// Prepares to decode a new stream, discarding any output not yet delivered. Keeps the allocations.
    public mutating func reset() {
        stream.reset()
        windowEnd = 0
        windowDelivered = 0
    }

    /// Whether the stream has ended and all its output has been delivered.
    public var isFinished: Bool { stream.isDone && windowDelivered == windowEnd }

    /// Decodes a whole stream, from the start, straight into `output`'s free capacity.
    ///
    /// The fastest way to decode: no window, no copies. The decoder must be fresh or ``reset()``.
    ///
    /// - Parameters:
    ///   - input: The whole compressed stream. Bytes after its end are ignored.
    ///   - output: Where to append the decompressed bytes; it needs room for all of them.
    /// - Returns: The number of input bytes the stream took, including its container's header and trailer.
    /// - Throws: ``BytesError/insufficientData`` for a truncated stream; ``BytesError/insufficientCapacity``
    ///   if the output doesn't fit; ``BytesError/invalidValue`` for corrupt data; ``BytesError/mismatch`` for
    ///   a wrong checksum or length, or a stored block's bad length complement.
    public mutating func decompressAll(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> Int {
        try output.withFreeCapacity { span, written throws(BytesError) -> Int in
            let result = try stream.run(input, from: 0, into: &span, at: 0)
            switch result.stop {
            case .finished: break
            case .needsInput: throw .insufficientData
            case .outputFull: throw .insufficientCapacity
            }
            written = result.end
            return result.position &>> 3
        }
    }

    /// Decodes as much of `input` as it can, appending to `output`, continuing the current stream.
    ///
    /// Input can be split anywhere. ``TransformProgress/consumed`` says how much of `input` was used; pass the
    /// rest again, followed by more, on the next call. The decoder only stops short of the end at the
    /// start of a code or header that isn't all there, so it needs at most 512 bytes of unconsumed input to
    /// make progress.
    ///
    /// - Parameters:
    ///   - input: The next compressed bytes, starting with any not consumed last time.
    ///   - output: Where to append decompressed bytes.
    /// - Returns: What was consumed and produced, and whether more input or more room is needed, or the
    ///   stream is finished.
    /// - Throws: ``BytesError/invalidValue`` for corrupt data; ``BytesError/mismatch`` for a wrong checksum
    ///   or length. A stream that never ends just keeps asking for input.
    public mutating func decompress(_ input: RawSpan, into output: inout OutputRawSpan) throws(BytesError) -> TransformProgress {
        var position = stream.bitOffset
        var produced = 0
        let status: TransformStatus
        while true {
            produced &+= deliver(into: &output)
            guard windowDelivered == windowEnd else {
                status = .needsOutput
                break
            }
            if stream.isDone {
                status = .finished
                break
            }
            if Self.windowCapacity &- windowEnd < Self.fastRoom {
                slide()
            }
            var span = window.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            let result = try stream.run(input, from: position, into: &raw, at: windowEnd)
            position = result.position
            windowEnd = result.end
            if result.stop == .needsInput {
                produced &+= deliver(into: &output)
                status = windowDelivered == windowEnd ? .needsInput : .needsOutput
                break
            }
        }
        stream.bitOffset = position & 7
        return TransformProgress(consumed: position &>> 3, produced: produced, status: status)
    }

    /// Copies undelivered output from the window into `output`, as much as fits.
    ///
    /// - Parameter output: Where to append.
    /// - Returns: The number of bytes copied.
    private mutating func deliver(into output: inout OutputRawSpan) -> Int {
        let count = min(windowEnd &- windowDelivered, output.freeCapacity)
        guard count > 0 else { return 0 }
        output.append(copying: window.span.bytes.extracting(windowDelivered..<(windowDelivered &+ count)))
        windowDelivered &+= count
        return count
    }

    /// Moves the last 32 KB of output, the history back-references can reach, to the front of the window.
    /// Everything has been delivered.
    private mutating func slide() {
        let kept = min(windowEnd, Deflate.windowSize)
        let start = windowEnd &- kept
        var span = window.mutableSpan
        span.copyBytes(within: start..<windowEnd, toByteOffset: 0)
        windowEnd = kept
        windowDelivered = kept
    }
}

/// A DEFLATE stream's state and tables, decoding into whatever buffer it's given.
@safe
struct InflateStream: ~Copyable {
    /// The container format.
    let format: DeflateFormat

    // MARK: Tables

    /// Root table widths: codes up to this long take one lookup, longer ones a second in a subtable.
    static var literalRootBits: Int { 11 }
    static var distanceRootBits: Int { 8 }

    // Tables, in one array: the fixed code's two (built once) and the current dynamic block's two. The sizes
    // cover the largest tables any valid code can need (from zlib's `enough`: 2,342 entries for 11-bit
    // literal/length roots, 402 for 8-bit distance roots). Read through spans, so every lookup is
    // bounds-checked; see `decodeSymbols` for why that costs nothing on the root lookups.
    static var tableSize: Int { 2560 }
    static var distanceTableSize: Int { 512 }
    static var fixedLiterals: Int { 0 }
    static var fixedDistances: Int { tableSize }
    static var dynamicLiterals: Int { tableSize + distanceTableSize }
    static var dynamicDistances: Int { 2 * tableSize + distanceTableSize }
    static var totalTableSize: Int { 2 * tableSize + 2 * distanceTableSize }

    private var tables: UniqueArray<UInt32>
    /// The code-length code, which only headers use: `Bytes`' plain table, entries holding just the symbol.
    private var codeLengthTable = HuffmanTable(symbolCount: 19, maximumCodeLength: 7, rootBits: 7)

    /// Room the fast loop needs before each symbol: three literals, a longest match, and the copy's overrun.
    static var fastRoom: Int { DeflateDecoder.fastRoom }

    // MARK: Stream state

    private enum Stage {
        case zlibHeader
        case gzipHeader
        case gzipExtraLength
        case gzipExtra(remaining: Int)
        case gzipName
        case gzipComment
        case gzipHeaderCRC
        case blockHeader
        case stored(remaining: Int)
        case huffman(fixed: Bool)
        case trailer
        case done
    }

    private var stage: Stage
    private var isFinalBlock = false
    /// Bits of the next call's first input byte already consumed.
    var bitOffset = 0
    /// gzip's header flags.
    private var gzipFlags = Byte.zero
    /// The CRC-32 of the gzip header so far, for its optional header CRC.
    private var headerCRC = CRC32()
    /// The running checksum of the output: CRC-32 for gzip, Adler-32 for zlib.
    private var checksum: UInt32 = 0
    /// The output's length modulo 2^32, for gzip's trailer.
    private var length: UInt32 = 0

    /// Creates a stream's state, allocating its tables.
    ///
    /// - Parameter format: The container the streams come in.
    init(format: DeflateFormat) {
        self.format = format
        tables = UniqueArray(repeating: 0, count: Self.totalTableSize)
        stage = Self.initialStage(format)
        checksum = Self.initialChecksum(format)
        // The fixed code is valid, so building it can't throw.
        try! buildTable(Deflate.fixedLiteralLengths.span, .literalLength, at: Self.fixedLiterals, rootBits: Self.literalRootBits)
        try! buildTable(InlineArray<32, UInt8>(repeating: 5).span, .distance, at: Self.fixedDistances, rootBits: Self.distanceRootBits)
    }

    private static func initialStage(_ format: DeflateFormat) -> Stage {
        switch format {
        case .raw: .blockHeader
        case .zlib: .zlibHeader
        case .gzip: .gzipHeader
        }
    }

    private static func initialChecksum(_ format: DeflateFormat) -> UInt32 {
        format == .zlib ? 1 : 0
    }

    /// Prepares to decode a new stream. Keeps the tables.
    /// Whether the stream is between two blocks, the last not final: where a parallel decoder's segment may
    /// end.
    var isBetweenBlocks: Bool {
        if case .blockHeader = stage { return !isFinalBlock }
        return false
    }

    mutating func reset() {
        stage = Self.initialStage(format)
        isFinalBlock = false
        bitOffset = 0
        gzipFlags = .zero
        headerCRC = CRC32()
        checksum = Self.initialChecksum(format)
        length = 0
    }

    /// Whether the stream has ended.
    var isDone: Bool {
        if case .done = stage { return true }
        return false
    }

    // MARK: - The stream's stages

    /// Why ``run(_:from:into:at:)`` stopped.
    enum Stop: Equatable {
        case needsInput, outputFull, finished
    }

    /// Decodes from bit `start` of `input` into `output` from `outputStart`, through the stream's stages,
    /// until it needs more input, the output is full, or the stream ends. Updates the checksum and length
    /// of what it writes.
    ///
    /// - Parameters:
    ///   - input: The compressed bytes available.
    ///   - start: The bit to start at.
    ///   - output: The buffer to decode into; bytes before `outputStart` are history.
    ///   - outputStart: Where to write next.
    /// - Returns: The next unread bit, the end of the output, and why it stopped.
    /// - Throws: As ``decompress(_:into:)``.
    mutating func run(
        _ input: RawSpan, from start: Int, into output: inout MutableRawSpan, at outputStart: Int
    ) throws(BytesError) -> (position: Int, end: Int, stop: Stop) {
        var position = start
        var end = outputStart
        while true {
            switch stage {
            case .done:
                return (position, end, .finished)
            case .zlibHeader, .gzipHeader, .gzipExtraLength, .gzipExtra, .gzipName, .gzipComment, .gzipHeaderCRC:
                guard try readContainerHeader(input, at: &position) else { return (position, end, .needsInput) }
            case .blockHeader:
                if isFinalBlock {
                    stage = .trailer
                } else {
                    guard try readBlockHeader(input, at: &position) else { return (position, end, .needsInput) }
                }
            case let .stored(remaining):
                let byteOffset = position &>> 3 // Stored data starts on a byte boundary.
                // Pairwise `min`: with three or more arguments it's variadic, which can allocate an array.
                let count = min(min(remaining, input.byteCount &- byteOffset), output.byteCount &- end)
                var writer = try AlignedBytesWriter(&output, atByteOffset: end)
                try writer.write(input.extracting(byteOffset..<(byteOffset &+ count)))
                updateChecksum(writer.writtenBytes.extracting(end...))
                position &+= count &<< 3
                end &+= count
                guard count == remaining else {
                    stage = .stored(remaining: remaining &- count)
                    return (position, end, end == output.byteCount ? .outputFull : .needsInput)
                }
                stage = .blockHeader
            case let .huffman(fixed):
                let literals = fixed ? Self.fixedLiterals : Self.dynamicLiterals
                let distances = fixed ? Self.fixedDistances : Self.dynamicDistances
                var result: (bitPosition: Int, end: Int, stop: SymbolStop)
                do {
                    let literalTable = tables.span.extracting(literals..<(literals &+ Self.tableSize))
                    let distanceTable = tables.span.extracting(distances..<(distances &+ Self.distanceTableSize))
                    result = try Self.decodeSymbols(
                        input, from: position, literals: literalTable, distances: distanceTable, into: &output, at: end
                    )
                    if result.stop == .nearEnd {
                        result = try Self.decodeSymbolsCarefully(
                            input, from: result.bitPosition, literals: literalTable, distances: distanceTable,
                            into: &output, at: result.end
                        )
                    }
                }
                updateChecksum(output.bytes.extracting(end..<result.end))
                position = result.bitPosition
                end = result.end
                switch result.stop {
                case .endOfBlock: stage = .blockHeader
                case .outputFull: return (position, end, .outputFull)
                case .needsInput, .nearEnd: return (position, end, .needsInput)
                }
            case .trailer:
                position = (position &+ 7) & ~7
                guard try readTrailer(input, at: &position) else { return (position, end, .needsInput) }
                stage = .done
            }
        }
    }

    /// Adds decoded bytes to the container's checksum and length.
    ///
    /// - Parameter bytes: Bytes just decoded.
    private mutating func updateChecksum(_ bytes: RawSpan) {
        switch format {
        case .raw: break
        case .zlib: checksum = Adler32.checksum(bytes, continuing: checksum)
        case .gzip:
            checksum = CRC32.checksum(bytes, continuing: checksum)
            length &+= UInt32(truncatingIfNeeded: bytes.byteCount)
        }
    }

    // MARK: Container headers and trailers

    /// Reads the next part of a zlib or gzip header at byte `position / 8`.
    ///
    /// - Parameters:
    ///   - input: The compressed bytes available.
    ///   - position: The bit position, a multiple of 8; advanced past what was read.
    /// - Returns: `false` if the part isn't all there (nothing is consumed).
    /// - Throws: ``BytesError/invalidValue`` for a header this decoder doesn't accept (another method, a
    ///   preset dictionary, reserved flags, a bad header check); ``BytesError/mismatch`` for a wrong header CRC.
    private mutating func readContainerHeader(_ input: RawSpan, at position: inout Int) throws(BytesError) -> Bool {
        var reader = try BytesReader(input, atBitPosition: position)
        do throws(BytesError) {
            switch stage {
            case .zlibHeader:
                let header = try reader.read(Byte2.self, .bigEndian)
                guard header[ZlibHeader.method] == 8, header[ZlibHeader.windowBits] <= 7, header % 31 == 0,
                      header.isClear(ZlibHeader.presetDictionary) else { throw BytesError.invalidValue }
                stage = .blockHeader
            case .gzipHeader:
                let fixed = try reader.read(byteCount: 10)
                var header = AlignedBytesReader(fixed)
                try header.expect(0x1F_8B_08 as Byte3) // ID1, ID2, CM (8, DEFLATE)
                gzipFlags = try header.read(Byte.self)
                try gzipFlags.requireZero(GzipFlags.reserved)
                headerCRC.update(fixed)
                stage = .gzipExtraLength
            case .gzipExtraLength:
                if gzipFlags[GzipFlags.extra] {
                    let lengthBytes = try reader.read(byteCount: 2)
                    headerCRC.update(lengthBytes)
                    var lengthReader = AlignedBytesReader(lengthBytes)
                    stage = try .gzipExtra(remaining: Int(lengthReader.read(Byte2.self, .littleEndian)))
                } else {
                    stage = .gzipName
                }
            case let .gzipExtra(remaining):
                let count = min(remaining, reader.remainingByteCount)
                headerCRC.update(try reader.read(byteCount: count))
                stage = count == remaining ? .gzipName : .gzipExtra(remaining: remaining &- count)
                if count < remaining {
                    position = reader.bitPosition
                    return false
                }
            case .gzipName, .gzipComment:
                let isName = if case .gzipName = stage { true } else { false }
                if gzipFlags[isName ? GzipFlags.name : GzipFlags.comment] { // Zero-terminated.
                    let rest = reader.remainingBytes
                    let zero = rest.firstByteOffset { $0.matching(0) }
                    let count = zero.map { $0 &+ 1 } ?? rest.byteCount
                    headerCRC.update(try reader.read(byteCount: count))
                    if zero == nil {
                        position = reader.bitPosition
                        return false
                    }
                }
                stage = isName ? .gzipComment : .gzipHeaderCRC
            case .gzipHeaderCRC:
                if gzipFlags[GzipFlags.headerCRC] { // The low 16 bits of the header's CRC-32.
                    let expected = try reader.read(Byte2.self, .littleEndian)
                    guard expected == UInt16(truncatingIfNeeded: headerCRC.value) else { throw BytesError.mismatch }
                }
                stage = .blockHeader
            default:
                preconditionFailure("Not a header stage")
            }
        } catch .insufficientData {
            return false
        }
        position = reader.bitPosition
        return true
    }

    /// Reads and checks the container's trailer at byte `position / 8`.
    ///
    /// - Parameters:
    ///   - input: The compressed bytes available.
    ///   - position: The bit position, a multiple of 8; advanced past the trailer.
    /// - Returns: `false` if the trailer isn't all there (nothing is consumed).
    /// - Throws: ``BytesError/mismatch`` for a wrong checksum or length.
    private func readTrailer(_ input: RawSpan, at position: inout Int) throws(BytesError) -> Bool {
        var reader = try BytesReader(input, atBitPosition: position)
        do throws(BytesError) {
            switch format {
            case .raw: break
            case .zlib:
                guard try reader.read(Byte4.self, .bigEndian) == checksum else { throw BytesError.mismatch }
            case .gzip:
                let trailer = try reader.read(byteCount: 8)
                var fields = AlignedBytesReader(trailer)
                guard try fields.read(Byte4.self, .littleEndian) == checksum,
                      try fields.read(Byte4.self, .littleEndian) == length else { throw BytesError.mismatch }
            }
        } catch .insufficientData {
            return false
        }
        position = reader.bitPosition
        return true
    }

    // MARK: Block headers

    /// Reads a block header at bit `position`: the final flag, the type, and a stored block's length or a
    /// dynamic block's tables, all or nothing.
    ///
    /// - Parameters:
    ///   - input: The compressed bytes available.
    ///   - position: The bit position; advanced past the header.
    /// - Returns: `false` if the header isn't all there (nothing is consumed).
    /// - Throws: ``BytesError/invalidValue`` for the reserved block type or invalid tables;
    ///   ``BytesError/mismatch`` for a stored block's bad length complement.
    private mutating func readBlockHeader(_ input: RawSpan, at position: inout Int) throws(BytesError) -> Bool {
        var bits = try BitBuffer(input, atBitPosition: position, bitOrder: .leastSignificantFirst)
        let isFinal = bits.read(Bool.self)
        let type = try bits.read(DeflateBlockType.self, as: Crumb.self)
        let next: Stage
        switch type {
        case .stored:
            bits.alignToByte()
            guard !bits.isOverrun else { return false }
            var stored = try bits.finish()
            let length: Byte2
            do {
                length = try stored.read(Byte2.self)
                try stored.expect(~length) // NLEN, the one's complement
            } catch .insufficientData {
                return false
            }
            isFinalBlock = isFinal
            position = stored.bitPosition
            stage = .stored(remaining: Int(length.littleEndian))
            return true
        case .fixedHuffman:
            next = .huffman(fixed: true)
        case .dynamicHuffman:
            guard try readDynamicTables(&bits) else { return false }
            next = .huffman(fixed: false)
        }
        // A truncated header reads zeros from the buffer; caught here, before anything changes.
        guard !bits.isOverrun else { return false }
        isFinalBlock = isFinal
        stage = next
        position = bits.bitPosition
        return true
    }

    /// Reads a dynamic block's header (RFC 1951, 3.2.7) and builds its two tables.
    ///
    /// - Parameter bits: The bit buffer, positioned after the block type.
    /// - Returns: `false` if the header ran past the end of the input.
    /// - Throws: ``BytesError/invalidValue`` for too many codes, an invalid or over-subscribed code, a bad
    ///   repeat, or a missing end-of-block code.
    private mutating func readDynamicTables(_ bits: inout BitBuffer) throws(BytesError) -> Bool {
        let literalCount = bits.read(Int.self, as: Bits<5>.self) &+ 257 // HLIT
        let distanceCount = bits.read(Int.self, as: Bits<5>.self) &+ 1 // HDIST
        let codeLengthCount = bits.read(Int.self, as: Nibble.self) &+ 4 // HCLEN
        guard !bits.isOverrun else { return false }
        guard literalCount <= 286, distanceCount <= 30 else { throw .invalidValue }

        // The code-length code: 3 bits per length, in a fixed order.
        var codeLengthLengths = InlineArray<19, UInt8>(repeating: 0)
        for index in 0..<codeLengthCount {
            codeLengthLengths[Int(Deflate.codeLengthOrder[index])] = bits.read(Bits<3>.self).rawValue
        }
        guard !bits.isOverrun else { return false }
        // zlib rejects incomplete code-length codes, unlike the others.
        try codeLengthTable.build(codeLengths: codeLengthLengths.span, bitOrder: .leastSignificantFirst, allowingIncomplete: false)

        // The literal/length and distance code lengths, as one sequence with run-length codes 16 to 18.
        var lengths = InlineArray<316, UInt8>(repeating: 0)
        let total = literalCount &+ distanceCount
        var index = 0
        while index < total {
            bits.refill()
            // Past the end, zeros decode as some code: harmless, since the overrun is checked before
            // anything is used.
            let symbol = try codeLengthTable.decode(&bits)
            let repeated: UInt8
            let count: Int
            switch symbol {
            case 0...15:
                lengths[index] = UInt8(symbol)
                index &+= 1
                continue
            case 16: // The previous length, 3 to 6 times.
                guard index > 0 else {
                    // Zeros past the end of a truncated header can decode as code 16 here: that's more input
                    // needed, not an invalid stream (a socket stream's reads ended 8 bytes into a header).
                    if bits.isOverrun { return false }
                    throw .invalidValue
                }
                repeated = lengths[index &- 1]
                count = 3 &+ Int(bits.read(Crumb.self))
            case 17: // Zero, 3 to 10 times.
                repeated = 0
                count = 3 &+ Int(bits.read(Bits<3>.self))
            default: // 18: zero, 11 to 138 times.
                repeated = 0
                count = 11 &+ Int(bits.read(Bits<7>.self))
            }
            guard index &+ count <= total else {
                if bits.isOverrun { return false }
                throw .invalidValue
            }
            for offset in index..<(index &+ count) {
                lengths[offset] = repeated
            }
            index &+= count
        }
        guard !bits.isOverrun else { return false }
        guard lengths[256] != 0 else { throw .invalidValue } // A block needs its end code.

        let span = lengths.span
        try buildTable(span.extracting(0..<literalCount), .literalLength, at: Self.dynamicLiterals, rootBits: Self.literalRootBits)
        try buildTable(span.extracting(literalCount..<total), .distance, at: Self.dynamicDistances, rootBits: Self.distanceRootBits)
        return true
    }

    /// Builds the decoding table at `offset` in ``tables`` for the canonical Huffman code with code `lengths`
    /// (0 for unused symbols), with `alphabet`'s packed entries.
    ///
    /// Accepts the incomplete codes zlib does: an empty one (a block without matches) and a single 1-bit
    /// code (RFC 1951 allows it for distances, zlib for literals too).
    ///
    /// - Parameters:
    ///   - lengths: The code length of each symbol.
    ///   - alphabet: Which alphabet's entries to build.
    ///   - offset: Where the table starts in ``tables``.
    ///   - rootBits: The root table's index width.
    /// - Throws: ``BytesError/invalidValue`` if the lengths aren't a valid code.
    private mutating func buildTable(
        _ lengths: Span<UInt8>, _ alphabet: DeflateAlphabet, at offset: Int, rootBits: Int
    ) throws(BytesError) {
        let size = alphabet == .literalLength ? Self.tableSize : Self.distanceTableSize
        var all = tables.mutableSpan
        var table = all._mutatingExtracting(offset..<(offset &+ size))
        _ = try HuffmanTable.build(
            codeLengths: lengths, bitOrder: .leastSignificantFirst, rootBits: rootBits, maximumCodeLength: 15,
            into: &table, invalid: HuffmanEntry.invalid.raw,
            symbol: { symbol, length in alphabet.entry(symbol, codeLength: length).raw },
            subtable: { offset, bits in HuffmanEntry(codeLength: bits, kind: .subtable, value: offset).raw }
        )
    }

    // MARK: - Symbols

    /// Why ``decodeSymbols(_:from:literals:distances:into:at:)`` stopped.
    enum SymbolStop {
        case endOfBlock, outputFull, needsInput
        /// The fast loop stopped within 32 bytes of the input's end or near the output's: continue with
        /// ``decodeSymbolsCarefully(_:from:literals:distances:into:at:)``.
        case nearEnd
    }

    /// Input the fast loop needs, in bits: an iteration consumes at most 93 bits (three 15-bit literals,
    /// or a match's 48), so with 32 bytes left it never reads past the end.
    static var fastInputBits: Int { 32 &* 8 }

    /// Decodes Huffman-coded symbols from `bitPosition` into `output` from `end`, until the block ends,
    /// the output is full, or the next code isn't all there.
    ///
    /// Table lookups are bounds-checked. Stating the tables' sizes once, here, makes those checks free for
    /// root lookups: with the count a known constant, the optimizer sees that a masked root index is in
    /// bounds. Only subtable lookups (codes longer than the root, rare) keep a check.
    ///
    /// - Parameters:
    ///   - input: The compressed bytes available.
    ///   - bitPosition: Where the block's symbols start or resume.
    ///   - literals: The literal/length table, exactly ``tableSize`` entries.
    ///   - distances: The distance table, exactly ``distanceTableSize`` entries.
    ///   - output: The buffer to decode into.
    ///   - end: Where in `output` to write next.
    /// - Returns: The new bit position and output end, and why it stopped. On `needsInput` and
    ///   `outputFull`, the position is the start of the symbol it couldn't finish.
    /// - Throws: ``BytesError/invalidValue`` for an invalid code or a distance reaching before the output's
    ///   start.
    /// - Precondition: The tables have exactly those sizes.
    private static func decodeSymbols(
        _ input: RawSpan, from bitPosition: Int,
        literals: Span<UInt32>, distances: Span<UInt32>,
        into output: inout MutableRawSpan, at end: Int
    ) throws(BytesError) -> (bitPosition: Int, end: Int, stop: SymbolStop) {
        precondition(literals.count == tableSize && distances.count == distanceTableSize)
        var bits = try BitBuffer(input, atBitPosition: bitPosition, bitOrder: .leastSignificantFirst)
        var writer = try AlignedBytesWriter(&output, atByteOffset: end)
        let inputBits = input.byteCount &<< 3

        // The fast loop. The next symbol's entry is looked up ahead of time (as libdeflate does): at the top
        // of each iteration it's ready, so decoding doesn't wait for a refill, a mask, and a table load first.
        // After a match, the next lookup happens before the match is copied, overlapping the two.
        bits.refill()
        var entry = lookup(literals, bits.bits, rootBits: literalRootBits)
        fast: while writer.remainingByteCount >= fastRoom, inputBits &- bits.bitPosition >= fastInputBits {
            if entry.kind == .literal {
                // Literals come in runs: up to three per refill (15 bits each of the 56 or more buffered).
                // Each lookup after a literal reads valid bits (41, then 26 or more left), and a refill only
                // adds bits above them, so an entry that isn't a literal stays valid across the refill.
                bits.consume(bitCount: entry.totalBits)
                try writer.write(Byte(truncatingIfNeeded: entry.value))
                // Root entries first: a literal there can't be a subtable link, so the common case skips
                // that check. Anything else is resolved below.
                entry = rootEntry(literals, bits.bits, rootBits: literalRootBits)
                if entry.kind == .literal {
                    bits.consume(bitCount: entry.totalBits)
                    try writer.write(Byte(truncatingIfNeeded: entry.value))
                    entry = rootEntry(literals, bits.bits, rootBits: literalRootBits)
                    if entry.kind == .literal {
                        bits.consume(bitCount: entry.totalBits)
                        try writer.write(Byte(truncatingIfNeeded: entry.value))
                        // 11 or more bits are left: enough for the root lookup, which then doesn't wait for the
                        // refill's load (only a long code's subtable lookup needs the refilled bits).
                        let root = rootEntry(literals, bits.bits, rootBits: literalRootBits)
                        bits.refill()
                        entry = resolve(root, literals, bits.bits, rootBits: literalRootBits)
                        continue
                    }
                }
                // 26 or more bits: enough to resolve any code.
                entry = resolve(entry, literals, bits.bits, rootBits: literalRootBits)
                // A match needs up to 48 bits: 15 + 5 for its length, 15 + 13 for its distance.
                bits.refill()
            }
            switch entry.kind {
            case .literal:
                // A long literal code, from a subtable: rare. 56 or more bits buffered.
                bits.consume(bitCount: entry.totalBits)
                try writer.write(Byte(truncatingIfNeeded: entry.value))
                entry = lookup(literals, bits.bits, rootBits: literalRootBits)
            case .lengthOrDistance:
                // 48 or more bits buffered. After the length, 28 or more: enough for the distance, decoded
                // from a copy of them, so the refill started here overlaps it instead of delaying it. After
                // the distance, 28 or more remain: enough for the next root lookup, made before a second
                // refill (which the next symbol needs, if it's another match) for the same reason.
                let length = entry.value &+ entry.extra(bits.bits)
                bits.consume(bitCount: entry.totalBits)
                let window = bits.bits
                bits.refill()
                let distanceEntry = lookup(distances, window, rootBits: distanceRootBits)
                guard distanceEntry.kind == .lengthOrDistance else { throw .invalidValue }
                let distance = distanceEntry.value &+ distanceEntry.extra(window)
                bits.consume(bitCount: distanceEntry.totalBits)
                let root = rootEntry(literals, bits.bits, rootBits: literalRootBits)
                bits.refill()
                entry = resolve(root, literals, bits.bits, rootBits: literalRootBits)
                // Throws `invalidValue` for a distance reaching before the output's start.
                try writer.copy(fromDistance: distance, count: length, allowingOverrun: true)
            case .endOfBlock:
                bits.consume(bitCount: entry.totalBits)
                return (bits.bitPosition, writer.byteCount, .endOfBlock)
            default:
                throw .invalidValue
            }
        }

        return (bits.bitPosition, writer.byteCount, .nearEnd)
    }

    /// Decodes symbols near the end of the input or output: one at a time, each finished only if its bits are
    /// all there and its output fits; otherwise it stops at the symbol's start.
    ///
    /// Separate from the fast loop and never inlined: together they were too big for the inliner, which then
    /// left `BytesWriter` and span getters as calls in the fast loop (1,390 instructions against 644).
    ///
    /// - Returns: As ``decodeSymbols(_:from:literals:distances:into:at:)``, never `nearEnd`.
    @inline(never)
    private static func decodeSymbolsCarefully(
        _ input: RawSpan, from bitPosition: Int,
        literals: Span<UInt32>, distances: Span<UInt32>,
        into output: inout MutableRawSpan, at end: Int
    ) throws(BytesError) -> (bitPosition: Int, end: Int, stop: SymbolStop) {
        precondition(literals.count == tableSize && distances.count == distanceTableSize)
        var bits = try BitBuffer(input, atBitPosition: bitPosition, bitOrder: .leastSignificantFirst)
        var writer = try AlignedBytesWriter(&output, atByteOffset: end)
        let inputBits = input.byteCount &<< 3
        while true {
            let start = bits.bitPosition
            let available = inputBits &- start
            bits.refill()
            let entry = lookup(literals, bits.bits, rootBits: literalRootBits)
            switch entry.kind {
            case .literal:
                guard entry.totalBits <= available else { return (start, writer.byteCount, .needsInput) }
                guard writer.remainingByteCount >= 1 else { return (start, writer.byteCount, .outputFull) }
                bits.consume(bitCount: entry.totalBits)
                try writer.write(Byte(truncatingIfNeeded: entry.value))
            case .endOfBlock:
                guard entry.totalBits <= available else { return (start, writer.byteCount, .needsInput) }
                bits.consume(bitCount: entry.totalBits)
                return (bits.bitPosition, writer.byteCount, .endOfBlock)
            case .lengthOrDistance:
                let length = entry.value &+ entry.extra(bits.bits)
                bits.consume(bitCount: entry.totalBits)
                bits.refill()
                let distanceEntry = lookup(distances, bits.bits, rootBits: distanceRootBits)
                guard distanceEntry.kind == .lengthOrDistance else {
                    // Zeros past the end can look like an invalid code.
                    if inputBits &- bits.bitPosition < 15 { return (start, writer.byteCount, .needsInput) }
                    throw .invalidValue
                }
                let distance = distanceEntry.value &+ distanceEntry.extra(bits.bits)
                bits.consume(bitCount: distanceEntry.totalBits)
                guard bits.bitPosition <= inputBits else { return (start, writer.byteCount, .needsInput) }
                guard writer.remainingByteCount >= length else { return (start, writer.byteCount, .outputFull) }
                if writer.remainingByteCount >= length &+ AlignedBytesWriter.copyOverrun {
                    try writer.copy(fromDistance: distance, count: length, allowingOverrun: true)
                } else {
                    try writer.copy(fromDistance: distance, count: length)
                }
            default:
                if available < 15 { return (start, writer.byteCount, .needsInput) }
                throw .invalidValue
            }
        }
    }

    /// The entry for the code at the start of `bits`.
    ///
    /// - Parameters:
    ///   - table: A root table followed by its subtables.
    ///   - bits: The buffered bits; enough must be valid for the longest code.
    ///   - rootBits: The root table's index width.
    /// - Returns: The entry, with any subtable link resolved.
    @inline(__always)
    private static func lookup(_ table: Span<UInt32>, _ bits: UInt64, rootBits: Int) -> HuffmanEntry {
        resolve(rootEntry(table, bits, rootBits: rootBits), table, bits, rootBits: rootBits)
    }

    /// The root table's entry for the start of `bits`: needs only `rootBits` valid bits.
    ///
    /// - Parameters:
    ///   - table: A root table followed by its subtables.
    ///   - bits: The buffered bits.
    ///   - rootBits: The root table's index width.
    /// - Returns: The root entry, which may be a subtable link.
    @inline(__always)
    private static func rootEntry(_ table: Span<UInt32>, _ bits: UInt64, rootBits: Int) -> HuffmanEntry {
        HuffmanEntry(raw: table[Int(truncatingIfNeeded: bits.bits(from: 0, upTo: rootBits))])
    }

    /// `entry`, or for a link to a subtable, the subtable's entry for the bits after the root's.
    ///
    /// - Parameters:
    ///   - entry: A root entry.
    ///   - table: The table `entry` came from.
    ///   - bits: The buffered bits `entry` was looked up with.
    ///   - rootBits: The root table's index width.
    /// - Returns: `entry` unless it's a subtable link.
    @inline(__always)
    private static func resolve(
        _ entry: HuffmanEntry, _ table: Span<UInt32>, _ bits: UInt64, rootBits: Int
    ) -> HuffmanEntry {
        guard entry.kind == .subtable else { return entry }
        // Shift, then mask: `bits(from:upTo:)` masks first, which needs the sum, and grew `decodeSymbols` by 5
        // instructions.
        let index = Int(truncatingIfNeeded: bits.bits(from: rootBits, count: entry.codeLength))
        return HuffmanEntry(raw: table[entry.value &+ index])
    }
}
