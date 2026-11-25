import Benchmark
import Bytes
import BytesAsync
import BytesCompression
import BytesCrypto
import BytesTestSupport
import CryptoKit
import Foundation

// Encryption against CryptoKit, and pipelines: compression and encryption composed, as a server sending
// HTTP-compressed bodies over TLS does, and back.

/// Keys, nonces, and a message of one size, for each AEAD; and the message sealed by each, to open.
struct SealFixture {
    let nonce = [UInt8](repeating: 0x07, count: 12)
    let aad = [UInt8](repeating: 0x17, count: 5)
    let message: [UInt8]
    let data: Data
    let aead: ChaCha20Poly1305
    let gcm: AESGCM
    let gcm256: AESGCM
    let chachaKey: SymmetricKey
    let gcmKey: SymmetricKey
    let gcm256Key: SymmetricKey
    let chachaNonce: ChaChaPoly.Nonce
    let gcmNonce: CryptoKit.AES.GCM.Nonce
    /// The message sealed by Bytes (ciphertext, then tag) and by CryptoKit, with `nonce` and `aad`.
    let chachaSealed: (ciphertext: [UInt8], tag: [UInt8])
    let gcmSealed: (ciphertext: [UInt8], tag: [UInt8])
    let chachaBox: ChaChaPoly.SealedBox
    let gcmBox: CryptoKit.AES.GCM.SealedBox

    init(size: Int) {
        let key = [UInt8](repeating: 0x42, count: 32)
        message = (0..<size).map { UInt8(truncatingIfNeeded: $0) }
        data = Data(message)
        aead = ChaCha20Poly1305(key: key.span.bytes)
        let gcmKeyBytes = Array(key.prefix(16))
        gcm = AESGCM(key: gcmKeyBytes.span.bytes)
        gcm256 = AESGCM(key: key.span.bytes)
        chachaKey = SymmetricKey(data: key)
        gcmKey = SymmetricKey(data: key.prefix(16))
        gcm256Key = SymmetricKey(data: key)
        chachaNonce = try! ChaChaPoly.Nonce(data: nonce)
        gcmNonce = try! CryptoKit.AES.GCM.Nonce(data: nonce)
        chachaBox = try! ChaChaPoly.seal(data, using: chachaKey, nonce: chachaNonce, authenticating: aad)
        gcmBox = try! CryptoKit.AES.GCM.seal(data, using: gcmKey, nonce: gcmNonce, authenticating: aad)
        let (plaintext, aead, gcm, nonce, aad) = (message, aead, gcm, nonce, aad)
        let seal = { (body: (inout MutableRawSpan) -> InlineArray<16, UInt8>) -> (ciphertext: [UInt8], tag: [UInt8]) in
            var ciphertext = plaintext
            var span = ciphertext.mutableSpan
            var raw = MutableRawSpan(mutating: &span)
            let tag = body(&raw)
            return (ciphertext, (0..<16).map { tag[$0] })
        }
        chachaSealed = seal { aead.seal(&$0, nonce: nonce.span.bytes, authenticating: aad.span.bytes) }
        gcmSealed = seal { gcm.seal(&$0, nonce: nonce.span.bytes, authenticating: aad.span.bytes) }
        // Bytes seals as CryptoKit does.
        precondition(chachaSealed.ciphertext + chachaSealed.tag == Array(chachaBox.ciphertext + chachaBox.tag))
        precondition(gcmSealed.ciphertext + gcmSealed.tag == Array(gcmBox.ciphertext + gcmBox.tag))
    }
}

/// Opens `sealed` with `open` as a receiver does: the ciphertext copied into `buffer` (opening decrypts in place), then
/// checked and decrypted. Whether it opened.
@inline(__always)
func openCopy(
    _ sealed: (ciphertext: [UInt8], tag: [UInt8]), in buffer: inout [UInt8],
    _ open: (inout MutableRawSpan, RawSpan) throws(BytesError) -> Void
) -> Bool {
    var span = buffer.mutableSpan
    var raw = MutableRawSpan(mutating: &span)
    raw.copyBytes(from: sealed.ciphertext.span.bytes, toByteOffset: 0)
    return (try? open(&raw, sealed.tag.span.bytes)) != nil
}

