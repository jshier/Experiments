import Bytes
import BytesCompression
import BytesCrypto
import CryptoKit
import PlatformExecutors

/// How the MQTT stream is compressed before it's encrypted or sent.
public enum StreamCompression: String, Sendable, CaseIterable {
    /// Not compressed.
    case none
    /// Raw DEFLATE at level 1, with a sync flush after each batch (as WebSocket's permessage-deflate does
    /// per message).
    case deflate
    /// Brotli at quality 1 with a 256 KB window, flushed after each batch.
    case brotli
}

/// The AEAD protecting TLS records: the cipher suite's.
public enum RecordCipher: String, Sendable, CaseIterable {
    /// ChaCha20-Poly1305 (TLS_CHACHA20_POLY1305_SHA256).
    case chacha20
    /// AES-128-GCM (TLS_AES_128_GCM_SHA256).
    case aes128gcm
    /// AES-256-GCM (TLS_AES_256_GCM_SHA384).
    case aes256gcm
}

/// What happens to the MQTT stream between the encoder and the socket: compression, encryption, both, or
/// neither. Each is a Bytes pipeline stage, built once per connection.
public struct Protection: Sendable, Hashable, CustomStringConvertible {
    /// The compression applied before encryption.
    public var compression: StreamCompression
    /// Whether the stream goes in TLS 1.3 records, with keys from an X25519 exchange.
    public var encrypted: Bool
    /// The records' cipher.
    public var cipher: RecordCipher = .chacha20

    var suite: TLSCipherSuite {
        switch cipher {
        case .chacha20: .chaCha20Poly1305SHA256
        case .aes128gcm: .aes128GCMSHA256
        case .aes256gcm: .aes256GCMSHA384
        }
    }
    /// How many cores compress each sender's stream: above 1, DEFLATE runs as a `ParallelDeflateEncoder`
    /// with this many lanes, each batch cut into that many chunks (at least 32 KB each). Brotli stays
    /// sequential.
    public var compressionLanes: Int
    /// How many cores seal each sender's TLS records: above 1, a batch holding several full records' worth seals
    /// them in parallel (`TLSRecordSealer.sealingLanes`), each straight into its place in the output.
    public var sealingLanes: Int

    /// Creates a protection.
    ///
    /// - Parameters:
    ///   - compression: The compression to apply.
    ///   - encrypted: Whether to seal the stream in TLS records.
    ///   - compressionLanes: How many cores compress DEFLATE (1: sequentially).
    ///   - sealingLanes: How many cores seal TLS records (1: sequentially).
    public init(compression: StreamCompression = .none, encrypted: Bool = false, compressionLanes: Int = 1, sealingLanes: Int = 1) {
        self.compression = compression
        self.encrypted = encrypted
        self.compressionLanes = max(compressionLanes, 1)
        self.sealingLanes = max(sealingLanes, 1)
    }

    /// Plain MQTT on the socket.
    public static var none: Self { Self() }

    /// Whether the stream is neither compressed nor encrypted.
    public var isNone: Bool { compression == .none && !encrypted }

    /// A short name: `plain`, `TLS records`, the compression, or the compression and `TLS records`.
    public var description: String {
        switch (compression, encrypted) {
        case (.none, false): "plain"
        case (.none, true): "TLS records\(sealingDescription)"
        case (let compression, false): "\(compression)\(lanesDescription)"
        case (let compression, true): "\(compression)\(lanesDescription) + TLS records\(sealingDescription)"
        }
    }

    private var lanesDescription: String {
        compression == .deflate && compressionLanes > 1 ? " on \(compressionLanes) lanes" : ""
    }

    private var sealingDescription: String {
        (cipher == .chacha20 ? "" : cipher == .aes128gcm ? " (AES-128-GCM)" : " (AES-256-GCM)")
            + (sealingLanes > 1 ? " sealed on \(sealingLanes) lanes" : "")
    }

    /// The sender's record stage.
    func sealer(_ keys: TLSTrafficKeys) -> TLSRecordSealer {
        var sealer = TLSRecordSealer(keys: keys)
        sealer.sealingLanes = sealingLanes
        return sealer
    }

