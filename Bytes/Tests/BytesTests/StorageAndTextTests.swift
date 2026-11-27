import Bytes
import Testing

/// `RawStorage`'s checked accessors, text from spans and literals, words from chunks, and the bit-count checks.
@Suite struct StorageAndTextTests {
    // MARK: - RawStorage

    @Test func storageSpansReadAndWriteTheirRange() {
        let storage = RawStorage(byteCount: 16, alignment: RawStorage.small)
        // Unsafe: writes through the shared storage. Safe: this test is its only user.
        unsafe storage.withMutableBytes(0..<16) { span in
            for index in 0..<16 {
                span.storeBytes(of: UInt8(index), toByteOffset: index, as: UInt8.self)
            }
        }
        // Unsafe: as above.
        let written = unsafe storage.withOutputRawSpan(overwriting: 4..<8) { output in
            output.append(copying: [40, 50].span)
            return output.byteCount
        }
        #expect(written == 2)
        let bytes = storage.bytes(2..<9)
        #expect([UInt8](copying: bytes) == [2, 3, 40, 50, 6, 7, 8])
        #expect(storage.bytes(16..<16).byteCount == 0)
        // Unsafe: pointer arithmetic only, compared.
        #expect(unsafe storage.pointer(16) - storage.base == 16) // The end is a valid pointer.
    }

    @Test func storagePointerPastTheEndStops() async {
        await #expect(processExitsWith: .failure) {
            let storage = RawStorage(byteCount: 16, alignment: RawStorage.small)
            _ = unsafe storage.pointer(17)
        }
        await #expect(processExitsWith: .failure) {
            let storage = RawStorage(byteCount: 16, alignment: RawStorage.small)
            _ = unsafe storage.pointer(-1)
        }
    }

    @Test func storageRangePastTheEndStops() async {
        await #expect(processExitsWith: .failure) {
            let storage = RawStorage(byteCount: 16, alignment: RawStorage.small)
            _ = storage.bytes(8..<17).byteCount
        }
        await #expect(processExitsWith: .failure) {
            let storage = RawStorage(byteCount: 16, alignment: RawStorage.small)
            // Unsafe: never reached past the check.
            unsafe storage.withMutableBytes(-1..<4) { _ in }
        }
    }

    // MARK: - Text

    @Test func stringDecodingRepairsInvalidUTF8() {
        #expect(String(decoding: Array("héllo".utf8).span.bytes, as: UTF8.self) == "héllo")
        let invalid: [UInt8] = [0x61, 0xFF, 0x62]
        #expect(String(decoding: invalid.span.bytes, as: UTF8.self) == "a\u{FFFD}b")
        #expect(String(decoding: [UInt8]().span.bytes, as: UTF8.self).isEmpty)
    }

    @Test func staticStringBytesAreTheLiteralsUTF8() {
        let literal: StaticString = "Content-Type: é"
        #expect([UInt8](copying: literal.bytes) == Array("Content-Type: é".utf8))
        #expect(("" as StaticString).bytes.byteCount == 0)
        let get: [UInt8] = [0x47, 0x45, 0x54]
        let equal = ("GET" as StaticString).bytes.bytesEqual(get.span.bytes)
        #expect(equal)
    }

    @Test func readUTF8ByteCount() throws {
        let bytes: [UInt8] = Array("hi there".utf8)
        var reader = BytesReader(bytes.span.bytes)
        #expect(try String(copying: reader.read(utf8ByteCount: 2)) == "hi")
        #expect(throws: BytesError.invalidValue) { _ = try reader.read(utf8ByteCount: 3, excluding: { $0.matching(UInt8(ascii: " ")) }) }
        #expect(try String(copying: reader.read(utf8ByteCount: 1)) == " ")
    }

    // MARK: - Words

    @Test func wordsFromChunksMatchLoads() {
        let bytes: [UInt8] = (0..<19).map { UInt8($0 &* 13 &+ 5) }
        let span = bytes.span.bytes
        let words = span.chunks(of: InlineArray<8, UInt8>.self)
        #expect(words.count == 2)
        for index in words.indices {
            let load = span.load(fromByteOffset: index * 8, as: UInt64.self)
            #expect(UInt64(littleEndianBytes: words[index]) == UInt64(littleEndian: load))
            #expect(UInt64(bigEndianBytes: words[index]) == UInt64(bigEndian: load))
        }
        let halves = span.chunks(of: InlineArray<4, UInt8>.self)
        for index in halves.indices {
            let load = span.load(fromByteOffset: index * 4, as: UInt32.self)
            #expect(UInt32(littleEndianBytes: halves[index]) == UInt32(littleEndian: load))
            #expect(UInt32(bigEndianBytes: halves[index]) == UInt32(bigEndian: load))
        }
        #expect(UInt32(bigEndianBytes: [0x12, 0x34, 0x56, 0x78]) == 0x1234_5678)
        #expect(UInt32(littleEndianBytes: [0x12, 0x34, 0x56, 0x78]) == 0x7856_3412)
    }

    // MARK: - Bit counts

    @Test func skippingBitsChecksTheCountWithOneCompare() {
        let bytes: [UInt8] = [0xFF, 0x00]
        var reader = BytesReader(bytes.span.bytes)
        #expect(throws: BytesError.invalidValue) { try reader.skip(bitCount: -1) }
        #expect(throws: BytesError.invalidValue) { try reader.skip(bitCount: .min) }
        #expect(throws: BytesError.insufficientData) { try reader.skip(bitCount: 17) }
        #expect(reader.remainingBitCount == 16) // Nothing consumed.
        try? reader.skip(bitCount: 16)
        #expect(reader.remainingBitCount == 0)
        #expect(throws: BytesError.invalidValue) { try reader.skip(bitCount: -1) }
    }

    @Test func peekingANegativeBitCountStops() async {
        await #expect(processExitsWith: .failure) {
            let bytes: [UInt8] = [0xFF]
            let reader = BytesReader(bytes.span.bytes)
            _ = try? reader.peek(bitCount: -1)
        }
        await #expect(processExitsWith: .failure) {
            let bytes: [UInt8] = [0xFF]
            let reader = BytesReader(bytes.span.bytes)
            _ = try? reader.peek(bitCount: 65)
        }
    }

    @Test func cancellableErrorWrapsAFailure() {
        let failed = CancellableError<BytesError>.failed(.invalidValue)
        #expect(failed != .cancelled && failed == .failed(.invalidValue))
        #expect(failed.description == "invalidValue" && CancellableError<BytesError>.cancelled.description == "cancelled")
    }
}
