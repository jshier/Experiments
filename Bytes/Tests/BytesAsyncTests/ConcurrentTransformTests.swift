import Bytes
import BytesAsync
import Dispatch
import Testing

/// `concurrently()`: a stage's calls run in a `@concurrent` function, off the caller's actor. (The round trips with a
/// codec as the stage moved with BytesCompression to its own package:
/// BytesCompression/Tests/BytesCompressionTests/ConcurrentTransformTests.swift.)
@Suite struct ConcurrentTransformTests {
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

    mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) -> TransformProgress {
        ranOnActor = DispatchQueue.getSpecific(key: QueueActor.key) == true
        let count = min(input.byteCount, output.freeCapacity)
        output.append(copying: input.extracting(0..<count))
        let done = count == input.byteCount
        return TransformProgress(consumed: count, produced: count, status: done ? (flush == .finish ? .finished : .needsInput) : .needsOutput)
    }
}
