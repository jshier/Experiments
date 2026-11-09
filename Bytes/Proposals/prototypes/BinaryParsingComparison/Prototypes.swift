import Bytes

// TEMPORARY: API proposals for Bytes, prototyped with its public API and measured against the kept code.
// Each is used in a copy of one decoder (`…Proto*`), benchmarked as "Proto …".

// MARK: P1 – writing a run of one repeated element

extension BytesWriter {
    /// Writes the low `byteCount` bytes (1 through 8) of `value`, `count` times. Capacity is checked once;
    /// the element is replicated into a word of whole periods and stored 8 bytes at a time.
    @inline(always)
    @_lifetime(self: copy self)
    mutating func write(repeating value: UInt64, byteCount period: Int, count: Int) throws(BytesError) {
        precondition(period >= 1 && period <= 8, "Period must be 1 through 8 bytes")
        let total = count &* period
        guard remainingByteCount >= total else { throw .insufficientCapacity }
        var word = period == 8 ? value : value & (1 &<< (8 &* period) &- 1)
        var wordBytes = period
        while wordBytes &* 2 <= 8 {
            word |= word &<< (8 &* wordBytes)
            wordBytes &*= 2
        }
        var remaining = total
        while remaining > wordBytes {
            try write(word, byteCount: wordBytes, allowingOverrun: true)
            remaining &-= wordBytes
        }
        try write(word, byteCount: remaining, allowingOverrun: true)
    }
}

// MARK: P2 – copying literals from a reader with overrun

extension BytesWriter {
    /// Copies the reader's next `byteCount` bytes. With `allowingOverrun` and 16 bytes left in both, a copy of
    /// up to 16 bytes is one fixed-size move (prototype: two 8-byte stores) that may overwrite up to 16 bytes
    /// after it, like `copy(fromDistance:count:allowingOverrun:)`.
    @inline(always)
    @_lifetime(self: copy self)
    @_lifetime(reader: copy reader)
    mutating func write(from reader: inout BytesReader, byteCount: Int, allowingOverrun: Bool) throws(BytesError) {
        if allowingOverrun, byteCount <= 16, reader.remainingByteCount >= 16 {
            let words = try reader.peekLoad(SIMD2<UInt64>.self)
            try write(words[0], byteCount: min(byteCount, 8), allowingOverrun: true)
            if byteCount > 8 { try write(words[1], byteCount: byteCount &- 8, allowingOverrun: true) }
            try reader.skip(byteCount: byteCount)
        } else {
            try write(reader.read(byteCount: byteCount))
        }
    }
}

// MARK: P3 – errors with their location

/// A ``BytesError`` and the byte offset of the read that threw it.
public struct LocatedBytesError: Error, Equatable {
    public var error: BytesError
    public var byteOffset: Int
    public init(error: BytesError, byteOffset: Int) {
        self.error = error
        self.byteOffset = byteOffset
    }
}

extension BytesReader {
    /// Runs `body` on this cursor; a ``BytesError`` it throws comes out with the cursor's offset, which is
    /// where the failing read started (reads that throw consume nothing). One shared throw path.
    @inline(always)
    @_lifetime(self: copy self)
    mutating func locatingErrors<R>(_ body: (inout BytesReader) throws(BytesError) -> R) throws(LocatedBytesError) -> R {
        do throws(BytesError) {
            return try body(&self)
        } catch {
            throw LocatedBytesError(error: error, byteOffset: byteOffset)
        }
    }
}

// MARK: P5 – masked comparison of a field

extension Bits {
    /// Whether the bits selected by `mask` equal `value`'s: version bits and reserved-zero bits in one test.
    @inline(__always)
    func matches(_ value: Self, mask: Self) -> Bool { self & mask == value }
}

// MARK: P6 – appending to an array through a writer

extension Array where Element == UInt8 {
    /// Appends up to `byteCapacity` bytes written by `body`: `append(addingCapacity:)` and
    /// `withBytesWriter` in one call, committing exactly what's written.
    @inline(always)
    mutating func append<E: Error>(byteCapacity: Int, _ body: (inout BytesWriter) throws(E) -> Void) throws(E) {
        try append(addingCapacity: byteCapacity) { (span: inout OutputSpan<UInt8>) throws(E) in
            try span.withBytesWriter { (writer: inout BytesWriter) throws(E) in try body(&writer) }
        }
    }
}