    /// Traffic keys for one connection: an X25519 exchange between its two ends (both here, in place of a
    /// TLS handshake) and TLS 1.3's key schedule. The sender seals with the client's keys, the receiver opens
    /// with them.
    static func connectionKeys(suite: TLSCipherSuite) -> TLSTrafficKeys {
        let client = Curve25519.KeyAgreement.PrivateKey()
        let server = Curve25519.KeyAgreement.PrivateKey()
        let shared = try! client.sharedSecretFromKeyAgreement(with: server.publicKey)
        // Unsafe: the secret's bytes, copied out. Safe: the buffer is valid for the closure, which copies it.
        let secret = unsafe shared.withUnsafeBytes { unsafe [UInt8]($0) }
        return TLSKeySchedule.applicationKeys(sharedSecret: secret.span.bytes, suite: suite).client
    }
}

extension Transfer {
    /// Runs one protected pair's sender with the pipeline its protection calls for. Uncompressed and plain
    /// never gets here (`Protection.isNone`), so `(.none, _)` means encrypted only.
    nonisolated(nonsending) static func sendProtected(
        _ workload: Workload, to address: SocketAddress, protection: Protection, keys: TLSTrafficKeys
    ) async throws -> Int {
        switch (protection.compression, protection.encrypted) {
        case (.none, _):
            return try await sendProtected(workload, to: address, through: protection.sealer(keys))
        case (.deflate, false) where protection.compressionLanes > 1:
            return try await sendProtected(workload, to: address, through: parallelDeflate(protection.compressionLanes))
        case (.deflate, true) where protection.compressionLanes > 1:
            return try await sendProtected(
                workload, to: address,
                through: parallelDeflate(protection.compressionLanes).then(protection.sealer(keys), bufferCapacity: workload.batchSize &+ (64 << 10))
            )
        case (.deflate, false):
            return try await sendProtected(workload, to: address, through: DeflateEncoder(format: .raw, level: 1))
        case (.deflate, true):
            return try await sendProtected(
                workload, to: address, through: DeflateEncoder(format: .raw, level: 1).then(protection.sealer(keys))
            )
        case (.brotli, false):
            return try await sendProtected(workload, to: address, through: BrotliEncoder(quality: 1, windowBits: 18))
        case (.brotli, true):
            return try await sendProtected(
                workload, to: address, through: BrotliEncoder(quality: 1, windowBits: 18).then(protection.sealer(keys))
            )
        }
    }

    /// Runs one protected pair's receiver with the pipeline that undoes the sender's.
    nonisolated(nonsending) static func receiveProtected(
        _ workload: Workload, on connection: consuming TCPConnection, protection: Protection, keys: TLSTrafficKeys
    ) async throws -> (wire: Int, plain: Int, packets: Int) {
        switch (protection.compression, protection.encrypted) {
        case (.none, _):
            return try await receiveProtected(workload, on: connection, through: TLSRecordOpener(keys: keys))
        case (.deflate, false):
            return try await receiveProtected(workload, on: connection, through: DeflateDecoder(format: .raw))
        case (.deflate, true):
            return try await receiveProtected(
                workload, on: connection, through: TLSRecordOpener(keys: keys).then(DeflateDecoder(format: .raw))
            )
        case (.brotli, false):
            return try await receiveProtected(workload, on: connection, through: BrotliDecoder())
        case (.brotli, true):
            return try await receiveProtected(workload, on: connection, through: TLSRecordOpener(keys: keys).then(BrotliDecoder()))
        }
    }

