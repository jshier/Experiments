import Benchmark
import Bytes
import BytesCrypto
import BytesTestSupport
import Foundation
import Security

// scrypt at N = 2^14 through 2^20, r = 8, p = 1, in caller scratch memory and allocating (OpenSSL's times, from
// Python's `hashlib.scrypt` in one process, are in Bytes' RESULTS-scrypt-x509.md: no C reference is linked here); and X.509
// certificate parsing, against Security's `SecCertificateCreateWithData`.

/// Scratch memory for the scrypt benchmarks, made by the first one's setup (1 GiB for N = 2^20) rather than at
/// registration, so other benchmarks in this executable don't carry it.
nonisolated(unsafe) var scryptScratch: [UInt8] = []

func registerScryptBenchmarks() {
    let password = Array("pleaseletmein".utf8)
    let salt = Array("SodiumChloride".utf8)
    // 2^14 and 2^20: time is linear in N (2^16 and 2^18 were retired on 2026-11-19; Bytes' RESULTS-scrypt-x509.md has them).
    for log2N in [14, 20] {
        let n = 1 << log2N
        // 2^14 takes 20 ms (10 samples), 2^20 1.2 s (2).
        let configuration = Benchmark.Configuration(
            metrics: [.wallClock, .instructions, .throughput],
            warmupIterations: 1,
            maxDuration: .seconds(log2N >= 20 ? 2 : 1),
            maxIterations: log2N >= 20 ? 2 : 10
        )
        let needed = try! Scrypt.scratchByteCount(cost: n, blockSize: 8, parallelism: 1)
        var scratchKey = [UInt8](repeating: 0, count: 32)
        Benchmark("scrypt N=2^\(log2N) r=8 p=1: Bytes, scratch", configuration: configuration) { benchmark in
            for _ in benchmark.scaledIterations {
                var keySpan = scratchKey.mutableSpan
                var keyBytes = MutableRawSpan(mutating: &keySpan)
                var scratchSpan = scryptScratch.mutableSpan
                var scratchBytes = MutableRawSpan(mutating: &scratchSpan)
                try! Scrypt.deriveKey(password: password.span.bytes, salt: salt.span.bytes, cost: n, blockSize: 8, parallelism: 1,
                                      scratch: &scratchBytes, into: &keyBytes)
            }
            blackHole(scratchKey[0])
        } setup: {
            if scryptScratch.count < needed { scryptScratch = [UInt8](repeating: 0, count: needed) }
        }
        // Allocating its scratch per call: at the small N only (the allocation is the same few calls at any N).
        guard log2N == 14 else { continue }
        var allocatingKey = [UInt8](repeating: 0, count: 32)
        Benchmark("scrypt N=2^\(log2N) r=8 p=1: Bytes, allocating", configuration: configuration) { benchmark in
            for _ in benchmark.scaledIterations {
                var keySpan = allocatingKey.mutableSpan
                var keyBytes = MutableRawSpan(mutating: &keySpan)
                try! Scrypt.deriveKey(password: password.span.bytes, salt: salt.span.bytes, cost: n, blockSize: 8, parallelism: 1,
                                      into: &keyBytes)
            }
            blackHole(allocatingKey[0])
        }
    }
    // p = 4 on one lane and on four: the threads' speedup.
    for lanes in [1, 4] {
        let configuration = Benchmark.Configuration(metrics: [.wallClock, .instructions], warmupIterations: 1, maxDuration: .seconds(1), maxIterations: 10)
        var key = [UInt8](repeating: 0, count: 32)
        // Made by setup (64 MiB), not while registering.
        var scratch: [UInt8] = []
        Benchmark("scrypt N=2^14 r=8 p=4: Bytes, \(lanes) lanes", configuration: configuration) { benchmark in
            for _ in benchmark.scaledIterations {
                var keySpan = key.mutableSpan
                var keyBytes = MutableRawSpan(mutating: &keySpan)
                var scratchSpan = scratch.mutableSpan
                var scratchBytes = MutableRawSpan(mutating: &scratchSpan)
                try! Scrypt.deriveKey(password: password.span.bytes, salt: salt.span.bytes, cost: 1 << 14, blockSize: 8, parallelism: 4,
                                      lanes: lanes, scratch: &scratchBytes, into: &keyBytes)
            }
            blackHole(key[0])
        } setup: {
            scratch = [UInt8](repeating: 0, count: try! Scrypt.scratchByteCount(cost: 1 << 14, blockSize: 8, parallelism: 4, lanes: lanes))
        }
    }
    // The zero-malloc gate (Thresholds/), at a small N.
    let allocationConfiguration = Benchmark.Configuration(
        metrics: [.mallocCountTotal], warmupIterations: 1, maxIterations: 10,
        thresholds: [.mallocCountTotal: BenchmarkThresholds(absolute: [.p0: 0, .p50: 0, .p90: 0, .p100: 0])]
    )
    var smallKey = [UInt8](repeating: 0, count: 64)
    var smallScratch: [UInt8] = [] // Made by setup.
    Benchmark("Allocations:Scrypt_N1024_r8_p2_scratch", configuration: allocationConfiguration) { benchmark in
        for _ in benchmark.scaledIterations {
            var keySpan = smallKey.mutableSpan
            var keyBytes = MutableRawSpan(mutating: &keySpan)
            var scratchSpan = smallScratch.mutableSpan
            var scratchBytes = MutableRawSpan(mutating: &scratchSpan)
            try! Scrypt.deriveKey(password: password.span.bytes, salt: salt.span.bytes, cost: 1 << 10, blockSize: 8, parallelism: 2,
                                  scratch: &scratchBytes, into: &keyBytes)
        }
        blackHole(smallKey[0])
    } setup: {
        smallScratch = [UInt8](repeating: 0, count: try! Scrypt.scratchByteCount(cost: 1 << 10, blockSize: 8, parallelism: 2))
    }
}

