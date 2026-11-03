import Foundation
import zlib

// ── Test data ───────────────────────────────────────────────────────────────
let input = "Hello, Alamofire! This is a test of the zlib compression format.".data(using: .utf8)!

// ── 1. What does NSData.compressed(using: .zlib) actually produce? ──────────
let compressed = try! (input as NSData).compressed(using: .zlib) as Data

print("=== NSData.compressed(using: .zlib) ===")
print("Input length : \(input.count) bytes")
print("Output length: \(compressed.count) bytes")
print("First 2 bytes (CMF+FLG): \(compressed.prefix(2).map { String(format: "0x%02X", $0) }.joined(separator: " "))")
print("Last  4 bytes (checksum): \(compressed.suffix(4).map { String(format: "0x%02X", $0) }.joined(separator: " "))")

// RFC 1950 zlib first byte (CMF) must be 0x78 for deflate with 32KB window.
// Valid CMF+FLG pairs: 0x78 0x01, 0x78 0x5E, 0x78 0x9C, 0x78 0xDA
let cmf = compressed[0]
let flg = compressed[1]
let isValidZlibHeader = cmf == 0x78 && (Int(cmf) * 256 + Int(flg)) % 31 == 0
print("Is valid RFC 1950 zlib header (CMF=0x78, CMF*256+FLG divisible by 31): \(isValidZlibHeader)")

// ── 2. Compute expected Adler-32 of the INPUT and compare to last 4 bytes ──
let adler = input.withUnsafeBytes { buf in
    UInt32(adler32(1, buf.baseAddress, UInt32(buf.count)))
}
let adlerBigEndian = adler.bigEndian
let adlerBytes = withUnsafeBytes(of: adlerBigEndian) { Data($0) }
let lastFour = compressed.suffix(4)
print("\nExpected Adler-32 of input (big-endian): \(adlerBytes.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
print("Last 4 bytes of compressed output:       \(lastFour.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
print("Last 4 bytes match Adler-32 of input: \(lastFour == adlerBytes)")

// ── 3. Verify round-trip decompression works ────────────────────────────────
let decompressed = try! (compressed as NSData).decompressed(using: .zlib) as Data
print("\nRound-trip decompression matches original: \(decompressed == input)")

// ── 4. Now demonstrate what DeflateRequestCompressor.deflate() actually does ─
print("\n=== DeflateRequestCompressor.deflate() simulation ===")
var output = Data([0x78, 0x5E])  // the header Alamofire prepends
output.append(compressed)         // appends the FULL zlib stream (already has header+checksum)
var checksum = adler.bigEndian
output.append(Data(bytes: &checksum, count: MemoryLayout<UInt32>.size))  // appends ANOTHER checksum

print("Alamofire deflate() output length: \(output.count) bytes")
print("Bytes 0-1   (Alamofire header):    \(output.prefix(2).map { String(format: "0x%02X", $0) }.joined(separator: " "))")
print("Bytes 2-3   (inner zlib header):   \(output.dropFirst(2).prefix(2).map { String(format: "0x%02X", $0) }.joined(separator: " "))")
print("Last 4 bytes (duplicate checksum): \(output.suffix(4).map { String(format: "0x%02X", $0) }.joined(separator: " "))")

// ── 5. Try to decompress Alamofire's output — should fail ──────────────────
print("\n=== Decompression of Alamofire deflate() output ===")
do {
    let attempt = try (output as NSData).decompressed(using: .zlib) as Data
    print("Decompression SUCCEEDED (unexpected!) — result: \(String(data: attempt, encoding: .utf8) ?? "<binary>")")
} catch {
    print("Decompression FAILED (expected — output is corrupt): \(error)")
}

// ── 6. Show what the CORRECT implementation should produce ─────────────────
print("\n=== Correct implementation: just return compressed(using: .zlib) ===")
let correct = compressed  // already a valid RFC 1950 zlib stream
do {
    let verify = try (correct as NSData).decompressed(using: .zlib) as Data
    print("Correct output decompresses successfully: \(verify == input)")
} catch {
    print("Correct output failed: \(error)")
}
