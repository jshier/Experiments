import Bytes
import BytesCompression
import BytesCrypto
import SocketStream

/// A sender's and a receiver's pipelines for one protection, run over the same packets in memory: what a
/// transfer's ends do per packet, without the socket. Built once; each run resets them and goes through one
/// whole stream.
class InMemoryProtection: @unchecked Sendable {
    /// Encodes, compresses, and seals the packets; returns the bytes protected.
    func protect() -> Int { fatalError("abstract") }
    /// Opens, decompresses, and checks the protected stream; returns the packets checked.
    func unprotect() -> Int { fatalError("abstract") }

    static func make(_ protection: Protection, payloadSize: Int, packets: Int) -> InMemoryProtection {
        let keys = TLSKeySchedule.applicationKeys(sharedSecret: [UInt8](repeating: 9, count: 32).span.bytes).client
        switch (protection.compression, protection.encrypted) {
        case (.deflate, true):
            return Pipelines(
                sender: DeflateEncoder(format: .raw, level: 1).then(TLSRecordSealer(keys: keys)),
                receiver: TLSRecordOpener(keys: keys).then(DeflateDecoder(format: .raw)),
                rewind: { $0.first.reset(sequence: 0) },
                payloadSize: payloadSize, packets: packets
            )
        case (.brotli, true):
            return Pipelines(
                sender: BrotliEncoder(quality: 1, windowBits: 18).then(TLSRecordSealer(keys: keys)),
                receiver: TLSRecordOpener(keys: keys).then(BrotliDecoder()),
                rewind: { $0.first.reset(sequence: 0) },
                payloadSize: payloadSize, packets: packets
            )
        default:
            return Pipelines(sender: TLSRecordSealer(keys: keys), receiver: TLSRecordOpener(keys: keys), rewind: { $0.reset(sequence: 0) }, payloadSize: payloadSize, packets: packets)
        }
    }
}

/// The concrete pipelines: their types are the stages composed, so each call specializes to them.
final class Pipelines<Sender: ResettableByteTransform & ~Copyable, Receiver: ResettableByteTransform & ~Copyable>: InMemoryProtection, @unchecked Sendable
    where Sender.Failure == BytesError, Receiver.Failure == BytesError {
    var sender: Sender
    var receiver: Receiver
    /// Sets the receiver's TLS stage back to the stream's first record, to open the same records again (a
    /// reset continues the record sequence).
    let rewind: (inout Receiver) -> Void
    let payloads: Payloads
    let packetCount: Int
    let payloadSize: Int
    var batch = [UInt8](repeating: 0, count: 256 << 10)
    var wire = [UInt8](repeating: 0, count: 512 << 10)
    /// The receiver's decoded bytes, as `receiveProtected` keeps them.
    var plain = ByteBuffer(capacity: 256 << 10)
    /// The protected stream, made once by `protect()`, for `unprotect()`.
    var stream: [UInt8] = []

    init(sender: consuming Sender, receiver: consuming Receiver, rewind: @escaping (inout Receiver) -> Void, payloadSize: Int, packets: Int) {
        self.sender = sender
        self.receiver = receiver
        self.rewind = rewind
        self.payloadSize = payloadSize
        payloads = Payloads.telemetry(size: payloadSize) // As protected transfers send.
        packetCount = packets
        super.init()
        // The stream to unprotect: one run's output, kept.
        var output: [UInt8] = []
        _ = run(collect: &output)
        stream = output
    }

    override func protect() -> Int {
        var none: [UInt8]? = nil
        return run(collect: &none)
    }

    /// One whole stream through the sender: encode a batch, transform it with a flush, and so on; finish.
    private func run(collect: inout [UInt8]?) -> Int {
        sender.reset()
        var next = 0
        var total = 0
        while true {
            let finishing = next == packetCount
            let count = finishing ? 0 : Transfer.encode(into: &batch, from: &next, until: packetCount, payloads: payloads)
            var offset = 0
            // The arrays as locals (a retain, not a copy): a span of a class's stored property lasts only for that
            // access. Released before the next batch is encoded into `batch`.
            let batch = batch
            while true {
                let progress = try! transform(&sender, batch.span.bytes.extracting(offset..<count), into: &wire, flush: finishing ? .finish : .flush)
                collect?.append(contentsOf: wire[..<progress.produced])
                total &+= progress.produced
                offset &+= progress.consumed
                if progress.status == .finished || (progress.status == .needsInput && offset == count) { break }
            }
            if finishing { return total }
        }
    }

    private func run(collect: inout [UInt8]) -> Int {
        var optional: [UInt8]? = collect
        let total = run(collect: &optional)
        collect = optional!
        return total
    }

    override func unprotect() -> Int {
        receiver.reset()
        rewind(&receiver)
        plain.removeAll()
        // The array as a local (a retain, not a copy), and the buffer passed `inout`: a span of a class's stored
        // property lasts only for that access.
        let stream = stream
        return Self.unprotect(stream.span.bytes, through: &receiver, into: &plain, payloadSize: payloadSize)
    }

    /// Opens, decompresses, and checks `stream` in 64 KB pieces, as a receiver's reads would deliver it.
    private static func unprotect(_ stream: RawSpan, through receiver: inout Receiver, into plain: inout ByteBuffer, payloadSize: Int) -> Int {
        var checker = PacketChecker(payloadSize: payloadSize)
        var start = 0
        while true {
            let finishing = start == stream.byteCount
            // The buffer carries a partial packet to the front once less than half of it is free.
            let progress = plain.fill { output in
                try! receiver.transform(stream.extracting(start..<min(start + (64 << 10), stream.byteCount)), into: &output, flush: finishing ? .finish : .none)
            }
            start += progress.consumed
            plain.consume(try! checker.check(plain.unread))
            if progress.status == .finished || (finishing && progress.status == .needsInput) { break }
        }
        return checker.packets
    }
}

/// One call of `pipeline` from `input` into `output`'s start.
func transform<Stages: ByteTransform & ~Copyable>(
    _ pipeline: inout Stages, _ input: RawSpan, into output: inout [UInt8], flush: TransformFlush
) throws(BytesError) -> TransformProgress where Stages.Failure == BytesError {
    try output.withOutputRawSpan { span throws(BytesError) in
        try pipeline.transform(input, into: &span, flush: flush)
    }
}
