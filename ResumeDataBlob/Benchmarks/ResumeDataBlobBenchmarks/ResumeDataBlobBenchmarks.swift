import Benchmark
import Foundation
import ResumeDataBlobKit
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The result of the one-shot fixture capture, protected by a `Mutex` so the background `Task`
/// (producer) and the polling loop below (consumer) can share it safely without a lock wrapper
/// or `DispatchSemaphore`. `.pending` is distinct from `.completed(nil)` so a failed capture
/// (rather than a not-yet-finished one) can be detected and reported.
private enum FixtureCaptureState {
    case pending
    case completed(Data?)
}

/// Captures one real resume data blob from the local Firewalk server, synchronously, so it can
/// be used as a shared fixture by every benchmark below. `benchmarks` (below) is a plain
/// synchronous closure, so this bridges the one `async` call it needs to make by starting an
/// unstructured `Task` and cooperatively polling a `Mutex`-guarded result rather than blocking
/// on a `DispatchSemaphore`.
private func captureFixtureResumeData() -> Data {
    let state = Mutex(FixtureCaptureState.pending)
    Task {
        let captured = await ResumeDataFixture.capture()
        state.withLock { $0 = .completed(captured) }
    }

    while true {
        let snapshot = state.withLock { $0 }
        switch snapshot {
        case .pending:
            Thread.sleep(forTimeInterval: 0.01)
        case let .completed(data):
            guard let data else {
                fatalError(
                    "Could not capture a resume data blob from Firewalk at \(Configuration.baseURL). " +
                        "Make sure it's running before executing the benchmarks."
                )
            }
            return data
        }
    }
}

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .throughput, .instructions, .mallocCountTotal, .memoryLeaked, .peakMemoryResidentDelta],
        warmupIterations: 3
    )

    // Captured once, shared (read-only) by every benchmark iteration below.
    let resumeData = captureFixtureResumeData()
    guard let fixtureEnvelope = ResumeDataCodec.decodeDirect(from: resumeData) else {
        fatalError("Captured resume data could not be decoded to build the encode-benchmark fixture.")
    }

    // MARK: - Decoding: raw resume data bytes -> ResumeDataEnvelope

    Benchmark("Decode.Direct (NSKeyedUnarchiver -> manual fields)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(ResumeDataCodec.decodeDirect(from: resumeData))
        }
    }

    Benchmark("Decode.PerKey (NSKeyedUnarchiver, no [String: Any] bridge)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(ResumeDataCodec.decodePerKey(from: resumeData))
        }
    }

    Benchmark("Decode.Codable (NSKeyedUnarchiver -> re-flatten -> PropertyListDecoder)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(ResumeDataCodec.decodeCodable(from: resumeData))
        }
    }

    // MARK: - Encoding: ResumeDataEnvelope -> resume data bytes usable by URLSession

    Benchmark("Encode.Direct (manual dictionary -> NSKeyedArchiver)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(ResumeDataCodec.encodeDirect(fixtureEnvelope))
        }
    }

    Benchmark("Encode.Codable (PropertyListEncoder -> re-parse -> NSKeyedArchiver)") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(ResumeDataCodec.encodeCodable(fixtureEnvelope))
        }
    }
}
