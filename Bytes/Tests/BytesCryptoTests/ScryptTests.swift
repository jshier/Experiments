import Bytes
@testable import BytesCrypto
import BytesTestSupport
import Foundation
import Testing

// scrypt: RFC 7914's vectors, then random parameters against OpenSSL (Python's `hashlib.scrypt`, which calls
// `EVP_PBE_scrypt`), with caller scratch and with the allocating form, one lane and several.

func scrypt(
    _ password: [UInt8], _ salt: [UInt8], n: Int, r: Int, p: Int, lanes: Int = 1, length: Int, allocating: Bool = false
) throws(BytesError) -> [UInt8] {
    var key = [UInt8](repeating: 0, count: length)
    var keySpan = key.mutableSpan
    var keyBytes = MutableRawSpan(mutating: &keySpan)
    if allocating {
        try Scrypt.deriveKey(password: password.span.bytes, salt: salt.span.bytes, cost: n, blockSize: r, parallelism: p,
                             lanes: lanes, into: &keyBytes)
    } else {
        var scratch = [UInt8](repeating: 0xA5, count: try Scrypt.scratchByteCount(cost: n, blockSize: r, parallelism: p, lanes: lanes))
        var scratchSpan = scratch.mutableSpan
        var scratchBytes = MutableRawSpan(mutating: &scratchSpan)
        try Scrypt.deriveKey(password: password.span.bytes, salt: salt.span.bytes, cost: n, blockSize: r, parallelism: p,
                             lanes: lanes, scratch: &scratchBytes, into: &keyBytes)
    }
    return key
}

/// `hashlib.scrypt`'s key for each parameter set, from one `python3 -I` run (OpenSSL underneath); nil without Python.
func referenceScrypt(_ cases: [(password: [UInt8], salt: [UInt8], n: Int, r: Int, p: Int, length: Int)]) -> [[UInt8]]? {
    let lines = cases.map { "\(Data($0.password).base64EncodedString()) \(Data($0.salt).base64EncodedString()) \($0.n) \($0.r) \($0.p) \($0.length)" }
    let script = """
    import base64, hashlib, sys
    for line in sys.stdin.read().split("\\n"):
        if not line: continue
        pw, salt, n, r, p, length = line.split(" ")
        print(hashlib.scrypt(base64.b64decode(pw), salt=base64.b64decode(salt), n=int(n), r=int(r), p=int(p),
                             maxmem=2**31 - 1, dklen=int(length)).hex())
    """
    guard let output = run("/usr/bin/env", ["python3", "-I", "-c", script], input: Data(lines.joined(separator: "\n").utf8)) else { return nil }
    let keys = String(decoding: output, as: UTF8.self).split(separator: "\n").map { hex(String($0)) }
    return keys.count == cases.count ? keys : nil
}

/// Whether the tests were compiled with optimization (`swift test -c release`), for tests too slow otherwise.
#if DEBUG
let isOptimizedBuild = false
#else
let isOptimizedBuild = true
#endif

/// Runs a program, returning its standard output, or nil if it couldn't run or failed.
func run(_ path: String, _ arguments: [String], input: Data? = nil, directory: URL? = nil) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = directory }
    let output = Pipe(), errors = Pipe(), stdin = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = stdin
    do { try process.run() } catch { return nil }
    if let input { stdin.fileHandleForWriting.write(input) }
    try? stdin.fileHandleForWriting.close()
    // Read both pipes to the end before waiting, so neither fills and blocks the child (standard error is drained
    // and dropped: nothing is shared between the threads).
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { _ = errors.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? data : nil
}