func registerCryptoBenchmarks() {
    // 1,500 bytes: an Ethernet frame's payload, a size that's no multiple of a block.
    for size in [64, 1_024, 1_500, 16_384, 1 << 20] {
        let label = size >= 1 << 20 ? "1 MB" : size % 1024 == 0 ? "\(size / 1024) KB" : size >= 1000 ? "1,500 B" : "\(size) B"
        let fixture = Lazy { SealFixture(size: size) }
        // Sealed in place, again each time; made by setup.
        var message: [UInt8] = []
        // 1 MB per iteration, in messages of `size`: per-call costs show for short messages.
        let repeats = max(1, (1 << 20) / size)
        let references = size != 1_500 // The odd size: Bytes' tail handling, no comparison.
        Benchmark("ChaCha20-Poly1305 seal \(label) (x\(repeats)): Bytes") { benchmark in
            let f = fixture.value
            let aead = f.aead, nonce = f.nonce, aad = f.aad
            for _ in benchmark.scaledIterations {
                for _ in 0..<repeats {
                    var span = message.mutableSpan
                    var raw = MutableRawSpan(mutating: &span)
                    blackHole(aead.seal(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes))
                }
            }
        } setup: { message = fixture.value.message }
        if references {
            Benchmark("ChaCha20-Poly1305 seal \(label) (x\(repeats)): CryptoKit") { benchmark in
                let f = fixture.value
                let data = f.data, chachaKey = f.chachaKey, chachaNonce = f.chachaNonce, aad = f.aad
                for _ in benchmark.scaledIterations {
                    for _ in 0..<repeats {
                        blackHole(try! ChaChaPoly.seal(data, using: chachaKey, nonce: chachaNonce, authenticating: aad))
                    }
                }
            } setup: { _ = fixture.value }
        }
        Benchmark("AES-128-GCM seal \(label) (x\(repeats)): Bytes") { benchmark in
            let f = fixture.value
            let gcm = f.gcm, nonce = f.nonce, aad = f.aad
            for _ in benchmark.scaledIterations {
                for _ in 0..<repeats {
                    var span = message.mutableSpan
                    var raw = MutableRawSpan(mutating: &span)
                    blackHole(gcm.seal(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes))
                }
            }
        } setup: { message = fixture.value.message }
        if references {
            Benchmark("AES-128-GCM seal \(label) (x\(repeats)): CryptoKit") { benchmark in
                let f = fixture.value
                let data = f.data, gcmKey = f.gcmKey, gcmNonce = f.gcmNonce, aad = f.aad
                for _ in benchmark.scaledIterations {
                    for _ in 0..<repeats {
                        blackHole(try! CryptoKit.AES.GCM.seal(data, using: gcmKey, nonce: gcmNonce, authenticating: aad))
                    }
                }
            } setup: { _ = fixture.value }
        }

        // AES-256 (14 rounds against 10), at one size.
        if size == 16_384 {
            Benchmark("AES-256-GCM seal \(label) (x\(repeats)): Bytes") { benchmark in
                let f = fixture.value
                let gcm = f.gcm256, nonce = f.nonce, aad = f.aad
                for _ in benchmark.scaledIterations {
                    for _ in 0..<repeats {
                        var span = message.mutableSpan
                        var raw = MutableRawSpan(mutating: &span)
                        blackHole(gcm.seal(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes))
                    }
                }
            } setup: { message = fixture.value.message }
            Benchmark("AES-256-GCM seal \(label) (x\(repeats)): CryptoKit") { benchmark in
                let f = fixture.value
                let data = f.data, key = f.gcm256Key, gcmNonce = f.gcmNonce, aad = f.aad
                for _ in benchmark.scaledIterations {
                    for _ in 0..<repeats {
                        blackHole(try! CryptoKit.AES.GCM.seal(data, using: key, nonce: gcmNonce, authenticating: aad))
                    }
                }
            } setup: { _ = fixture.value }
        }

        // Opening: the tag checked over the ciphertext, then decrypted. Bytes opens in place, so each message is copied
        // into the buffer first (as a receiver's bytes land in it); CryptoKit returns a new `Data`.
        guard size == 1_024 || size == 16_384 else { continue }
        Benchmark("ChaCha20-Poly1305 open \(label) (x\(repeats)): Bytes") { benchmark in
            let f = fixture.value
            let aead = f.aead, nonce = f.nonce, aad = f.aad, sealed = f.chachaSealed
            for _ in benchmark.scaledIterations {
                for _ in 0..<repeats {
                    blackHole(openCopy(sealed, in: &message) { raw, tag throws(BytesError) in
                        try aead.open(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes, tag: tag)
                    })
                }
            }
        } setup: {
            let f = fixture.value
            message = f.message
            precondition(openCopy(f.chachaSealed, in: &message) { raw, tag throws(BytesError) in
                try f.aead.open(&raw, nonce: f.nonce.span.bytes, authenticating: f.aad.span.bytes, tag: tag)
            } && message == f.message)
        }
        Benchmark("ChaCha20-Poly1305 open \(label) (x\(repeats)): CryptoKit") { benchmark in
            let f = fixture.value
            let box = f.chachaBox, key = f.chachaKey, aad = f.aad
            for _ in benchmark.scaledIterations {
                for _ in 0..<repeats {
                    blackHole(try! ChaChaPoly.open(box, using: key, authenticating: aad))
                }
            }
        } setup: { _ = fixture.value }
        Benchmark("AES-128-GCM open \(label) (x\(repeats)): Bytes") { benchmark in
            let f = fixture.value
            let gcm = f.gcm, nonce = f.nonce, aad = f.aad, sealed = f.gcmSealed
            for _ in benchmark.scaledIterations {
                for _ in 0..<repeats {
                    blackHole(openCopy(sealed, in: &message) { raw, tag throws(BytesError) in
                        try gcm.open(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes, tag: tag)
                    })
                }
            }
        } setup: {
            let f = fixture.value
            message = f.message
            precondition(openCopy(f.gcmSealed, in: &message) { raw, tag throws(BytesError) in
                try f.gcm.open(&raw, nonce: f.nonce.span.bytes, authenticating: f.aad.span.bytes, tag: tag)
            } && message == f.message)
        }
        Benchmark("AES-128-GCM open \(label) (x\(repeats)): CryptoKit") { benchmark in
            let f = fixture.value
            let box = f.gcmBox, key = f.gcmKey, aad = f.aad
            for _ in benchmark.scaledIterations {
                for _ in 0..<repeats {
                    blackHole(try! CryptoKit.AES.GCM.open(box, using: key, authenticating: aad))
                }
            }
        } setup: { _ = fixture.value }
    }

    // TLS records from 4 MB handed to the sealer at once (as a socket writer with a large buffer does): one lane,
    // then several, each record sealed straight into its place in the output. 4 MB per iteration.
    final class TLSSealFixture {
        let plaintext = (0..<(4 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        var records = [UInt8](repeating: 0, count: (4 << 20) + (4 << 20) / 128)
        var sealer: TLSRecordSealer

        init(suite: TLSCipherSuite, lanes: Int) {
            let keys = TLSKeySchedule.applicationKeys(sharedSecret: [UInt8](repeating: 3, count: 32).span.bytes, suite: suite).server
            sealer = TLSRecordSealer(keys: keys)
            sealer.sealingLanes = lanes
        }
    }
    for suite in [TLSCipherSuite.aes128GCMSHA256, .chaCha20Poly1305SHA256] {
        let name = suite == .aes128GCMSHA256 ? "AES-128-GCM" : "ChaCha20-Poly1305"
        for lanes in [1, 4, 8] {
            let fixture = Lazy { TLSSealFixture(suite: suite, lanes: lanes) }
            Benchmark("TLS seal 4 MB \(name) (\(lanes) lanes): Bytes") { benchmark in
                let f = fixture.value
                let plaintext = f.plaintext
                for _ in benchmark.scaledIterations {
                    blackHole(f.records.withOutputRawSpan { span in
                        try! f.sealer.transform(plaintext.span.bytes, into: &span, flush: .flush)
                    })
                }
            } setup: { _ = fixture.value }
        }

        // Opening the same 4 MB of records (sealed by setup), one call: records are opened one after another, each
        // straight into the output. The opener goes back to sequence 0 each time.
        let open = Lazy { TLSOpenFixture(suite: suite) }
        register("TLS open 4 MB \(name) (1 lane): Bytes", configuration: Fixtures.largeConfiguration, open, check: { f, count in
            count == f.plaintext.count && f.output.prefix(count).elementsEqual(f.plaintext)
        }) { f in
            tlsOpenAll(f)
        }
    }
}

/// 4 MB of records, sealed once, and an opener for them.
final class TLSOpenFixture {
    let plaintext = (0..<(4 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) }
    let records: [UInt8]
    var output: [UInt8]
    var opener: TLSRecordOpener

    init(suite: TLSCipherSuite) {
        let keys = TLSKeySchedule.applicationKeys(sharedSecret: [UInt8](repeating: 3, count: 32).span.bytes, suite: suite).server
        var sealer = TLSRecordSealer(keys: keys)
        var records = [UInt8](repeating: 0, count: (4 << 20) + (4 << 20) / 128)
        let plaintext = plaintext
        let count = records.withOutputRawSpan { span in
            _ = try! sealer.transform(plaintext.span.bytes, into: &span, flush: .flush)
            return span.byteCount
        }
        self.records = Array(records.prefix(count))
        output = [UInt8](repeating: 0, count: plaintext.count + (64 << 10))
        opener = TLSRecordOpener(keys: keys)
    }
}

/// Opens every record in `f.records` into `f.output` from sequence 0: the bytes opened.
@inline(never)
func tlsOpenAll(_ f: TLSOpenFixture) -> Int {
    f.opener.reset(sequence: 0)
    let records = f.records
    return f.output.withOutputRawSpan { span in
        let progress = try! f.opener.transform(records.span.bytes, into: &span, flush: .finish)
        precondition(progress.consumed == records.count)
        return span.byteCount
    }
}

/// A sample, the pipelines that send and receive it, and their buffers.
final class PipelineFixture {
    let input: [UInt8]
    var wire: [UInt8]
    var plain: [UInt8]
    var middle: [UInt8]
    var deflateSend: Pipeline<DeflateEncoder, TLSRecordSealer>
    var deflateReceive: Pipeline<TLSRecordOpener, DeflateDecoder>
    var brotliSend: Pipeline<BrotliEncoder, TLSRecordSealer>
    var brotliReceive: Pipeline<TLSRecordOpener, BrotliDecoder>
    var deflateAlone = DeflateEncoder(format: .raw, level: 1)
    var sealerAlone: TLSRecordSealer
    var openerAlone: TLSRecordOpener
    var inflateAlone = DeflateDecoder(format: .raw)
    /// The streams to receive: each sender's first, records numbered from 0.
    let deflateWire: [UInt8]
    let brotliWire: [UInt8]

    init(_ sample: Fixtures.Sample) {
        let keys = TLSKeySchedule.applicationKeys(sharedSecret: [UInt8](repeating: 3, count: 32).span.bytes).server
        input = sample.bytes
        wire = [UInt8](repeating: 0, count: input.count * 2 + (1 << 20))
        plain = [UInt8](repeating: 0, count: input.count + (1 << 20))
        middle = [UInt8](repeating: 0, count: input.count * 2 + (1 << 20))
        deflateSend = DeflateEncoder(format: .raw, level: 1).then(TLSRecordSealer(keys: keys))
        deflateReceive = TLSRecordOpener(keys: keys).then(DeflateDecoder(format: .raw))
        brotliSend = BrotliEncoder(quality: 5, windowBits: 18).then(TLSRecordSealer(keys: keys))
        brotliReceive = TLSRecordOpener(keys: keys).then(BrotliDecoder())
        sealerAlone = TLSRecordSealer(keys: keys)
        openerAlone = TLSRecordOpener(keys: keys)
        // (The count first: in `wire.prefix(send(into: &wire))`, `wire` is read before the send writes, so the prefix
        // is of the old, empty array.)
        let deflateCount = pipelineSend(&deflateSend, input, into: &wire)
        deflateWire = Array(wire.prefix(deflateCount))
        let brotliCount = pipelineSend(&brotliSend, input, into: &wire)
        brotliWire = Array(wire.prefix(brotliCount))
    }

    /// Whether `count` bytes were received and are the input.
    func received(_ count: Int) -> Bool {
        count == input.count && plain.prefix(input.count).elementsEqual(input)
    }
}

/// Compress-then-seal and open-then-decompress pipelines over web assets: a flush per 16 KB of input sent,
/// 64 KB pieces received. Each iteration is one whole stream through pipelines built once and reset.
func registerPipelineBenchmarks() {
    for sample in Fixtures.samples where sample.name == "Main.js" || sample.name == "JSON" {
        let configuration = Fixtures.configuration(forByteCount: sample.byteCount)
        let fixture = Lazy { PipelineFixture(sample) }
        register("Pipeline deflate 1 + TLS send \(sample.label): Bytes", configuration: configuration, fixture, check: { f, count in
            sendRoundTrips(count, &f.deflateSend, &f.deflateReceive, input: f.input, wire: &f.wire, plain: &f.plain)
        }) { f in
            pipelineSend(&f.deflateSend, f.input, into: &f.wire)
        }
        register("Pipeline TLS + inflate receive \(sample.label): Bytes", configuration: configuration, fixture, check: { $0.received($1) }) { f in
            f.deflateReceive.first.reset(sequence: 0)
            return pipelineReceive(&f.deflateReceive, f.deflateWire, into: &f.plain)
        }
        // The same work as two passes through a buffer of the whole stream, no pipeline: its overhead.
        register("Two passes deflate 1, then TLS send \(sample.label): Bytes", configuration: configuration, fixture, check: { $1 > 0 }) { f in
            let compressed = pipelineSend(&f.deflateAlone, f.input, into: &f.middle)
            return pipelineSend(&f.sealerAlone, f.middle, count: compressed, into: &f.wire)
        }
        register("Two passes TLS, then inflate receive \(sample.label): Bytes", configuration: configuration, fixture, check: { $0.received($1) }) { f in
            f.openerAlone.reset(sequence: 0)
            let opened = pipelineReceive(&f.openerAlone, f.deflateWire, into: &f.middle)
            return pipelineReceive(&f.inflateAlone, f.middle, count: opened, into: &f.plain)
        }
        register("Pipeline brotli 5 + TLS send \(sample.label): Bytes", configuration: configuration, fixture, check: { f, count in
            sendRoundTrips(count, &f.brotliSend, &f.brotliReceive, input: f.input, wire: &f.wire, plain: &f.plain)
        }) { f in
            pipelineSend(&f.brotliSend, f.input, into: &f.wire)
        }
        register("Pipeline TLS + brotli receive \(sample.label): Bytes", configuration: configuration, fixture, check: { $0.received($1) }) { f in
            f.brotliReceive.first.reset(sequence: 0)
            return pipelineReceive(&f.brotliReceive, f.brotliWire, into: &f.plain)
        }

        // SocketStream's senders: 256 KB batches, each flushed. Brotli at quality 1 with a 256 KB window, and the
        // parallel DEFLATE encoder on the performance cores in 64 KB chunks, with a buffer of a batch and a chunk.
        guard sample.name == "Main.js" else { continue }
        let consumer = Lazy { ConsumerPipelineFixture(sample) }
        register("Pipeline brotli 1 window 18 + TLS send \(sample.label): Bytes, 256 KB batches", configuration: configuration, consumer, check: {
            f, count in sendRoundTrips(count, &f.brotliSend, &f.brotliReceive, input: f.input, wire: &f.wire, plain: &f.plain, batch: 256 << 10)
        }) { f in
            pipelineSend(&f.brotliSend, f.input, batch: 256 << 10, into: &f.wire)
        }
        register(
            "Pipeline parallel deflate 1 (\(performanceCores) lanes, 64 KB chunks) + TLS send \(sample.label): Bytes, 256 KB batches",
            configuration: configuration, consumer, check: { f, count in
                sendRoundTrips(count, &f.parallelSend, &f.deflateReceive, input: f.input, wire: &f.wire, plain: &f.plain, batch: 256 << 10)
            }
        ) { f in
            pipelineSend(&f.parallelSend, f.input, batch: 256 << 10, into: &f.wire)
        }
    }
}

/// SocketStream's sending pipelines, and receivers for checking them.
final class ConsumerPipelineFixture {
    let input: [UInt8]
    var wire: [UInt8]
    var plain: [UInt8]
    var brotliSend: Pipeline<BrotliEncoder, TLSRecordSealer>
    var parallelSend: Pipeline<ParallelDeflateEncoder, TLSRecordSealer>
    var brotliReceive: Pipeline<TLSRecordOpener, BrotliDecoder>
    var deflateReceive: Pipeline<TLSRecordOpener, DeflateDecoder>

    init(_ sample: Fixtures.Sample) {
        let keys = TLSKeySchedule.applicationKeys(sharedSecret: [UInt8](repeating: 3, count: 32).span.bytes).server
        input = sample.bytes
        wire = [UInt8](repeating: 0, count: input.count * 2 + (1 << 20))
        plain = [UInt8](repeating: 0, count: input.count + (1 << 20))
        brotliSend = BrotliEncoder(quality: 1, windowBits: 18).then(TLSRecordSealer(keys: keys))
        parallelSend = ParallelDeflateEncoder(format: .raw, level: 1, chunkSize: 64 << 10, lanes: performanceCores)
            .then(TLSRecordSealer(keys: keys), bufferCapacity: (256 << 10) + (64 << 10))
        brotliReceive = TLSRecordOpener(keys: keys).then(BrotliDecoder())
        deflateReceive = TLSRecordOpener(keys: keys).then(DeflateDecoder(format: .raw))
    }
}

/// For a send's setup check: whether a stream sent again by `send` is `count` bytes (the measured run's size) and opens
/// and decodes, through `receive` from the sender's sequence number, back to `input`.
func sendRoundTrips<Encoder: ResettableByteTransform & ~Copyable, Decoder: ResettableByteTransform & ~Copyable>(
    _ count: Int, _ send: inout Pipeline<Encoder, TLSRecordSealer>, _ receive: inout Pipeline<TLSRecordOpener, Decoder>,
    input: [UInt8], wire: inout [UInt8], plain: inout [UInt8], batch: Int = 16_384
) -> Bool where Encoder.Failure == BytesError, Decoder.Failure == BytesError {
    let start = send.second.recordProtection.sequence
    let sent = pipelineSend(&send, input, batch: batch, into: &wire)
    let stream = Array(wire.prefix(sent))
    receive.first.reset(sequence: start)
    let received = pipelineReceive(&receive, stream, into: &plain)
    return sent == count && received == input.count && plain.prefix(received).elementsEqual(input)
}

/// One stream through a sending pipeline, a flush per 16 KB of input (`input`'s first `count` bytes): returns
/// the bytes out.
@inline(__always)
func pipelineSend<P: ResettableByteTransform & ~Copyable>(
    _ pipeline: inout P, _ input: [UInt8], count: Int? = nil, batch: Int = 16_384, into output: inout [UInt8]
) -> Int where P.Failure == BytesError {
    pipeline.reset()
    let total = count ?? input.count
    return output.withOutputRawSpan { span in
        var offset = 0
        repeat {
            let end = min(offset + batch, total)
            let flush: TransformFlush = end == total ? .finish : .flush
            while true {
                let progress = try! pipeline.transform(input.span.bytes.extracting(offset..<end), into: &span, flush: flush)
                offset += progress.consumed
                precondition(progress.status != .needsOutput, "The output holds the whole stream")
                if progress.status == .finished || (progress.status == .needsInput && offset == end) { break }
            }
        } while offset < total
        return span.byteCount
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
    return output.withOutputRawSpan { span in
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
        return span.byteCount
    }
}

// MARK: - Allocation gates

/// TLS records sealed and opened again, each iteration: the gates' content, in records.
final class TLSRoundTripFixture {
    let plaintext = Fixtures.gateContent()
    var records: [UInt8]
    var output: [UInt8]
    var sealer: TLSRecordSealer
    var opener: TLSRecordOpener

    init() {
        let keys = TLSKeySchedule.applicationKeys(sharedSecret: [UInt8](repeating: 3, count: 32).span.bytes, suite: .aes128GCMSHA256).server
        sealer = TLSRecordSealer(keys: keys)
        opener = TLSRecordOpener(keys: keys)
        records = [UInt8](repeating: 0, count: plaintext.count + plaintext.count / 128 + 1024)
        output = [UInt8](repeating: 0, count: plaintext.count + (64 << 10))
    }
}

/// Seals the plaintext into records (one lane), then opens them from the sealer's sequence number: the bytes opened.
@inline(never)
func tlsRoundTrip(_ f: TLSRoundTripFixture) -> Int {
    let start = f.sealer.recordProtection.sequence
    let plaintext = f.plaintext
    let sealed = f.records.withOutputRawSpan { span in
        _ = try! f.sealer.transform(plaintext.span.bytes, into: &span, flush: .flush)
        return span.byteCount
    }
    f.opener.reset(sequence: start)
    let records = f.records
    return f.output.withOutputRawSpan { span in
        _ = try! f.opener.transform(records.span.bytes.extracting(first: sealed), into: &span, flush: .finish)
        return span.byteCount
    }
}

/// Seals `message` in place and opens it again with `seal` and `open`: whether it opened (and so is the original).
@inline(__always)
func aeadRoundTrip(
    _ message: inout [UInt8], seal: (inout MutableRawSpan) -> InlineArray<16, UInt8>,
    open: (inout MutableRawSpan, RawSpan) throws(BytesError) -> Void
) -> Bool {
    var span = message.mutableSpan
    var raw = MutableRawSpan(mutating: &span)
    let tag = seal(&raw)
    return (try? open(&raw, tag.span.bytes)) != nil
}

/// The AEADs, TLS records, pipelines, hashes, HMAC, HKDF, and PBKDF2 allocate nothing once made. Zero thresholds in
/// `Thresholds/`:
///
///     swift package --disable-sandbox benchmark thresholds check --filter 'Allocations:(Pipeline|TLS|AES|ChaCha|Hashes|PBKDF2).*'
func registerCryptoAllocationBenchmarks() {
    let configuration = Fixtures.allocationConfiguration

    let pipeline = Lazy { PipelineFixture(Fixtures.Sample(name: "gate", bytes: Fixtures.gateContent())) }
    register("Allocations:Pipeline_deflate_TLS_send", configuration: configuration, pipeline, check: { f, count in
        sendRoundTrips(count, &f.deflateSend, &f.deflateReceive, input: f.input, wire: &f.wire, plain: &f.plain)
    }) { f in
        pipelineSend(&f.deflateSend, f.input, into: &f.wire)
    }
    register("Allocations:Pipeline_TLS_inflate_receive", configuration: configuration, pipeline, check: { $0.received($1) }) { f in
        f.deflateReceive.first.reset(sequence: 0)
        return pipelineReceive(&f.deflateReceive, f.deflateWire, into: &f.plain)
    }

    let tls = Lazy { TLSRoundTripFixture() }
    register("Allocations:TLS_seal_open", configuration: configuration, tls, check: { f, count in
        count == f.plaintext.count && f.output.prefix(count).elementsEqual(f.plaintext)
    }) { f in
        tlsRoundTrip(f)
    }

    // 16 KB sealed and opened in place, each iteration.
    final class AEADFixture {
        let seal = SealFixture(size: 16_384)
        var message: [UInt8]
        init() { message = seal.message }
    }
    let aead = Lazy { AEADFixture() }
    register("Allocations:AES_GCM_seal_open_16KB", configuration: configuration, aead, check: { f, opened in opened && f.message == f.seal.message }) { f in
        let gcm = f.seal.gcm, nonce = f.seal.nonce, aad = f.seal.aad
        return aeadRoundTrip(&f.message, seal: { gcm.seal(&$0, nonce: nonce.span.bytes, authenticating: aad.span.bytes) }) { raw, tag throws(BytesError) in
            try gcm.open(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes, tag: tag)
        }
    }
    register("Allocations:ChaCha20_Poly1305_seal_open_16KB", configuration: configuration, aead, check: { f, opened in
        opened && f.message == f.seal.message
    }) { f in
        let chacha = f.seal.aead, nonce = f.seal.nonce, aad = f.seal.aad
        return aeadRoundTrip(&f.message, seal: { chacha.seal(&$0, nonce: nonce.span.bytes, authenticating: aad.span.bytes) }) { raw, tag throws(BytesError) in
            try chacha.open(&raw, nonce: nonce.span.bytes, authenticating: aad.span.bytes, tag: tag)
        }
    }

    // SHA-1, SHA-256, SHA-512, HMAC-SHA256, and HKDF-SHA256 on 16 KB, through their non-allocating forms.
    let primitives = Lazy { PrimitiveFixture() }
    register("Allocations:Hashes_HMAC_HKDF", configuration: configuration, primitives) { f in
        let message = f.message.span.bytes.extracting(first: 16_384)
        var sum = Int(SHA1.hash(message)[0]) &+ Int(BytesCrypto.SHA256.hash(message)[0])
        var sha512 = BytesCrypto.SHA512()
        sha512.update(message)
        var digest = InlineArray<64, UInt8>(repeating: 0)
        var span = digest.mutableSpan
        var raw = MutableRawSpan(mutating: &span)
        sha512.finalize(into: &raw)
        sum &+= Int(digest[0])
        sum &+= Int(into32 { BytesCrypto.HMAC<BytesCrypto.SHA256>.authenticationCode(for: message, key: f.key.span.bytes, into: &$0) }[0])
        sum &+= Int(hkdfSHA256(salt: f.salt, secret: f.key256, info: f.info)[0])
        return sum
    }
    register("Allocations:PBKDF2_SHA1", configuration: configuration, primitives) { f in
        var derived = InlineArray<34, UInt8>(repeating: 0)
        var span = derived.mutableSpan
        var raw = MutableRawSpan(mutating: &span)
        PBKDF2.deriveKey(SHA1.self, password: f.password.span.bytes, salt: f.salt.span.bytes, iterations: 1000, into: &raw)
        return derived[0]
    }
}

// MARK: - Offloaded stages

/// A stage run on a Dispatch queue (`offloaded(to:)`), fed 64 KB pieces, its output into a buffer of the whole stream.
final class OffloadedFixture {
    let input: [UInt8]
    var stage: OffloadedTransform<DeflateEncoder>
    /// The output: raw memory, as the async forms can't borrow an array across a suspension. Allocated once, freed by
    /// `deinit`.
    let buffer: UnsafeMutableRawBufferPointer

    init(_ sample: Fixtures.Sample) {
        input = sample.bytes
        stage = DeflateEncoder(format: .raw, level: 1).offloaded(to: DispatchQueue(label: "offloaded"))
        buffer = .allocate(byteCount: DeflateEncoder.maximumCompressedSize(forByteCount: input.count, format: .raw), alignment: 64)
    }

    deinit { buffer.deallocate() }
}

/// Compresses the input through the offloaded stage in 64 KB pieces, finishing with the last: the bytes written.
func offloadedEncode(_ f: OffloadedFixture) async -> Int {
    f.stage.base.reset()
    let input = f.input, buffer = f.buffer
    var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
    var offset = 0
    while true {
        let end = min(offset + (64 << 10), input.count)
        let progress = try! await f.stage.transform(input.span.bytes.extracting(offset..<end), into: &span, flush: end == input.count ? .finish : .none)
        offset += progress.consumed
        if progress.status == .finished { break }
    }
    return span.finalize(for: buffer)
}

/// DEFLATE level 1 on a Dispatch queue: two hops per 64 KB piece on top of "Deflate 1 Main.js: Bytes, streaming 64 KB"'s
/// work (which writes into a reused window instead of one buffer).
func registerOffloadedBenchmarks() {
    guard let sample = Fixtures.samples.first(where: { $0.name == "Main.js" }) else { return }
    let fixture = Lazy { OffloadedFixture(sample) }
    Benchmark("Offloaded deflate 1 \(sample.label): Bytes, 64 KB pieces", configuration: Fixtures.largeConfiguration) { (benchmark: Benchmark) async in
        let f = fixture.value
        for _ in benchmark.scaledIterations {
            await blackHole(offloadedEncode(f))
        }
    } setup: {
        let f = fixture.value
        let count = await offloadedEncode(f)
        let output = Array(UnsafeRawBufferPointer(rebasing: f.buffer[..<count]))
        precondition(Fixtures.inflates(output[...], to: f.input), "Offloaded deflate: wrong result")
    }
}
