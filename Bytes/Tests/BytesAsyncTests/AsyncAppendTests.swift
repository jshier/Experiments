import Bytes
import BytesAsync
import Dispatch
import Testing

/// Appending through `AsyncByteTransform.transform(_:appending:)` and `[UInt8].append(receivingUpTo:)`: the stage writes
/// the array's new capacity in place, across suspensions, and the output matches the synchronous drive loop's.
@Suite struct AsyncAppendTests {
    static let input: [UInt8] = (0..<50_000).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 11) }

    /// Copies its input.
    struct Copy: ByteTransform {
        typealias Failure = Never

        mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) -> TransformProgress {
            let count = min(input.byteCount, output.freeCapacity)
            output.append(copying: input.extracting(0..<count))
            return TransformProgress(consumed: count, produced: count, status: Self.status(count, input.byteCount, flush))
        }

        static func status(_ count: Int, _ total: Int, _ flush: TransformFlush) -> TransformStatus {
            count < total ? .needsOutput : flush == .finish ? .finished : .needsInput
        }
    }

    /// Writes `factor` copies of each input byte, whole or not at all: it needs `factor` bytes of room to make progress
    /// (its `minimumOutputCapacity`), like a decoder's output for a unit of input.
    struct Expand: ByteTransform {
        typealias Failure = Never
        static var factor: Int { 4_096 }
        static var minimumOutputCapacity: Int { factor }

        mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) -> TransformProgress {
            let count = min(input.byteCount, output.freeCapacity / Self.factor)
            for index in 0..<count {
                let byte = input.load(fromByteOffset: index, as: UInt8.self)
                output.withFreeCapacity(byteCount: Self.factor) { span, written in
                    for offset in stride(from: 0, to: Self.factor, by: 8) {
                        span.storeBytes(of: UInt64(byte) &* 0x0101_0101_0101_0101, toByteOffset: offset, as: UInt64.self)
                    }
                    written = Self.factor
                }
            }
            return TransformProgress(consumed: count, produced: count &* Self.factor, status: Copy.status(count, input.byteCount, flush))
        }
    }

    /// Throws once it has consumed `limit` bytes in all.
    struct FailAfter: ByteTransform {
        struct Stop: Error {}
        typealias Failure = Stop
        var left: Int

        mutating func transform(_ input: RawSpan, into output: inout OutputRawSpan, flush: TransformFlush) throws(Stop) -> TransformProgress {
            let count = min(input.byteCount, output.freeCapacity, left)
            output.append(copying: input.extracting(0..<count))
            left -= count
            if left == 0, count < input.byteCount { throw Stop() }
            return TransformProgress(consumed: count, produced: count, status: Copy.status(count, input.byteCount, flush))
        }
    }

    /// The same bytes as the synchronous drive loop, for each growth, onto an array that isn't empty, with the calls in
    /// place and on a queue (a real suspension each round).
    @Test(arguments: [1, 7, 16 << 10])
    func matchesTheSynchronousForm(growth: Int) async {
        let prefix: [UInt8] = [9, 8, 7]
        var expected = prefix
        var copy = Copy()
        _ = copy.transform(Self.input.span.bytes, appending: &expected, flush: .finish, growth: growth)
        var inPlace = prefix
        var synchronous = Copy().synchronously()
        let progress = await synchronous.transform(Self.input.span.bytes, appending: &inPlace, flush: .finish, growth: growth)
        #expect(progress.consumed == Self.input.count && progress.produced == Self.input.count && progress.status == .finished)
        #expect(inPlace == expected)
        var queued = prefix
        var offloaded = Copy().offloaded(to: DispatchQueue(label: "append"))
        _ = await offloaded.transform(Self.input.span.bytes, appending: &queued, flush: .finish, growth: growth)
        #expect(queued == expected)
    }

    /// A stage needing more room than `growth` gets its minimum: the async form ignored it, and looped on `needsOutput`
    /// with nothing produced (hence the time limit).
    @Test(.timeLimit(.minutes(1))) func roomIsAtLeastTheStagesMinimum() async {
        let input = [UInt8](Self.input.prefix(2_048))
        var output: [UInt8] = []
        var stage = Expand().synchronously()
        let progress = await stage.transform(input.span.bytes, appending: &output, flush: .finish, growth: 1)
        #expect(progress.status == .finished && output.count == input.count * Expand.factor)
        #expect(output[Expand.factor * 1_000] == input[1_000] && output.last == input.last)
        var synchronous: [UInt8] = []
        var expand = Expand()
        _ = expand.transform(input.span.bytes, appending: &synchronous, flush: .finish, growth: 1)
        #expect(synchronous == output)
    }

    /// Both appends grow an array geometrically: 1,000 appends of 16 bytes change its capacity about 10 times, not on
    /// every append (an exact reserve each round reallocated each round).
    @Test func appendsGrowGeometrically() async {
        var receiving: [UInt8] = []
        var writing: [UInt8] = []
        var receivingGrowths = 0, writingGrowths = 0
        for _ in 0..<1_000 {
            var before = receiving.capacity
            await receiving.append(receivingUpTo: 16) { output in output.append(copying: Self.input.span.bytes.extracting(0..<16)) }
            if receiving.capacity != before { receivingGrowths += 1 }
            before = writing.capacity
            writing.append(writingUpTo: 16) { output in output.append(copying: Self.input.span.bytes.extracting(0..<16)) }
            if writing.capacity != before { writingGrowths += 1 }
        }
        #expect(receiving.count == 16_000 && writing == receiving)
        #expect(receivingGrowths <= 20 && writingGrowths <= 20, "\(receivingGrowths), \(writingGrowths)")
    }

    /// A stage that throws: what earlier calls appended stays, nothing of the round that threw (it had copied 10,000
    /// bytes into the array's capacity before throwing).
    @Test func aThrowingStageKeepsEarlierOutput() async throws {
        var output: [UInt8] = [1]
        var stage = FailAfter(left: 30_000).synchronously()
        let first = try await stage.transform(Self.input.span.bytes.extracting(0..<20_000), appending: &output, flush: .none)
        #expect(first.produced == 20_000)
        await #expect(throws: FailAfter.Stop.self) {
            _ = try await stage.transform(Self.input.span.bytes.extracting(20_000...), appending: &output, flush: .finish)
        }
        #expect(output == [1] + Self.input[..<20_000])
    }

    /// `append(receivingUpTo:)` itself: counts only what the body wrote, keeps the bytes before, leaves a copy that
    /// shared the storage alone, appends nothing when the body throws, and takes 0 bytes.
    @Test func appendReceivingCountsWhatWasWritten() async {
        var array: [UInt8] = [1, 2, 3]
        let shared = array
        let result = await array.append(receivingUpTo: 100) { output in
            await Task.yield()
            output.append(copying: [4, 5].span)
            return output.byteCount
        }
        #expect(result == 2 && array == [1, 2, 3, 4, 5] && shared == [1, 2, 3])
        await #expect(throws: FailAfter.Stop.self) {
            try await array.append(receivingUpTo: 10) { (output: inout OutputRawSpan) async throws(FailAfter.Stop) in
                output.append(copying: [6].span)
                throw FailAfter.Stop()
            }
        }
        #expect(array == [1, 2, 3, 4, 5])
        let none = await array.append(receivingUpTo: 0) { output in output.freeCapacity }
        #expect(none == 0 && array == [1, 2, 3, 4, 5])
    }
}