    /// Connects, then encodes the packets into batches, runs each batch through `pipeline` (flushing at its
    /// end, so the receiver can decode every packet in it), and writes what comes out. Finishes the pipeline
    /// at the end.
    ///
    /// - Returns: The MQTT bytes sent, before the pipeline.
    nonisolated(nonsending) static func sendProtected<Stages: ByteTransform & ~Copyable>(
        _ workload: Workload, to address: SocketAddress, through stages: consuming Stages
    ) async throws -> Int where Stages.Failure == BytesError {
        var pipeline = stages
        var connection = try await TCPConnection.connect(to: address)
        // Varied payloads: the fixed one would compress to almost nothing.
        let payloads = Payloads.telemetry(size: workload.payloadSize)
        var batch = [UInt8](repeating: 0, count: workload.batchSize)
        var wire = [UInt8](repeating: 0, count: workload.batchSize + workload.batchSize / 8 + (64 << 10))
        var next = 0
        var sent = 0
        do {
            while true {
                let finishing = next == workload.packetsPerConnection
                let count = finishing ? 0 : encode(into: &batch, from: &next, until: workload.packetsPerConnection, payloads: payloads)
                var offset = 0
                while true {
                    let progress = try transform(&pipeline, batch.span.bytes.extracting(offset..<count), into: &wire, flush: finishing ? .finish : .flush)
                    offset += progress.consumed
                    if progress.produced > 0 {
                        try await connection.write(from: wire.span.bytes.extracting(0..<progress.produced))
                    }
                    if progress.status == .finished || (progress.status == .needsInput && offset == count) { break }
                }
                sent += count
                if finishing { break }
            }
        } catch {
            try? await connection.close()
            throw error
        }
        try await connection.close()
        return sent
    }

    /// Reads until the end of the stream, running what arrives through `pipeline` into a second buffer and
    /// parsing and checking every packet there, then closes the connection.
    ///
    /// - Returns: The bytes received from the socket, the MQTT bytes out of the pipeline, and the packets.
    nonisolated(nonsending) static func receiveProtected<Stages: ByteTransform & ~Copyable>(
        _ workload: Workload, on connection: consuming TCPConnection, through stages: consuming Stages
    ) async throws -> (wire: Int, plain: Int, packets: Int) where Stages.Failure == BytesError {
        var pipeline = stages
        var connection = connection
        var received = ByteBuffer(capacity: workload.receiveCapacity)
        var plain = ByteBuffer(capacity: workload.receiveCapacity)
        var checker = PacketChecker(payloadSize: workload.payloadSize)
        var wireBytes = 0
        var plainBytes = 0
        var ended = false
        do throws(any Error) {
            while !ended {
                let count = try await received.read(from: &connection)
                wireBytes += count
                ended = count == 0
                // Through the pipeline until it wants more from the socket. At the end, `.finish`: a decoder
                // finishes (or throws, if its stream ended early); a TLS opener alone has no end of stream, and
                // throws if a partial record is left.
                while true {
                    let progress: TransformProgress
                    do throws(BytesError) {
                        progress = try plain.fill { output throws(BytesError) in
                            try pipeline.transform(received.unread, into: &output, flush: ended ? .finish : .none)
                        }
                    } catch {
                        throw TransferError(description: "Decoding failed (\(error)) after \(wireBytes) bytes from the socket, \(plainBytes) decoded")
                    }
                    received.consume(progress.consumed)
                    plainBytes += progress.produced
                    do throws(any Error) {
                        plain.consume(try checker.check(plain.unread))
                    } catch {
                        throw TransferError(description: "Packet \(checker.packets) failed (\(error)) after \(plainBytes) bytes decoded")
                    }
                    if progress.status != .needsOutput { break }
                }
            }
        } catch {
            try? await connection.close()
            throw error
        }
        try await connection.close()
        guard plain.isEmpty else { throw TransferError(description: "The stream ended inside a packet") }
        return (wireBytes, plainBytes, checker.packets)
    }

    /// Runs `pipeline` from `input` into `output` from its start: one call, the produced bytes at the front.
    static func transform<Stages: ByteTransform & ~Copyable>(
        _ pipeline: inout Stages, _ input: RawSpan, into output: inout [UInt8], flush: TransformFlush
    ) throws(BytesError) -> TransformProgress where Stages.Failure == BytesError {
        try output.withOutputRawSpan { span throws(BytesError) in
            try pipeline.transform(input, into: &span, flush: flush)
        }
    }
}

extension Transfer {
    /// DEFLATE level 1 on `lanes` cores, raw, chunks of up to 64 KB: a 256 KB batch is cut into `lanes` chunks
    /// of at least 32 KB, each primed with the 32 KB before it.
    static func parallelDeflate(_ lanes: Int) -> ParallelDeflateEncoder {
        ParallelDeflateEncoder(format: .raw, level: 1, chunkSize: 64 << 10, lanes: lanes)
    }
}
