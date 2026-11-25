import Bytes
import BytesCompression
import BytesTestSupport
import Foundation
import NativeZip
import Testing
import zlib

/// Encrypted entries decode from staged input: each fill decrypts as much as the staging buffer takes. A Zstandard entry
/// of two frames whose first ends exactly where the first fill does was refused ("Size mismatch … expected 263132
/// bytes, got 262132"): the first frame's end was read as the entry's. Frames one byte shorter or longer decoded.
@Suite(.diskLifetimes) struct StagedInputTests {
    /// ZipCrypto (PKWARE's traditional encryption) of `plain` with `password`: the 12-byte header (its last byte the
    /// CRC's high byte, the check), then the data.
    static func zipCrypto(_ plain: [UInt8], password: String, crc: UInt32) -> [UInt8] {
        var keys: (UInt32, UInt32, UInt32) = (0x1234_5678, 0x2345_6789, 0x3456_7890)
        func crcByte(_ value: UInt32, _ byte: UInt8) -> UInt32 {
            var c = (value ^ UInt32(byte)) & 0xFF
            for _ in 0..<8 {
                c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
            }
            return c ^ (value >> 8)
        }
        func update(_ byte: UInt8) {
            keys.0 = crcByte(keys.0, byte)
            keys.1 = (keys.1 &+ (keys.0 & 0xFF)) &* 134_775_813 &+ 1
            keys.2 = crcByte(keys.2, UInt8(keys.1 >> 24))
        }
        func keyByte() -> UInt8 {
            let t = (keys.2 | 2) & 0xFFFF
            return UInt8(truncatingIfNeeded: (t &* (t ^ 1)) >> 8)
        }
        for byte in password.utf8 {
            update(byte)
        }
        var header = SampleBytes.random(11, seed: 5)
        header.append(UInt8(crc >> 24))
        var output: [UInt8] = []
        output.reserveCapacity(12 + plain.count)
        for byte in header + plain {
            output.append(byte ^ keyByte())
            update(byte)
        }
        return output
    }

    /// One Zstandard frame of `count` random bytes (stored blocks: its size follows `count` byte for byte).
    static func frame(_ count: Int, seed: UInt64) throws -> (data: [UInt8], frame: [UInt8]) {
        let data = SampleBytes.random(count, seed: seed)
        var compressor = Compressor()
        try compressor.reset(for: .zstd(level: 1))
        var output = [UInt8](repeating: 0, count: count + 4096)
        let written = try output.withOutputRawSpan { span throws(BytesError) -> Int in
            try compressor.compressAll(data.span.bytes, into: &span)
            return span.byteCount
        }
        return (data, Array(output.prefix(written)))
    }

    /// The first frame `delta` bytes from the staging buffer's size (0: exactly where the first fill ends), then a
    /// second frame: the entry decodes whole, with its password.
    @Test(arguments: [-1, 0, 1])
    func twoFramesWithTheFirstEndingAtAFill(delta: Int) throws {
        let target = ChunkedDecompressor.stagingCapacity(for: .zstd()) + delta
        // Find the data size whose frame is `target` bytes (stored blocks: a byte of data is a byte of frame).
        var count = target - 32
        var first = try Self.frame(count, seed: 1)
        while first.frame.count != target {
            count += target - first.frame.count
            first = try Self.frame(count, seed: 1)
        }
        let second = try Self.frame(1_000, seed: 2)
        let plain = first.data + second.data
        let crc = UInt32(plain.withUnsafeBufferPointer { crc32(0, $0.baseAddress, uInt($0.count)) })
        let payload = Self.zipCrypto(first.frame + second.frame, password: "secret", crc: crc)

        let temporary = try TemporaryDirectory(prefix: "NativeZipStaged")
        defer { temporary.remove() }
        let url = try HostileSizeTests.archive([
            HostileSizeTests.Entry(name: "frames", data: plain, flags: 1, method: 93, payload: payload),
        ], in: temporary.url)
        let archive = try ZipArchive(url: url)
        let entry = try #require(archive.entries.first)
        #expect(try archive.contents(of: entry, password: "secret") == Data(plain))
    }

    /// An encrypted LZMA entry whose stream ends with its marker (flag bit 1) and decodes past its recorded size, streamed
    /// from staged input: the decoder stops at the first byte past the size (BytesCompression's `.lzma(maximumSize:)`;
    /// NativeZip counted chunks itself before), a size mismatch one byte past. At its own size it decodes.
    @Test func endMarkerLZMAPastItsSizeStopsThere() throws {
        let vector = LZMAVector.named("text-marker")
        let temporary = try TemporaryDirectory(prefix: "NativeZipStagedLZMA")
        defer { temporary.remove() }
        for size in [vector.size - 1, vector.size / 2, vector.size] {
            let data = Array(vector.expected.prefix(size))
            let crc = UInt32(data.withUnsafeBufferPointer { crc32(0, $0.baseAddress, uInt($0.count)) })
            let payload = Self.zipCrypto(vector.payload, password: "secret", crc: crc)
            let url = try HostileSizeTests.archive([
                // Encrypted (bit 0), and the stream ends with its marker (bit 1).
                HostileSizeTests.Entry(name: "past", data: data, flags: 3, method: 14, payload: payload),
            ], in: temporary.url)
            let archive = try ZipArchive(url: url)
            let entry = try #require(archive.entries.first)
            let outcome = Result { () throws(ZipError) in try archive.contents(of: entry, password: "secret") }
            if size == vector.size {
                #expect(outcome == .success(Data(data)))
            } else {
                #expect(outcome == .failure(.sizeMismatch("past", expected: UInt64(size), actual: UInt64(size + 1))), "size \(size)")
            }
        }
    }
}