/// A system root certificate as PEM, from `security`.
func systemRootCertificatePEM(named name: String) -> [UInt8] {
    try! ExternalTool.output("/usr/bin/security", ["find-certificate", "-c", name, "-p", "/System/Library/Keychains/SystemRootCertificates.keychain"])
}

/// A system root certificate's DER, from `security`.
func systemRootCertificate(named name: String) -> [UInt8] {
    try! X509Certificate.decodePEM(systemRootCertificatePEM(named: name).span.bytes)[0]
}

func registerX509Benchmarks() {
    // Apple Root CA - G3: ECDSA P-384, 583 bytes, 3 extensions. ACCVRAIZ1: RSA 4096, 2,007 bytes, 9 extensions (the most
    // of the system's roots).
    let samples = [("Apple Root CA - G3", "G3"), ("ACCVRAIZ1", "ACCVRAIZ1")]
    let configuration = Benchmark.Configuration(metrics: [.wallClock, .instructions, .throughput], scalingFactor: .kilo)
    let allocationConfiguration = Benchmark.Configuration(
        metrics: [.mallocCountTotal], warmupIterations: 1, maxIterations: 10,
        thresholds: [.mallocCountTotal: BenchmarkThresholds(absolute: [.p0: 0, .p50: 0, .p90: 0, .p100: 0])]
    )
    for (name, label) in samples {
        let certificate = Lazy {
            let der = systemRootCertificate(named: name)
            // Checked once: the fields the benchmarks read.
            let checked = try! X509Certificate(derEncoded: der.span.bytes)
            precondition(checked.tbsCertificate.byteCount > 0 && checked.publicKey.byteCount > 0)
            return der
        }
        let data = Lazy { Data(certificate.value) }
        Benchmark("X.509 parse \(label) (x1000): Bytes", configuration: configuration) { benchmark in
            let der = certificate.value
            for _ in benchmark.scaledIterations {
                let certificate = try! X509Certificate(derEncoded: der.span.bytes)
                blackHole(certificate.notAfter.year)
            }
        } setup: { _ = certificate.value }
        // The fields a chain check reads: names, key, signature, constraints, and each extension (no strings).
        Benchmark("X.509 parse and read \(label) (x1000): Bytes", configuration: configuration) { benchmark in
            let der = certificate.value
            for _ in benchmark.scaledIterations {
                let certificate = try! X509Certificate(derEncoded: der.span.bytes)
                var total = certificate.issuer.der.byteCount &+ certificate.subject.der.byteCount &+ certificate.publicKey.byteCount
                total &+= certificate.signature.byteCount &+ certificate.tbsCertificate.byteCount
                total &+= certificate.basicConstraints?.pathLengthConstraint ?? 0
                total &+= Int(certificate.keyUsage?.rawValue ?? 0)
                var extensions = certificate.extensions
                while let item = extensions.next() {
                    total &+= item.value.byteCount
                }
                blackHole(total)
            }
        } setup: { _ = certificate.value }
        // From PEM text: the block found, its Base64 decoded (BytesBase64, skipping the line breaks), then parsed.
        // (Security has no PEM certificate parser to compare with but `SecItemImport`, a keychain import.)
        let pem = Lazy {
            let pem = systemRootCertificatePEM(named: name)
            precondition(try! X509Certificate.decodePEM(pem.span.bytes) == [certificate.value])
            return pem
        }
        Benchmark("X.509 PEM decode and parse \(label) (x1000): Bytes", configuration: configuration) { benchmark in
            let pem = pem.value
            for _ in benchmark.scaledIterations {
                let der = try! PEM.decodeAll(pem.span.bytes, label: "CERTIFICATE")[0]
                let certificate = try! X509Certificate(derEncoded: der.span.bytes)
                blackHole(certificate.notAfter.year)
            }
        } setup: { _ = pem.value }
        Benchmark("X.509 parse \(label) (x1000): Security", configuration: configuration) { benchmark in
            let data = data.value
            for _ in benchmark.scaledIterations {
                blackHole(SecCertificateCreateWithData(nil, data as CFData))
            }
        } setup: { _ = data.value }
        Benchmark("Allocations:X509_parse_and_read_\(label)", configuration: allocationConfiguration) { benchmark in
            let der = certificate.value
            for _ in benchmark.scaledIterations {
                let certificate = try! X509Certificate(derEncoded: der.span.bytes)
                var total = certificate.issuer.der.byteCount &+ certificate.publicKey.byteCount &+ certificate.signatureAlgorithm.contents.byteCount
                var extensions = certificate.extensions
                while let item = extensions.next() {
                    total &+= item.identifier.contents.byteCount
                }
                blackHole(total)
            }
        } setup: { _ = certificate.value }
    }
}