@Suite struct ScryptTests {
    @Test func rfc7914Vectors() throws {
        #expect(try scrypt([], [], n: 16, r: 1, p: 1, length: 64) == hex(
            "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906"))
        let nacl = hex("fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640")
        #expect(try scrypt(Array("password".utf8), Array("NaCl".utf8), n: 1024, r: 8, p: 16, length: 64) == nacl)
        #expect(try scrypt(Array("password".utf8), Array("NaCl".utf8), n: 1024, r: 8, p: 16, lanes: 4, length: 64) == nacl)
        #expect(try scrypt(Array("password".utf8), Array("NaCl".utf8), n: 1024, r: 8, p: 16, lanes: 16, length: 64, allocating: true) == nacl)
        #expect(try scrypt(Array("pleaseletmein".utf8), Array("SodiumChloride".utf8), n: 16384, r: 8, p: 1, length: 64, allocating: true) == hex(
            "7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2d5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887"))
    }

    /// RFC 7914's last vector: N = 2²⁰, a 1 GiB table. Optimized builds only (`swift test -c release`): 30 seconds
    /// in a debug build.
    @Test(.enabled(if: isOptimizedBuild)) func rfc7914LargeVector() throws {
        #expect(try scrypt(Array("pleaseletmein".utf8), Array("SodiumChloride".utf8), n: 1 << 20, r: 8, p: 1, length: 64, allocating: true) == hex(
            "2101cb9b6a511aaeaddbbe09cf70f881ec568d574a2ffd4dabe5ee9820adaa478e56fd8f4ba5d09ffa1c6d927c40f4c337304049e8a952fbcbf45c6fa77a41a4"))
    }

    @Test func matchesOpenSSL() throws {
        var rng = SplitMix64(seed: 7914)
        var cases: [(password: [UInt8], salt: [UInt8], n: Int, r: Int, p: Int, length: Int)] = []
        for _ in 0..<40 {
            let n = 1 << Int.random(in: 1...12, using: &rng)
            let r = Int.random(in: 1...9, using: &rng)
            let p = Int.random(in: 1...4, using: &rng)
            cases.append((randomBytes(Int.random(in: 0...80, using: &rng), using: &rng), randomBytes(Int.random(in: 0...40, using: &rng), using: &rng),
                          n, r, p, Int.random(in: 1...100, using: &rng)))
        }
        let expected = try #require(referenceScrypt(cases), "python3 with hashlib.scrypt is needed for this test")
        for (index, test) in cases.enumerated() {
            let lanes = index % 3 == 0 ? test.p : 1
            let key = try scrypt(test.password, test.salt, n: test.n, r: test.r, p: test.p, lanes: lanes, length: test.length, allocating: index % 2 == 0)
            #expect(key == expected[index], "N \(test.n), r \(test.r), p \(test.p), \(lanes) lanes, \(test.length) bytes")
        }
    }

    @Test func rejectsInvalidParameters() throws {
        for (n, r, p) in [(0, 8, 1), (1, 8, 1), (3, 8, 1), (1000, 8, 1), (16, 0, 1), (16, 8, 0), (16, 1 << 15, 1 << 15), (1 << 16, 1, 1)] {
            #expect(throws: BytesError.invalidValue, "N \(n), r \(r), p \(p)") { _ = try Scrypt.scratchByteCount(cost: n, blockSize: r, parallelism: p) }
        }
        #expect(throws: BytesError.invalidValue) { _ = try Scrypt.scratchByteCount(cost: 1 << 62, blockSize: 8, parallelism: 1) }
        // N = 2^15 with r = 1 is the largest N r = 1 allows.
        #expect(try Scrypt.scratchByteCount(cost: 1 << 15, blockSize: 1, parallelism: 1) == ((1 << 15) + 2) * 128 + 128)
        let password: [UInt8] = [1, 2, 3]
        var scratch = [UInt8](repeating: 0, count: 100)
        var scratchSpan = scratch.mutableSpan
        var scratchBytes = MutableRawSpan(mutating: &scratchSpan)
        var key = [UInt8](repeating: 0, count: 32)
        var keySpan = key.mutableSpan
        var keyBytes = MutableRawSpan(mutating: &keySpan)
        #expect(throws: BytesError.insufficientCapacity) {
            try Scrypt.deriveKey(password: password.span.bytes, salt: password.span.bytes, cost: 16, blockSize: 1, parallelism: 1,
                                 scratch: &scratchBytes, into: &keyBytes)
        }
    }
}
