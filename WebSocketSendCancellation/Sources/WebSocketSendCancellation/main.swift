import Foundation

// MARK: - Experiment

//
// Question: Does URLSessionWebSocketTask.send() complete when the task is cancelled
// while a send is in-flight, and if so, does it return an error?
//
// URLSessionWebSocketTask.send() wraps the completion-handler API in a continuation.
// If cancellation causes URLSession to drop the completion handler call, the continuation
// would never resume — a permanent hang. The experiments below probe both cases:
//
//   Scenario A — Cancel before send (deterministic):
//     Cancel the task first, then call send(). Does send() throw immediately?
//
//   Scenario B — Cancel concurrently with send (race):
//     Connect to /websocket/payloads/0?closeDelay=60000 — a WebSocket that stays
//     open without writing back, so no echo-induced backpressure closes the connection.
//     Send a large message (1 MB) and immediately cancel the task. Run 5 iterations
//     with increasing delays between send() and cancel() to sample different points in
//     the race window. A 5-second timeout per iteration detects a hung continuation.

// MARK: - State

actor Outcome {
    private(set) var result: Result<Void, Error>?
    var isDone: Bool { result != nil }
    func record(_ r: Result<Void, Error>) { result = r }
}

// MARK: - Helpers

// /websocket/payloads/0 with a 60-second close delay: the server keeps the connection
// open without echoing anything back, so our sends don't trigger echo backpressure.
let baseURL = URL(string: "ws://127.0.0.1:8080/websocket/payloads/0?closeDelay=60000")!
let largeMessage = Data(repeating: 0x41, count: 1 * 1024 * 1024) // 1 MB

func section(_ title: String) {
    print("\n" + String(repeating: "─", count: 60))
    print(title)
    print(String(repeating: "─", count: 60))
}

func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

func describe(_ e: Error) -> String {
    let ns = e as NSError
    return "\(ns.domain) \(ns.code) — \(ns.localizedDescription)"
}

// MARK: - Scenario A: cancel before send

section("Scenario A: cancel() before send()")

let taskA = URLSession.shared.webSocketTask(with: baseURL)
taskA.resume()
try await Task.sleep(for: .milliseconds(100))

taskA.cancel(with: .normalClosure, reason: nil)
try await Task.sleep(for: .milliseconds(50))

print("[\(ts())] Calling send() on a task that has already been cancelled...")
do {
    try await taskA.send(.string("hello"))
    print("[\(ts())] -> send() returned without error")
} catch {
    print("[\(ts())] -> send() threw: \(describe(error))")
}

// MARK: - Scenario B: cancel concurrently with send

section("Scenario B: cancel() concurrently with send() — 5 iterations")

// Each iteration uses a fresh task. We vary the delay between starting the send
// and calling cancel() to sample different points in the race window.
let cancelDelays: [Duration] = [.zero, .milliseconds(1), .milliseconds(5), .milliseconds(10), .milliseconds(50)]

for (i, cancelDelay) in cancelDelays.enumerated() {
    print("\n  Iteration \(i + 1)/\(cancelDelays.count)  cancelDelay=\(cancelDelay)")

    let wsTask = URLSession.shared.webSocketTask(with: baseURL)
    wsTask.resume()
    try await Task.sleep(for: .milliseconds(100)) // let the handshake complete

    let outcome = Outcome()

    // Unstructured Task so Swift cooperative cancellation of our outer context
    // cannot mask a URLSession-level hang in the send() continuation.
    let sendTask = Task {
        let start = ContinuousClock.now
        do {
            try await wsTask.send(.data(largeMessage))
            let elapsed = ContinuousClock.now - start
            await outcome.record(.success(()))
            print("    [\(ts())] send() returned without error (took \(elapsed))")
        } catch {
            let elapsed = ContinuousClock.now - start
            await outcome.record(.failure(error))
            print("    [\(ts())] send() threw after \(elapsed): \(describe(error))")
        }
    }

    if cancelDelay > .zero {
        try await Task.sleep(for: cancelDelay)
    }
    wsTask.cancel(with: .normalClosure, reason: nil)
    print("    [\(ts())] cancel() called")

    // Poll for up to 5 s. No result within that window means the continuation hung.
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await outcome.isDone { break }
        try await Task.sleep(for: .milliseconds(100))
    }

    let hung = await !outcome.isDone
    if hung {
        sendTask.cancel() // best-effort; has no effect on a hung URLSession continuation
        print("    [\(ts())] -> WARNING: send() continuation never resumed within 5 s")
    }
}
