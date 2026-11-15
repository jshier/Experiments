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

/// What happens to the MQTT stream between the encoder and the socket: compression, encryption, both, or
/// neither. Each is a Bytes pipeline stage, built once per connection.
public struct Protection: Sendable, Hashable, CustomStringConvertible {
    /// The compression applied before encryption.
    public var compression: StreamCompression
    /// Whether the stream goes in TLS 1.3 records (ChaCha20-Poly1305), with keys from an X25519 exchange.
    public var encrypted: Bool

    /// Creates a protection.
    ///
    /// - Parameters:
    ///   - compression: The compression to apply.
    ///   - encrypted: Whether to seal the stream in TLS records.
    public init(compression: StreamCompression = .none, encrypted: Bool = false) {
        self.compression = compression
        self.encrypted = encrypted
    }

    /// Plain MQTT on the socket.
    public static var none: Self { Self() }

    /// Whether the stream is neither compressed nor encrypted.
    public var isNone: Bool { compression == .none && !encrypted }

    /// A short name: `plain`, `TLS records`, the compression, or the compression and `TLS records`.
    public var description: String {
        switch (compression, encrypted) {
        case (.none, false): "plain"
        case (.none, true): "TLS records"
        case (let compression, false): "\(compression)"
        case (let compression, true): "\(compression) + TLS records"
        }
    }

    /// Traffic keys for one connection: an X25519 exchange between its two ends (both here, in place of a
    /// TLS handshake) and TLS 1.3's key schedule. The sender seals with the client's keys, the receiver opens
    /// with them.
    static func connectionKeys() -> TLSTrafficKeys {
        let client = Curve25519.KeyAgreement.PrivateKey()
        let server = Curve25519.KeyAgreement.PrivateKey()
        let shared = try! client.sharedSecretFromKeyAgreement(with: server.publicKey)
        // Unsafe: the secret's bytes, copied out. Safe: the buffer is valid for the closure, which copies it.
        let secret = unsafe shared.withUnsafeBytes { unsafe [UInt8]($0) }
        return TLSKeySchedule.applicationKeys(sharedSecret: secret.span.bytes).client
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
            return try await sendProtected(workload, to: address, through: TLSRecordSealer(keys: keys))
        case (.deflate, false):
            return try await sendProtected(workload, to: address, through: DeflateEncoder(format: .raw, level: 1))
        case (.deflate, true):
            return try await sendProtected(
                workload, to: address, through: DeflateEncoder(format: .raw, level: 1).then(TLSRecordSealer(keys: keys))
            )
        case (.brotli, false):
            return try await sendProtected(workload, to: address, through: BrotliEncoder(quality: 1, windowBits: 18))
        case (.brotli, true):
            return try await sendProtected(
                workload, to: address, through: BrotliEncoder(quality: 1, windowBits: 18).then(TLSRecordSealer(keys: keys))
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
        var received = ReceiveBuffer(capacity: workload.receiveCapacity)
        var plain = PlainBuffer(capacity: workload.receiveCapacity)
        var checker = PacketChecker(payloadSize: workload.payloadSize)
        var wireBytes = 0
        var plainBytes = 0
        var ended = false
        do {
            while !ended {
                let count = try await received.read(from: &connection)
                wireBytes += count
                ended = count == 0
                // Through the pipeline until it wants more from the socket. At the end, `.finish`: a decoder
                // finishes (or throws, if its stream ended early); a TLS opener alone has no end of stream, and
                // throws if a partial record is left.
                while true {
                    let progress = try plain.fill { output throws(BytesError) in
                        try pipeline.transform(received.unread, into: &output, flush: ended ? .finish : .none)
                    }
                    received.consume(progress.consumed)
                    plainBytes += progress.produced
                    plain.consume(try checker.check(plain.unread))
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
        var bytes = output.mutableSpan
        // Unsafe: an output span over the buffer. Safe: it covers the buffer and ends with the closure; the
        // produced count comes from the pipeline's report. (The span's closure keeps the error type; the
        // array's would make it `any Error`.)
        return try bytes.withUnsafeMutableBytes { buffer throws(BytesError) in
            var span = unsafe OutputRawSpan(buffer: buffer, initializedCount: 0)
            let progress = try pipeline.transform(input, into: &span, flush: flush)
            _ = unsafe span.finalize(for: buffer)
            return progress
        }
    }
}

/// The receiver's buffer of decoded MQTT bytes: a pipeline appends, the checker consumes from the front, and
/// a partial packet moves to the front before the buffer fills. Allocated once.
struct PlainBuffer: ~Copyable {
    private var storage: [UInt8]
    private var start = 0
    private var end = 0

    init(capacity: Int) {
        storage = [UInt8](repeating: 0, count: capacity)
    }

    var unread: RawSpan {
        @_lifetime(borrow self)
        get { storage.span.bytes.extracting(start..<end) }
    }

    var isEmpty: Bool { start == end }

    mutating func consume(_ count: Int) {
        start += count
        if start == end { (start, end) = (0, 0) }
    }

    /// Appends what `body` writes to the free space, after moving a partial packet to the front if less than
    /// half the buffer is free.
    mutating func fill(_ body: (inout OutputRawSpan) throws(BytesError) -> TransformProgress) throws(BytesError) -> TransformProgress {
        if storage.count - end < storage.count / 2, start > 0 {
            let count = end - start
            for index in 0..<count { storage[index] = storage[start + index] }
            (start, end) = (0, count)
        }
        let end = end
        var bytes = storage.mutableSpan
        // Unsafe: an output span over the free tail. Safe: it covers exactly `storage[end...]` and ends with the
        // closure; only the produced bytes are counted.
        let progress = try bytes.withUnsafeMutableBytes { buffer throws(BytesError) in
            let free = unsafe UnsafeMutableRawBufferPointer(rebasing: buffer[end...])
            var output = unsafe OutputRawSpan(buffer: free, initializedCount: 0)
            let progress = try body(&output)
            _ = unsafe output.finalize(for: free)
            return progress
        }
        self.end += progress.produced
        return progress
    }
}
