import BytesFoundation
import Foundation
import Testing

// `Data(copying:)` and `Data.append(copying:)`: empty spans, slices, appends after existing bytes, and a large
// copy (several pages, so `Data` stores it out of line).

@Suite struct DataSpanTests {
    static let large: [UInt8] = (0..<(1 << 20) + 13).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) }

    @Test func copyingEmpty() {
        let bytes: [UInt8] = []
        let data = Data(copying: bytes.span.bytes)
        #expect(data.isEmpty)
    }

    @Test func copyingSmall() {
        let bytes: [UInt8] = [1, 2, 3, 0xFF]
        let data = Data(copying: bytes.span.bytes)
        #expect([UInt8](data) == bytes)
    }

    @Test func copyingLarge() {
        let data = Data(copying: Self.large.span.bytes)
        #expect(data.count == Self.large.count)
        #expect([UInt8](data) == Self.large)
    }

    @Test func copyingSlice() {
        let bytes: [UInt8] = Array(0..<100)
        let span = bytes.span.bytes.extracting(10..<20)
        #expect([UInt8](Data(copying: span)) == Array(10..<20))
    }

    @Test func copyIsIndependent() {
        var bytes: [UInt8] = [1, 2, 3]
        let data = Data(copying: bytes.span.bytes)
        bytes[0] = 9
        #expect([UInt8](data) == [1, 2, 3])
    }

    @Test func appendEmpty() {
        var data = Data([7, 8])
        let empty: [UInt8] = []
        data.append(copying: empty.span.bytes)
        #expect([UInt8](data) == [7, 8])
        var none = Data()
        none.append(copying: empty.span.bytes)
        #expect(none.isEmpty)
    }

    @Test func appendAfterExisting() {
        var data = Data([1, 2])
        let more: [UInt8] = [3, 4, 5]
        data.append(copying: more.span.bytes)
        data.append(copying: more.span.bytes.extracting(1...))
        #expect([UInt8](data) == [1, 2, 3, 4, 5, 4, 5])
    }

    @Test func appendLargeInPieces() {
        var data = Data()
        let span = Self.large.span.bytes
        var offset = 0
        var piece = 1
        while offset < span.byteCount {
            let end = min(offset + piece, span.byteCount)
            data.append(copying: span.extracting(offset..<end))
            offset = end
            piece = piece * 3 + 1
        }
        #expect([UInt8](data) == Self.large)
    }

    @Test func appendToSlicedData() {
        // A `Data` slice whose indices don't start at 0.
        var data = Data([0, 1, 2, 3, 4])[2...]
        let more: [UInt8] = [9]
        data.append(copying: more.span.bytes)
        #expect(data.startIndex == 2)
        #expect([UInt8](data) == [2, 3, 4, 9])
    }

    @Test func appendFromInlineArray() {
        var data = Data()
        let bytes: InlineArray<4, UInt8> = [0xDE, 0xAD, 0xBE, 0xEF]
        data.append(copying: bytes.span.bytes)
        #expect([UInt8](data) == [0xDE, 0xAD, 0xBE, 0xEF])
    }
}
