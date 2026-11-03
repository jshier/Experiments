import Foundation
import zlib

let input = "Hello, Alamofire! This is a test of the zlib compression format.".data(using: .utf8)!
let compressed = try! (input as NSData).compressed(using: .zlib) as Data

// Write Apple output
try! compressed.write(to: URL(fileURLWithPath: "/tmp/apple_compressed.bin"))
print("Apple compressed: \(compressed.count) bytes, first 4: \(compressed.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " "))")

// Write Alamofire output
var afOutput = Data([0x78, 0x5E])
afOutput.append(compressed)
let adler = input.withUnsafeBytes { buf in UInt32(adler32(1, buf.baseAddress, UInt32(buf.count))) }
var adlerBE = adler.bigEndian
afOutput.append(Data(bytes: &adlerBE, count: 4))
try! afOutput.write(to: URL(fileURLWithPath: "/tmp/alamofire_deflate.bin"))
print("Alamofire deflate: \(afOutput.count) bytes, first 4: \(afOutput.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " "))")