// MARK: - Variants using them

public extension QOI {
    /// P1: a run op writes the whole run at once.
    static func decodeWithBytesProtoRunFill(_ data: RawSpan) throws -> DecodedImage {
        var reader = BytesReader(data)
        try reader.expect(0x71_6F_69_66 as Byte4) // "qoif"
        let width = try reader.read(Int.self, as: Byte4.self, .bigEndian)
        let height = try reader.read(Int.self, as: Byte4.self, .bigEndian)
        let channels = try Int(reader.read(Byte.self))
        let colorSpace = try reader.read(Byte.self)
        guard channels == 3 || channels == 4, colorSpace <= 1, width > 0, height > 0 else { throw QOIError() }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount < maximumPixelCount else { throw QOIError() }
        let total = pixelCount &* channels

        var pixels = [UInt8](repeating: 0, count: total)
        var output = pixels.mutableSpan
        var writer = BytesWriter(&output)
        do {
            var cache = InlineArray<64, SIMD4<UInt8>>(repeating: .zero)
            var previous = SIMD4<UInt8>(0, 0, 0, 255)
            while !writer.isFull, reader.remainingByteCount >= 8 {
                let first = try reader.read(Byte.self)
                let pixel: SIMD4<UInt8>
                switch first {
                case 0xFF:
                    pixel = try reader.load(SIMD4<UInt8>.self)
                case 0xFE:
                    let rgb = try reader.read(Byte3.self)
                    pixel = SIMD4(rgb[0], rgb[1], rgb[2], previous[3])
                default:
                    let value = UInt8(first[Bits<6>.self, at: 0])
                    switch first[Crumb.self, at: 6] {
                    case 0b00:
                        pixel = cache[Int(value)]
                    case 0b01:
                        let delta = SIMD4(
                            UInt8(first[Crumb.self, at: 4]), UInt8(first[Crumb.self, at: 2]),
                            UInt8(first[Crumb.self, at: 0]), 2
                        ) &- 2
                        pixel = previous &+ delta
                    case 0b10:
                        let second = try reader.read(Byte.self)
                        let green = value &- 32
                        pixel = previous &+ SIMD4(
                            green &- 8 &+ UInt8(second.highHalf), green, green &- 8 &+ UInt8(second.lowHalf), 0
                        )
                    default: // QOI_OP_RUN: this pixel and `value` more, written at once (cut off at the end)
                        let count = min(Int(value) &+ 1, writer.remainingByteCount / channels)
                        try writer.write(
                            repeating: UInt64(bitCast(previous, to: UInt32.self)), byteCount: channels, count: count
                        )
                        cache[hash(previous)] = previous
                        continue
                    }
                }
                try store(pixel, channels: channels, to: &writer)
                cache[hash(pixel)] = pixel
                previous = pixel
            }
        }
        let written = writer.byteCount
        _ = consume writer
        _ = consume output
        pixels.removeLast(total &- written)
        return DecodedImage(width: width, height: height, channels: channels, pixels: pixels)
    }

