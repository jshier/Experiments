import Alamofire
import Benchmark
import Foundation

// MARK: - Configuration

private let url = URL(string: "ws://127.0.0.1:8080/websocket/echo")!
private let payload = Data(repeating: 0x42, count: 64)

// MARK: - Socket wrappers

// Wraps URLSessionWebSocketTask for @unchecked Sendable use across setup/benchmark/teardown.
private final class URLSessionSocket: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    let message = URLSessionWebSocketTask.Message.data(Data(repeating: 0x42, count: 64))

    init() {
        task = URLSession.shared.webSocketTask(with: url)
        task.resume()
    }
}

// Wraps an Alamofire WebSocketRequest and holds the single long-lived message stream iterator
// so we can drive a persistent ping-pong loop across many benchmark iterations.
private final class AlamofireSocket: @unchecked Sendable {
    let request: WebSocketRequest
    // The stream iterator is stored as a var so each call to iterator.next() advances it in place.
    var iterator: StreamOf<URLSessionWebSocketTask.Message>.AsyncIterator
    let message = URLSessionWebSocketTask.Message.data(Data(repeating: 0x42, count: 64))

    init() {
        request = AF.webSocketRequest(to: url)
        // automaticallyCancelling: false — we cancel explicitly in teardown.
        iterator = request.streamingMessages(automaticallyCancelling: false).makeAsyncIterator()
    }
}

// MARK: - Shared benchmark state

//
// nonisolated(unsafe) lets setup and teardown hooks (which run outside the benchmark closure)
// share state with each other. Benchmarks run serially so there is no actual data race.

private nonisolated(unsafe) var urlSocket: URLSessionSocket?
private nonisolated(unsafe) var afSocket: AlamofireSocket?

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    // Each benchmark iteration performs 1 000 round-trips (scalingFactor: .kilo).
    // package-benchmark derives throughput as (scalingFactor × iterations) / wall-time,
    // which gives messages-per-second — matching the original hand-rolled benchmark.
    let config = Benchmark.Configuration(
        metrics: .all,
        scalingFactor: .kilo,
        maxDuration: .seconds(5),
        maxIterations: 10_000,
        thresholds: [.throughput: .relaxed, .wallClock: .relaxed]
    )

    // ── URLSession ──────────────────────────────────────────────────────────

    Benchmark("URLSession", configuration: config) { benchmark in
        guard let socket = urlSocket else { return }
        for _ in benchmark.scaledIterations {
            try? await socket.task.send(socket.message)
            _ = try? await socket.task.receive()
        }
    } setup: {
        urlSocket = URLSessionSocket()
    } teardown: {
        urlSocket?.task.cancel(with: .normalClosure, reason: nil)
        urlSocket = nil
    }

    // ── Alamofire ───────────────────────────────────────────────────────────

    Benchmark("Alamofire", configuration: config) { benchmark in
        guard let socket = afSocket else { return }
        for _ in benchmark.scaledIterations {
            try? await socket.request.send(socket.message).get()
            _ = await socket.iterator.next()
        }
    } setup: {
        afSocket = AlamofireSocket()
    } teardown: {
        afSocket?.request.close(sending: .normalClosure)
        afSocket = nil
    }
}
