import Benchmark
import Bytes
import BytesCompression
import BytesCrypto
import CryptoKit
import Foundation

// Encryption against CryptoKit, and pipelines: compression and encryption composed, as a server sending
// HTTP-compressed bodies over TLS does, and back.

func registerCryptoBenchmarks() {
    let key = [UInt8](repeating: 0x42, count: 32)
    let nonce = [UInt8](repeating: 0x07, count: 12)
    let aad = [UInt8](repeating: 0x17, count: 5)
    let aead = ChaCha20Poly1305(key: key.span.bytes)
    let chachaKey = SymmetricKey(data: key)
    let gcmKey = SymmetricKey(data: key.prefix(16))
    let chachaNonce = try! ChaChaPoly.Nonce(data: nonce)
    let gcmNonce = try! AES.GCM.Nonce(data: nonce)
    for size in [64, 1_024, 16_384, 1 << 20] {
        let label = size >= 1 << 20 ? "1 MB" : size >= 1024 ? "\(size / 1024) KB" : "\(size) B"
        var message = (0..<size).map { UInt8(truncatingIfNeeded: $0) }
        let data = Data(message)
        // 1 MB per iteration, in messages of `size`: per-call costs show for short messages.
        let repeats = max(1, (1 << 20) / size)
        Benchmark("ChaCha20-Poly1305 seal \(label) (x\(repeats)): Bytes") { benchmark in
            for _ in benchmark.scaledIterations {
                for _ in 0..<repeats {
                    var span = message.mutableSpan
                    var raw = MutableRawSpan(mutating: &span)
                    blackHole(aead.seal(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes))
                }
            }
        }
        Benchmark("ChaCha20-Poly1305 seal \(label) (x\(repeats)): CryptoKit") { benchmark in
            for _ in benchmark.scaledIterations {
                for _ in 0..<repeats {
                    blackHole(try! ChaChaPoly.seal(data, using: chachaKey, nonce: chachaNonce, authenticating: aad))
                }
            }
        }
        Benchmark("AES-128-GCM seal \(label) (x\(repeats)): CryptoKit") { benchmark in
            for _ in benchmark.scaledIterations {
                for _ in 0..<repeats {
                    blackHole(try! AES.GCM.seal(data, using: gcmKey, nonce: gcmNonce, authenticating: aad))
                }
            }
        }
    }
}