    /// Diagnosis: the kept Bytes decoder with the DIFF and LUMA fields taken out with shifts and masks, as
    /// the `ParserSpan` port does, instead of bit-field subscripts.
    static func decodeWithBytesProtoShifts(_ data: RawSpan) throws -> DecodedImage {
        var reader = BytesReader(data)
        try reader.expect(0x71_6F_69_66 as Byte4) // "qoif"
        let width = try reader.read(Int.self, as: Byte4.self, .bigEndian)
        let height = try reader.read(Int.self, as: Byte4.self, .bigEndian)
        let channels = try Int(reader.read(Byte.self))
        let colorSpace = try reader.read(Byte.self)
        guard channels == 3 || channels == 4, colorSpace <= 1, width > 0, height > 0 else { throw QOIError() }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount < maximumPixelCount else { throw QOIError() }
        let total = pixelCount &* channels

        var pixels = [UInt8](repeating: 0, count: total)
        var output = pixels.mutableSpan
        var writer = BytesWriter(&output)
        do {
            var cache = InlineArray<64, SIMD4<UInt8>>(repeating: .zero)
            var previous = SIMD4<UInt8>(0, 0, 0, 255)
            var run = 0
            var position = 0
            while position < total, reader.remainingByteCount >= 8 {
                defer { position &+= channels }
                guard run == 0 else {
                    run &-= 1
                    try store(previous, channels: channels, to: &writer)
                    continue
                }
                let first = try reader.read(Byte.self).rawValue
                let pixel: SIMD4<UInt8>
                switch first {
                case 0xFF:
                    pixel = try reader.load(SIMD4<UInt8>.self)
                case 0xFE:
                    let rgb = try reader.read(Byte3.self)
                    pixel = SIMD4(rgb[0], rgb[1], rgb[2], previous[3])
                default:
                    let value = first & 0x3F
                    switch first & 0xC0 {
                    case 0x00:
                        pixel = cache[Int(value)]
                    case 0x40:
                        let delta = SIMD4(first >> 4 & 3, first >> 2 & 3, first & 3, 2) &- 2
                        pixel = previous &+ delta
                    case 0x80:
                        let second = try reader.read(Byte.self).rawValue
                        let green = value &- 32
                        pixel = previous &+ SIMD4(green &- 8 &+ second >> 4, green, green &- 8 &+ second & 0xF, 0)
                    default:
                        run = Int(value)
                        pixel = previous
                    }
                }
                try store(pixel, channels: channels, to: &writer)
                cache[hash(pixel)] = pixel
                previous = pixel
            }
        }
        let written = writer.byteCount
        _ = consume writer
        _ = consume output
        pixels.removeLast(total &- written)
        return DecodedImage(width: width, height: height, channels: channels, pixels: pixels)
    }
}

