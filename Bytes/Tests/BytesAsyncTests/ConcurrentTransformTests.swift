import Bytes
import BytesAsync
import BytesCompression
import Dispatch
import Testing

/// `concurrently()`: a stage's calls run in a `@concurrent` function, off the caller's actor.
@Suite struct ConcurrentTransformTests {
    static let text: [UInt8] = Array(String(repeating: "Pack my box with five dozen liquor jugs. ", count: 4_000).utf8)

    /// The concurrent adapter produces the stage's output, through the drive loop.
    @Test func roundTrips() async throws {
        var reference: [UInt8] = []
        var encoder = DeflateEncoder(format: .gzip, level: 6)
        _ = try encoder.transform(Self.text.span.bytes, appending: &reference, flush: .finish)

        var concurrent = DeflateEncoder(format: .gzip, level: 6).concurrently()
        var compressed: [UInt8] = []
        let progress = try await concurrent.transform(Self.text.span.bytes, appending: &compressed, flush: .finish, growth: 1_000)
        #expect(progress.status == .finished && compressed == reference)

        var decoder = DeflateDecoder(format: .gzip).concurrently()
        var decoded: [UInt8] = []
        _ = try await decoder.transform(compressed.span.bytes, appending: &decoded, flush: .finish)
        #expect(decoded == Self.text)
    }

    /// A concurrent stage's error comes back to the caller, and nothing it wrote is counted.
    @Test func errorsPropagate() async {
        var decoder = DeflateDecoder(format: .zlib).concurrently()
        var output: [UInt8] = []
        await #expect(throws: BytesError.self) {
            _ = try await decoder.transform([0xFF, 0xFF, 0xFF].span.bytes, appending: &output, flush: .finish)
        }
        #expect(output.isEmpty)
    }

    /// Called from an actor, a synchronous stage runs on the actor's executor, a concurrent one doesn't.
    @Test func concurrentStagesLeaveTheActor() async {
        let owner = QueueActor()
        let (synchronous, concurrent) = await owner.runStages()
        #expect(synchronous)
        #expect(!concurrent)
    }
}

/// An actor whose executor is a Dispatch queue with a marker, so a stage can tell whether it runs there.
actor QueueActor {
    static let key = DispatchSpecificKey<Bool>()
    let queue: DispatchSerialQueue

    init() {
        queue = DispatchSerialQueue(label: "QueueActor")
        queue.setSpecific(key: Self.key, value: true)
    }

    // Unsafe: an unowned reference to the queue. Safe: the actor holds the queue for its lifetime.
    nonisolated var unownedExecutor: UnownedSerialExecutor { unsafe queue.asUnownedSerialExecutor() }

    /// Whether each adapter ran its stage on this actor's queue.
    func runStages() async -> (synchronous: Bool, concurrent: Bool) {
        var synchronous = Probe().synchronously()
        var concurrent = Probe().concurrently()
        var output: [UInt8] = []
        _ = await synchronous.transform([1, 2, 3].span.bytes, appending: &output, flush: .finish)
        _ = await concurrent.transform([1, 2, 3].span.bytes, appending: &output, flush: .finish)
        return (synchronous.base.ranOnActor, concurrent.base.ranOnActor)
    }
}

/// A stage that copies its input and records whether it ran on ``QueueActor``'s queue.
struct Probe: ByteTransform {
    var ranOnActor = false

    mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(Never) -> TransformProgress {
        ranOnActor = DispatchQueue.getSpecific(key: QueueActor.key) == true
        let count = min(input.byteCount, output.freeCapacity)
        output.append(copying: input.extracting(0..<count))
        let done = count == input.byteCount
        return TransformProgress(consumed: count, produced: count, status: done ? (flush == .finish ? .finished : .needsInput) : .needsOutput)
    }
}
