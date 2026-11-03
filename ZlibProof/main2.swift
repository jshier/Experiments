import Foundation
import zlib

let input = "Hello, Alamofire! This is a test of the zlib compression format.".data(using: .utf8)!

let compressed = try! (input as NSData).compressed(using: .zlib) as Data

// Print ALL bytes of the compressed output to understand its format
print("=== Full byte dump of compressed(using: .zlib) output (\(compressed.count) bytes) ===")
for (i, byte) in compressed.enumerated() {
    print(String(format: "[%02d] 0x%02X  %08b  %3d", i, byte, byte, byte))
}

// RFC 1950 first byte analysis:
// CM (bits 0-3): compression method (8 = deflate)
// CINFO (bits 4-7): window size (7 = 32KB for deflate)
let cmf = compressed[0]
print("\nCMF byte breakdown: 0x\(String(format: "%02X", cmf))")
print("  CM    (bits 0-3) = \(cmf & 0x0F)  (must be 8 for deflate)")
print("  CINFO (bits 4-7) = \(cmf >> 4)  (7 = 32KB window)")

// Try standard zlib inflate (raw deflate, no wrapper) on the Apple data
// This tells us if Apple output is raw DEFLATE (RFC 1951) or wrapped zlib (RFC 1950)
print("\n=== Attempting raw DEFLATE inflate (no zlib wrapper) on Apple output ===")
var stream = z_stream()
stream.next_in = UnsafeMutablePointer(mutating: compressed.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) })
stream.avail_in = uInt(compressed.count)
var outBuffer = [UInt8](repeating: 0, count: 1024)
stream.next_out = &outBuffer
stream.avail_out = uInt(outBuffer.count)

// inflateInit2 with -15 = raw deflate (no zlib header)
var ret = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
print("inflateInit2 (raw deflate): \(ret == Z_OK ? "OK" : "FAIL (\(ret))")")
if ret == Z_OK {
    ret = inflate(&stream, Z_FINISH)
    let produced = outBuffer.prefix(outBuffer.count - Int(stream.avail_out))
    print("inflate result: \(ret) (Z_STREAM_END=\(Z_STREAM_END), Z_OK=\(Z_OK))")
    print("Produced \(produced.count) bytes")
    if let str = String(bytes: produced, encoding: .utf8), str == String(data: input, encoding: .utf8) {
        print("✅ Raw DEFLATE inflate MATCHES input — Apple uses raw DEFLATE internally, possibly with a custom wrapper")
    } else {
        print("❌ Raw DEFLATE inflate did NOT match")
    }
    inflateEnd(&stream)
}

// Now try standard zlib inflate (with zlib wrapper, wbits=15)
print("\n=== Attempting zlib-wrapped inflate (RFC 1950) on Apple output ===")
var stream2 = z_stream()
stream2.next_in = UnsafeMutablePointer(mutating: compressed.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) })
stream2.avail_in = uInt(compressed.count)
var outBuffer2 = [UInt8](repeating: 0, count: 1024)
stream2.next_out = &outBuffer2
stream2.avail_out = uInt(outBuffer2.count)
ret = inflateInit2_(&stream2, 15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
print("inflateInit2 (zlib wrapper): \(ret == Z_OK ? "OK" : "FAIL (\(ret))")")
if ret == Z_OK {
    ret = inflate(&stream2, Z_FINISH)
    let produced2 = outBuffer2.prefix(outBuffer2.count - Int(stream2.avail_out))
    print("inflate result: \(ret) (Z_STREAM_END=\(Z_STREAM_END), Z_OK=\(Z_OK))")
    if let str = String(bytes: produced2, encoding: .utf8), str == String(data: input, encoding: .utf8) {
        print("✅ Zlib-wrapped inflate MATCHES — output IS standard RFC 1950")
    } else {
        print("❌ Zlib-wrapped inflate did NOT match (Apple format is NOT standard RFC 1950)")
    }
    inflateEnd(&stream2)
}

// Now try Alamofire's actual deflate() output against both
print("\n=== Testing Alamofire's deflate() output ===")
var afOutput = Data([0x78, 0x5E])
afOutput.append(compressed)
let adler = input.withUnsafeBytes { buf in UInt32(adler32(1, buf.baseAddress, UInt32(buf.count))) }
var adlerBE = adler.bigEndian
afOutput.append(Data(bytes: &adlerBE, count: 4))
print("Alamofire output: \(afOutput.count) bytes, first bytes: \(afOutput.prefix(6).map { String(format: "0x%02X", $0) }.joined(separator: " "))")

var stream3 = z_stream()
stream3.next_in = UnsafeMutablePointer(mutating: afOutput.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) })
stream3.avail_in = uInt(afOutput.count)
var outBuffer3 = [UInt8](repeating: 0, count: 1024)
stream3.next_out = &outBuffer3
stream3.avail_out = uInt(outBuffer3.count)
ret = inflateInit2_(&stream3, 15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
if ret == Z_OK {
    ret = inflate(&stream3, Z_FINISH)
    let produced3 = outBuffer3.prefix(outBuffer3.count - Int(stream3.avail_out))
    print("zlib inflate of AF output: result=\(ret), produced=\(produced3.count) bytes")
    if let str = String(bytes: produced3, encoding: .utf8), str == String(data: input, encoding: .utf8) {
        print("✅ Alamofire's deflate() IS decompressible by standard zlib")
    } else {
        print("❌ Alamofire's deflate() is NOT decompressible by standard zlib")
    }
    inflateEnd(&stream3)
}