public extension LZ4 {
    /// P2: literals copied with `write(from:byteCount:allowingOverrun:)`.
    static func decodeWithBytesProtoLiterals(_ data: RawSpan) throws -> [UInt8] {
        var reader = BytesReader(data)
        try reader.expect(0x04_22_4D_18 as Byte4)
        let flags = try reader.read(Byte.self)
        let descriptor = try reader.read(Byte.self)
        let sizeCode = Int(descriptor[Bits<3>.self, at: 4])
        guard flags[Crumb.self, at: 6] == 0b01, !flags[bit: 1], !descriptor[bit: 7],
              descriptor[Nibble.self, at: 0] == 0, sizeCode >= 4, flags[bit: 5]
        else { throw LZ4Error() }
        let blockMaximum = 1 << (8 &+ 2 &* sizeCode)
        let hasBlockChecksums = flags[bit: 4]
        let contentSize = try flags[bit: 3] ? reader.read(Int.self, as: Byte8.self, .littleEndian) : 0
        if flags[bit: 0] { try reader.skip(byteCount: 4) }
        try reader.skip(byteCount: 1)

        var output: [UInt8] = []
        output.reserveCapacity(contentSize > 0 ? contentSize : data.byteCount &* 3)
        while true {
            let size = try reader.read(Byte4.self, .littleEndian)
            if size == 0 { break }
            let block = try reader.read(byteCount: Int(size[bits: 0..<31]))
            if hasBlockChecksums { try reader.skip(byteCount: 4) }
            if size[bit: 31] {
                try output.append(addingCapacity: block.byteCount) { (span: inout OutputSpan<UInt8>) throws(BytesError) in
                    try span.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in try writer.write(block) }
                }
            } else {
                try output.append(addingCapacity: blockMaximum) { (span: inout OutputSpan<UInt8>) throws(BytesError) in
                    try span.withBytesWriter { (writer: inout BytesWriter) throws(BytesError) in
                        var reader = BytesReader(block)
                        while true {
                            let token = try reader.read(Byte.self)
                            let literalCount = try length(Int(token.highHalf), &reader)
                            try writer.write(from: &reader, byteCount: literalCount, allowingOverrun: true)
                            if reader.isAtEnd { return }
                            let distance = try reader.read(Int.self, as: Byte2.self, .littleEndian)
                            guard distance != 0 else { throw .invalidValue }
                            let count = try length(Int(token.lowHalf), &reader) &+ 4
                            try writer.copy(fromDistance: distance, count: count, allowingOverrun: true)
                        }
                    }
                }
            }
        }
        return output
    }

    /// P5 and P6: the header checked with masks, blocks appended with `append(byteCapacity:)`.
    static func decodeWithBytesProtoAppend(_ data: RawSpan) throws -> [UInt8] {
        var reader = BytesReader(data)
        try reader.expect(0x04_22_4D_18 as Byte4)
        let flags = try reader.read(Byte.self)
        let descriptor = try reader.read(Byte.self)
        let sizeCode = Int(descriptor[Bits<3>.self, at: 4])
        // Version 01, reserved bit 1 clear, independent blocks; descriptor reserved bits clear.
        guard flags.matches(0b0110_0000, mask: 0b1110_0010), descriptor.matches(0, mask: 0b1000_1111), sizeCode >= 4
        else { throw LZ4Error() }
        let blockMaximum = 1 << (8 &+ 2 &* sizeCode)
        let hasBlockChecksums = flags[bit: 4]
        let contentSize = try flags[bit: 3] ? reader.read(Int.self, as: Byte8.self, .littleEndian) : 0
        if flags[bit: 0] { try reader.skip(byteCount: 4) }
        try reader.skip(byteCount: 1)

        var output: [UInt8] = []
        output.reserveCapacity(contentSize > 0 ? contentSize : data.byteCount &* 3)
        while true {
            let size = try reader.read(Byte4.self, .littleEndian)
            if size == 0 { break }
            let block = try reader.read(byteCount: Int(size[bits: 0..<31]))
            if hasBlockChecksums { try reader.skip(byteCount: 4) }
            if size[bit: 31] {
                try output.append(byteCapacity: block.byteCount) { (writer) throws(BytesError) in try writer.write(block) }
            } else {
                try output.append(byteCapacity: blockMaximum) { (writer) throws(BytesError) in
                    try decodeBlock(block, into: &writer)
                }
            }
        }
        return output
    }
}

public extension CentralDirectory {
    /// P3: `parseWithBytes` inside `locatingErrors`.
    static func parseWithBytesProtoLocated(_ span: RawSpan) throws(LocatedBytesError) -> UInt64 {
        var reader = BytesReader(span)
        return try reader.locatingErrors { (reader) throws(BytesError) in
            var fields = Fields()
            while !reader.isAtEnd {
                try reader.expect(signature)
                try fields.add(reader.read(Byte2.self, .littleEndian)) // made by
                try reader.skip(byteCount: 2)
                try fields.add(reader.read(Byte2.self, .littleEndian)) // flags
                try fields.add(reader.read(Byte2.self, .littleEndian)) // method
                try fields.add(reader.read(Byte2.self, .littleEndian)) // time
                try fields.add(reader.read(Byte2.self, .littleEndian)) // date
                try fields.add(reader.read(Byte4.self, .littleEndian)) // CRC
                try fields.add(reader.read(Byte4.self, .littleEndian)) // compressed
                try fields.add(reader.read(Byte4.self, .littleEndian)) // uncompressed
                let nameLength = try reader.read(Int.self, as: Byte2.self, .littleEndian)
                let extraLength = try reader.read(Int.self, as: Byte2.self, .littleEndian)
                let commentLength = try reader.read(Int.self, as: Byte2.self, .littleEndian)
                try reader.skip(byteCount: 4)
                try fields.add(reader.read(Byte4.self, .littleEndian)) // external attributes
                try fields.add(reader.read(Byte4.self, .littleEndian)) // local header offset
                try fields.add(reader.read(byteCount: nameLength).byteCount)
                var extra = try reader.readSection(byteCount: extraLength)
                try reader.skip(byteCount: commentLength)
                while extra.remainingByteCount >= 4 {
                    let id = try extra.read(Byte2.self, .littleEndian)
                    let size = try extra.read(Int.self, as: Byte2.self, .littleEndian)
                    var field = try extra.readSection(byteCount: size)
                    if id == 0x5455, size >= 5, try field.read(Byte.self)[bit: 0] {
                        try fields.add(Int32(bitPattern: field.read(Byte4.self, .littleEndian)))
                    }
                }
            }
            return fields.checksum
        }
    }
}