/// Compress-then-seal and open-then-decompress pipelines over web assets: a flush per 16 KB of input sent,
/// 64 KB pieces received. Each iteration is one whole stream through pipelines built once and reset.
func registerPipelineBenchmarks() {
    let keys = TLSKeySchedule.applicationKeys(sharedSecret: [UInt8](repeating: 3, count: 32).span.bytes).server
    for sample in Fixtures.samples where sample.name == "Main.js" || sample.name == "JSON" {
        var wire = [UInt8](repeating: 0, count: sample.bytes.count * 2 + (1 << 20))
        var plain = [UInt8](repeating: 0, count: sample.bytes.count + (1 << 20))
        var deflateSend = DeflateEncoder(format: .raw, level: 1).then(TLSRecordSealer(keys: keys))
        var deflateReceive = TLSRecordOpener(keys: keys).then(DeflateDecoder(format: .raw))
        var brotliSend = BrotliEncoder(quality: 5, windowBits: 18).then(TLSRecordSealer(keys: keys))
        var brotliReceive = TLSRecordOpener(keys: keys).then(BrotliDecoder())
        // The streams to receive: each sender's first, records numbered from 0. (The count first: in
        // `wire.prefix(send(into: &wire))`, `wire` is read before the send writes, so the prefix is of the old,
        // empty array.)
        let deflateCount = pipelineSend(&deflateSend, sample.bytes, into: &wire)
        let deflateWire = Array(wire.prefix(deflateCount))
        let brotliCount = pipelineSend(&brotliSend, sample.bytes, into: &wire)
        let brotliWire = Array(wire.prefix(brotliCount))
        precondition(pipelineReceive(&deflateReceive, deflateWire, into: &plain) == sample.bytes.count)
        precondition(plain.prefix(sample.bytes.count).elementsEqual(sample.bytes))
        precondition(pipelineReceive(&brotliReceive, brotliWire, into: &plain) == sample.bytes.count)
        precondition(plain.prefix(sample.bytes.count).elementsEqual(sample.bytes))
        Benchmark("Pipeline deflate 1 + TLS send \(sample.label): Bytes") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(pipelineSend(&deflateSend, sample.bytes, into: &wire))
            }
        }
        Benchmark("Pipeline TLS + inflate receive \(sample.label): Bytes") { benchmark in
            for _ in benchmark.scaledIterations {
                deflateReceive.first.reset(sequence: 0)
                blackHole(pipelineReceive(&deflateReceive, deflateWire, into: &plain))
            }
        }
        // The same work as two passes through a buffer of the whole stream, no pipeline: its overhead.
        var deflateAlone = DeflateEncoder(format: .raw, level: 1)
        var sealerAlone = TLSRecordSealer(keys: keys)
        var openerAlone = TLSRecordOpener(keys: keys)
        var inflateAlone = DeflateDecoder(format: .raw)
        var middle = [UInt8](repeating: 0, count: sample.bytes.count * 2 + (1 << 20))
        Benchmark("Two passes deflate 1, then TLS send \(sample.label): Bytes") { benchmark in
            for _ in benchmark.scaledIterations {
                let compressed = pipelineSend(&deflateAlone, sample.bytes, into: &middle)
                blackHole(pipelineSend(&sealerAlone, middle, count: compressed, into: &wire))
            }
        }
        Benchmark("Two passes TLS, then inflate receive \(sample.label): Bytes") { benchmark in
            for _ in benchmark.scaledIterations {
                openerAlone.reset(sequence: 0)
                let opened = pipelineReceive(&openerAlone, deflateWire, into: &middle)
                blackHole(pipelineReceive(&inflateAlone, middle, count: opened, into: &plain))
            }
        }
        Benchmark("Pipeline brotli 5 + TLS send \(sample.label): Bytes") { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(pipelineSend(&brotliSend, sample.bytes, into: &wire))
            }
        }
        Benchmark("Pipeline TLS + brotli receive \(sample.label): Bytes") { benchmark in
            for _ in benchmark.scaledIterations {
                brotliReceive.first.reset(sequence: 0)
                blackHole(pipelineReceive(&brotliReceive, brotliWire, into: &plain))
            }
        }
    }
}

/// One stream through a sending pipeline, a flush per 16 KB of input (`input`'s first `count` bytes): returns
/// the bytes out.
@inline(__always)
func pipelineSend<P: ResettableByteTransform & ~Copyable>(
    _ pipeline: inout P, _ input: [UInt8], count: Int? = nil, into output: inout [UInt8]
) -> Int where P.Failure == BytesError {
    pipeline.reset()
    let total = count ?? input.count
    return output.withUnsafeMutableBytes { buffer in
        var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
        var offset = 0
        repeat {
            let end = min(offset + 16_384, total)
            let flush: TransformFlush = end == total ? .finish : .flush
            while true {
                let progress = try! pipeline.transform(input.span.bytes.extracting(offset..<end), into: &span, flush: flush)
                offset += progress.consumed
                precondition(progress.status != .needsOutput, "The output holds the whole stream")
                if progress.status == .finished || (progress.status == .needsInput && offset == end) { break }
            }
        } while offset < total
        return span.finalize(for: buffer)
    }
}

/// One stream through a receiving pipeline (`input`'s first `count` bytes), in 64 KB pieces as reads would
/// deliver it: returns the bytes out. Reset first; a TLS opener's sequence is the caller's to set.
@inline(__always)
func pipelineReceive<P: ResettableByteTransform & ~Copyable>(
    _ pipeline: inout P, _ input: [UInt8], count: Int? = nil, into output: inout [UInt8]
) -> Int where P.Failure == BytesError {
    pipeline.reset()
    let total = count ?? input.count
    return output.withUnsafeMutableBytes { buffer in
        var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
        var offset = 0
        while true {
            let end = min(offset + (64 << 10), total)
            let finishing = end == total
            let progress = try! pipeline.transform(input.span.bytes.extracting(offset..<end), into: &span, flush: finishing ? .finish : .none)
            offset += progress.consumed
            precondition(progress.status != .needsOutput, "The output holds the whole stream")
            // A decoder finishes; an opener at the input's end has nothing more to do.
            if progress.status == .finished || (finishing && offset == total) { break }
        }
        return span.finalize(for: buffer)
    }
}