// MARK: Round 2

extension BytesReader {
    /// P3b: `error` with this cursor's offset, where the failing read started. For `catch` blocks: no
    /// closure, so nothing changes on the success path.
    @inline(__always)
    func located(_ error: BytesError) -> LocatedBytesError { LocatedBytesError(error: error, byteOffset: byteOffset) }
}

public extension CentralDirectory {
    /// P3b: `parseWithBytes` in a `do`/`catch` that locates the error.
    static func parseWithBytesProtoCatch(_ span: RawSpan) throws(LocatedBytesError) -> UInt64 {
        var reader = BytesReader(span)
        var fields = Fields()
        do throws(BytesError) {
            while !reader.isAtEnd {
                try reader.expect(signature)
                try fields.add(reader.read(Byte2.self, .littleEndian)) // made by
                try reader.skip(byteCount: 2)
                try fields.add(reader.read(Byte2.self, .littleEndian)) // flags
                try fields.add(reader.read(Byte2.self, .littleEndian)) // method
                try fields.add(reader.read(Byte2.self, .littleEndian)) // time
                try fields.add(reader.read(Byte2.self, .littleEndian)) // date
                try fields.add(reader.read(Byte4.self, .littleEndian)) // CRC
                try fields.add(reader.read(Byte4.self, .littleEndian)) // compressed
                try fields.add(reader.read(Byte4.self, .littleEndian)) // uncompressed
                let nameLength = try reader.read(Int.self, as: Byte2.self, .littleEndian)
                let extraLength = try reader.read(Int.self, as: Byte2.self, .littleEndian)
                let commentLength = try reader.read(Int.self, as: Byte2.self, .littleEndian)
                try reader.skip(byteCount: 4)
                try fields.add(reader.read(Byte4.self, .littleEndian)) // external attributes
                try fields.add(reader.read(Byte4.self, .littleEndian)) // local header offset
                try fields.add(reader.read(byteCount: nameLength).byteCount)
                var extra = try reader.readSection(byteCount: extraLength)
                try reader.skip(byteCount: commentLength)
                while extra.remainingByteCount >= 4 {
                    let id = try extra.read(Byte2.self, .littleEndian)
                    let size = try extra.read(Int.self, as: Byte2.self, .littleEndian)
                    var field = try extra.readSection(byteCount: size)
                    if id == 0x5455, size >= 5, try field.read(Byte.self)[bit: 0] {
                        try fields.add(Int32(bitPattern: field.read(Byte4.self, .littleEndian)))
                    }
                }
            }
        } catch {
            throw reader.located(error)
        }
        return fields.checksum
    }

    /// `atomically` per entry: a streaming parser's all-or-nothing entry (the cost of the closure form).
    static func parseWithBytesProtoAtomic(_ span: RawSpan) throws -> UInt64 {
        var reader = BytesReader(span)
        var fields = Fields()
        while !reader.isAtEnd {
            try reader.atomically { (reader) throws(BytesError) in
                try reader.expect(signature)
                try fields.add(reader.read(Byte2.self, .littleEndian)) // made by
                try reader.skip(byteCount: 2)
                try fields.add(reader.read(Byte2.self, .littleEndian)) // flags
                try fields.add(reader.read(Byte2.self, .littleEndian)) // method
                try fields.add(reader.read(Byte2.self, .littleEndian)) // time
                try fields.add(reader.read(Byte2.self, .littleEndian)) // date
                try fields.add(reader.read(Byte4.self, .littleEndian)) // CRC
                try fields.add(reader.read(Byte4.self, .littleEndian)) // compressed
                try fields.add(reader.read(Byte4.self, .littleEndian)) // uncompressed
                let nameLength = try reader.read(Int.self, as: Byte2.self, .littleEndian)
                let extraLength = try reader.read(Int.self, as: Byte2.self, .littleEndian)
                let commentLength = try reader.read(Int.self, as: Byte2.self, .littleEndian)
                try reader.skip(byteCount: 4)
                try fields.add(reader.read(Byte4.self, .littleEndian)) // external attributes
                try fields.add(reader.read(Byte4.self, .littleEndian)) // local header offset
                try fields.add(reader.read(byteCount: nameLength).byteCount)
                var extra = try reader.readSection(byteCount: extraLength)
                try reader.skip(byteCount: commentLength)
                while extra.remainingByteCount >= 4 {
                    let id = try extra.read(Byte2.self, .littleEndian)
                    let size = try extra.read(Int.self, as: Byte2.self, .littleEndian)
                    var field = try extra.readSection(byteCount: size)
                    if id == 0x5455, size >= 5, try field.read(Byte.self)[bit: 0] {
                        try fields.add(Int32(bitPattern: field.read(Byte4.self, .littleEndian)))
                    }
                }
            }
        }
        return fields.checksum
    }
}

public extension QOI {
    /// Diagnosis: the kept Bytes decoder reading QOI_OP_RGB as three single bytes, as the `ParserSpan` port
    /// does, instead of one `Byte3`.
    static func decodeWithBytesProtoThreeReads(_ data: RawSpan) throws -> DecodedImage {
        var reader = BytesReader(data)
        try reader.expect(0x71_6F_69_66 as Byte4) // "qoif"
        let width = try reader.read(Int.self, as: Byte4.self, .bigEndian)
        let height = try reader.read(Int.self, as: Byte4.self, .bigEndian)
        let channels = try Int(reader.read(Byte.self))
        let colorSpace = try reader.read(Byte.self)
        guard channels == 3 || channels == 4, colorSpace <= 1, width > 0, height > 0 else { throw QOIError() }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount < maximumPixelCount else { throw QOIError() }
        let total = pixelCount &* channels

        var pixels = [UInt8](repeating: 0, count: total)
        var output = pixels.mutableSpan
        var writer = BytesWriter(&output)
        do {
            var cache = InlineArray<64, SIMD4<UInt8>>(repeating: .zero)
            var previous = SIMD4<UInt8>(0, 0, 0, 255)
            var run = 0
            var position = 0
            while position < total, reader.remainingByteCount >= 8 {
                defer { position &+= channels }
                guard run == 0 else {
                    run &-= 1
                    try store(previous, channels: channels, to: &writer)
                    continue
                }
                let first = try reader.read(Byte.self)
                let pixel: SIMD4<UInt8>
                switch first {
                case 0xFF:
                    pixel = try reader.load(SIMD4<UInt8>.self)
                case 0xFE:
                    let red = try reader.read(Byte.self)
                    let green = try reader.read(Byte.self)
                    let blue = try reader.read(Byte.self)
                    pixel = SIMD4(red.rawValue, green.rawValue, blue.rawValue, previous[3])
                default:
                    let value = UInt8(first[Bits<6>.self, at: 0])
                    switch first[Crumb.self, at: 6] {
                    case 0b00:
                        pixel = cache[Int(value)]
                    case 0b01:
                        let delta = SIMD4(
                            UInt8(first[Crumb.self, at: 4]), UInt8(first[Crumb.self, at: 2]),
                            UInt8(first[Crumb.self, at: 0]), 2
                        ) &- 2
                        pixel = previous &+ delta
                    case 0b10:
                        let second = try reader.read(Byte.self)
                        let green = value &- 32
                        pixel = previous &+ SIMD4(
                            green &- 8 &+ UInt8(second.highHalf), green, green &- 8 &+ UInt8(second.lowHalf), 0
                        )
                    default:
                        run = Int(value)
                        pixel = previous
                    }
                }
                try store(pixel, channels: channels, to: &writer)
                cache[hash(pixel)] = pixel
                previous = pixel
            }
        }
        let written = writer.byteCount
        _ = consume writer
        _ = consume output
        pixels.removeLast(total &- written)
        return DecodedImage(width: width, height: height, channels: channels, pixels: pixels)
    }
}
