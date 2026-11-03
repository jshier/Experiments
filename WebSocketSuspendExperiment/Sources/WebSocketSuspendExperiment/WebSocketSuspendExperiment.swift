// Experiment: URLSessionWebSocketTask behavior when suspended
//
// Experiment 1: Try to send messages while the task is suspended (echo endpoint).
// Experiment 2: Suspend the task mid-stream while the server is delivering payloads.

import Foundation

// MARK: - Helpers

let experimentStart = ContinuousClock.now

func log(_ message: String) {
    let elapsed = experimentStart.duration(to: .now)
    let seconds = Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
    print(String(format: "[%+7.3fs] %@", seconds, message))
}

/// Thread-safe boolean flag.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    func get() -> Bool { lock.withLock { value } }
}

// MARK: - Delegate

/// Implements every URLSessionWebSocketDelegate and URLSessionTaskDelegate method,
/// logging each callback with a timestamp so we can observe exactly when they fire
/// relative to suspension and resume.
final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let name: String

    private let lock = NSLock()
    private var openContinuation: CheckedContinuation<String?, Error>?

    struct CloseEvent {
        let code: URLSessionWebSocketTask.CloseCode
        let reason: String?
        let at: ContinuousClock.Instant
    }
    struct CompleteEvent {
        let error: Error?
        let at: ContinuousClock.Instant
    }

    private(set) var closeEvent: CloseEvent?
    private(set) var completeEvent: CompleteEvent?
    private(set) var openProtocol: String??  // nil = not yet opened; .some(nil) = opened with no protocol

    init(name: String) { self.name = name }

    /// Suspends until the socket opens (or the task fails before opening).
    func awaitOpen() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { openContinuation = continuation }
        }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        log("[\(name)] didOpenWithProtocol: \(`protocol` ?? "(none)")")
        lock.withLock {
            openProtocol = .some(`protocol`)
            openContinuation?.resume(returning: `protocol`)
            openContinuation = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
        log("[\(name)] didCloseWith: code=\(closeCode.rawValue) reason=\(reasonStr) — task state: \(webSocketTask.state.name)")
        lock.withLock {
            closeEvent = CloseEvent(code: closeCode, reason: reasonStr, at: .now)
        }
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            log("[\(name)] didCompleteWithError: \(error.localizedDescription) — task state: \(task.state.name)")
        } else {
            log("[\(name)] didCompleteWithError: nil (success) — task state: \(task.state.name)")
        }
        lock.withLock {
            completeEvent = CompleteEvent(error: error, at: .now)
            // Handle the case where the task fails before the open delegate fires.
            if let error {
                openContinuation?.resume(throwing: error)
                openContinuation = nil
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let duration = metrics.taskInterval.duration
        let transactions = metrics.transactionMetrics.map { t in
            t.networkProtocolName ?? "unknown-protocol"
        }.joined(separator: ", ")
        log("[\(name)] didFinishCollecting: duration=\(String(format: "%.3f", duration))s transactions=[\(transactions)]")
    }
}

// MARK: - URLSessionTask.State name

extension URLSessionTask.State {
    var name: String {
        switch self {
        case .running:    "running"
        case .suspended:  "suspended"
        case .canceling:  "canceling"
        case .completed:  "completed"
        @unknown default: "unknown(\(rawValue))"
        }
    }
}

// MARK: - Experiment 1: Sending while suspended (echo endpoint)

func runEchoExperiment() async {
    log("══════════════════════════════════════════════════════════")
    log("EXPERIMENT 1: Sending while suspended  (ws/echo)")
    log("  Connect → suspend → send (concurrent) → resume → receive")
    log("══════════════════════════════════════════════════════════")

    let delegate = SocketDelegate(name: "echo")
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }

    let task = session.webSocketTask(with: URL(string: "ws://localhost:8080/websocket/echo")!)
    log("Calling task.resume() to connect")
    task.resume()

    do {
        try await delegate.awaitOpen()
    } catch {
        log("Connection failed: \(error)")
        return
    }
    log("Connected — state: \(task.state.name)")

    // Suspend the already-connected task.
    task.suspend()
    log("Called suspend() — state: \(task.state.name)")

    // Kick off a concurrent task that sends while suspended.
    // We must not await it here or we'll deadlock (send won't complete until resumed).
    let sendStart = ContinuousClock.now
    log("Launching concurrent send() while suspended")
    let sendTask = Task {
        do {
            try await task.send(.string("hello while suspended"))
            log("send() returned SUCCESS after \(sendStart.duration(to: .now))")
        } catch {
            log("send() threw after \(sendStart.duration(to: .now)): \(error.localizedDescription)")
            log("  Full send error: \(error)")
        }
    }

    // Give the send call a moment to confirm it's queued/blocking, then resume.
    log("Sleeping 1s to observe send() blocking behavior before resume")
    try? await Task.sleep(for: .seconds(1))
    log("State after 1s with task suspended: \(task.state.name)")

    log("Calling resume()")
    task.resume()
    log("State after resume(): \(task.state.name)")

    // Wait for the send to complete now that we've resumed.
    await sendTask.value

    // Call receive() to find out whether the echo was delivered.
    log("Calling receive() to check for echo")
    do {
        let msg = try await task.receive()
        switch msg {
        case .string(let t): log("Received echo: \"\(t)\"")
        case .data(let d):   log("Received binary echo (\(d.count) bytes)")
        @unknown default:    log("Received unknown message type")
        }
    } catch {
        log("receive() threw: \(error.localizedDescription)")
        log("  Full receive error: \(error)")
    }
}

// MARK: - Experiment 2: Suspend mid-stream — varying message arrival timing

// Three scenarios probe whether URLSession truly buffers incoming frames during suspension,
// or whether the prior experiment's "buffering" was simply the OS TCP receive buffer holding
// frames that had already fully arrived before suspend() was called.
//
// In all scenarios we suspend after receiving message 3 (out of 10), then resume later.
// The messageDelay controls when the server sends each frame relative to the suspension window:
//
//   A  0ms  delay, 2s suspend  — all 10 frames arrive before suspend() is called;
//                                 tests OS TCP buffering of already-arrived data
//   B  300ms delay, 2s suspend — msgs 4–9 arrive from the server DURING suspension;
//                                 tests buffering of frames in-flight while suspended
//   C  500ms delay, 6s suspend — all 7 remaining frames + the close frame arrive
//                                 during suspension; server has long closed by resume

struct PayloadScenario {
    let name: String
    let messageDelayMs: Int  // ms between server sends; passed as ?messageDelay=
    let suspendDuration: Double  // seconds the task stays suspended
    let total: Int
    let suspendAfter: Int

    var url: URL {
        URL(string: "ws://localhost:8080/websocket/payloads/\(total)?messageDelay=\(messageDelayMs)")!
    }
}

let payloadScenarios: [PayloadScenario] = [
    PayloadScenario(
        name: "A — 0ms/msg, 2s suspend (all frames arrive before suspend)",
        messageDelayMs: 0,
        suspendDuration: 2.0,
        total: 10,
        suspendAfter: 3
    ),
    PayloadScenario(
        name: "B — 300ms/msg, 2s suspend (~6 frames arrive during suspension)",
        messageDelayMs: 300,
        suspendDuration: 2.0,
        total: 10,
        suspendAfter: 3
    ),
    PayloadScenario(
        name: "C — 500ms/msg, 6s suspend (all remaining frames + close arrive during suspension)",
        messageDelayMs: 500,
        suspendDuration: 6.0,
        total: 10,
        suspendAfter: 3
    ),
]

func runPayloadsScenario(_ scenario: PayloadScenario) async {
    log("──────────────────────────────────────────────────────────")
    log("Scenario \(scenario.name)")
    log("  \(scenario.total) messages, \(scenario.messageDelayMs)ms between sends,")
    log("  suspend after msg \(scenario.suspendAfter), resume after \(scenario.suspendDuration)s")
    log("──────────────────────────────────────────────────────────")

    let delegate = SocketDelegate(name: "scenario-\(String(scenario.name.prefix(1)))")
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }

    let task = session.webSocketTask(with: scenario.url)
    task.resume()

    do {
        try await delegate.awaitOpen()
    } catch {
        log("  Connection failed: \(error)")
        return
    }

    var received = 0
    var suspendedAt: ContinuousClock.Instant?

    receiveLoop: while true {
        do {
            let receiveStart = ContinuousClock.now
            let msg = try await task.receive()
            received += 1
            let elapsed = receiveStart.duration(to: .now)
            let size: String
            switch msg {
            case .string(let t): size = "\(t.count) chars"
            case .data(let d):   size = "\(d.count) bytes"
            @unknown default:    size = "unknown"
            }
            // Note whether this message arrived instantly (buffered) or after a delay (live).
            let receiveNote = elapsed < .milliseconds(50) ? "instant" : "\(elapsed)"
            log("  msg \(received)/\(scenario.total): \(size), receive() returned in \(receiveNote) — state: \(task.state.name)")

            if received == scenario.suspendAfter {
                // Suspend with no pending receive() call — the next receive() won't be
                // called until after resume(). Any frames that arrive from the server
                // during this window must be buffered by URLSession if they are to be
                // delivered at all.
                suspendedAt = .now
                task.suspend()
                log("  → Suspended (state: \(task.state.name)); server will send \(scenario.total - received) more frames")
                log("    Server delivery window: msgs \(received+1)–\(scenario.total) at \(scenario.messageDelayMs)ms intervals")
                log("    Sleeping \(scenario.suspendDuration)s before resume")
                try await Task.sleep(for: .seconds(scenario.suspendDuration))
                let suspendElapsed = suspendedAt!.duration(to: .now)
                log("  → Resuming after \(suspendElapsed) (state before: \(task.state.name))")
                task.resume()
                log("    State after resume(): \(task.state.name)")
                // Re-arm the receive loop — no pending receive() was in flight during suspension.
            }
        } catch {
            log("  receive() threw after \(received) msgs: \(error.localizedDescription)")
            log("  Final state: \(task.state.name)")
            break receiveLoop
        }
    }

    let verdict: String
    if received == scenario.total {
        verdict = "✓ ALL \(scenario.total) messages received"
    } else {
        verdict = "✗ Only \(received)/\(scenario.total) messages received — \(scenario.total - received) lost"
    }
    log("  Result: \(verdict)")

    // Summarise which delegate callbacks fired and when, relative to suspension.
    if let suspendedAt {
        func elapsed(from anchor: ContinuousClock.Instant, to event: ContinuousClock.Instant) -> String {
            let d = anchor.duration(to: event)
            let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            return String(format: "%+.3fs after suspend", s)
        }
        log("  ── Delegate callback timeline (anchor = moment of suspend()) ──")
        if let e = delegate.closeEvent {
            log("  didCloseWith: fired \(elapsed(from: suspendedAt, to: e.at)), code=\(e.code.rawValue)")
        } else {
            log("  didCloseWith: NOT called")
        }
        if let e = delegate.completeEvent {
            log("  didCompleteWithError: fired \(elapsed(from: suspendedAt, to: e.at)), error=\(e.error.map { $0.localizedDescription } ?? "nil")")
        } else {
            log("  didCompleteWithError: NOT called yet")
        }
    }
}

func runPayloadsExperiment() async {
    log("══════════════════════════════════════════════════════════")
    log("EXPERIMENT 2: Suspend mid-stream — varying message timing")
    log("══════════════════════════════════════════════════════════")
    print()
    for scenario in payloadScenarios {
        await runPayloadsScenario(scenario)
        print()
    }
}

// MARK: - Experiment 3: Sending before didOpenWithProtocol (openDelay)

// The server delays its 101 Switching Protocols response by `openDelay` ms.
// After task.resume() the task is .running and TCP is connected, but the WebSocket
// handshake has not completed — didOpenWithProtocol has not fired.
//
// Question: does send() queue and wait for the handshake (like it does during suspension),
//           fail immediately, or succeed but silently drop the message?
//
// We test two send timings to distinguish "before TCP" from "after TCP, before 101":
//   Early — send() called in the same event loop turn as resume(), before TCP even connects
//   Late  — send() called after a short sleep, TCP is up but 101 is still pending

func runPreOpenExperiment() async {
    let openDelayMs = 2000

    log("══════════════════════════════════════════════════════════")
    log("EXPERIMENT 3: Sending before didOpenWithProtocol")
    log("  Server delays 101 response by \(openDelayMs)ms (?openDelay=\(openDelayMs))")
    log("  Sub-experiment A: send() immediately after resume() (pre-TCP)")
    log("  Sub-experiment B: send() after 200ms sleep (post-TCP, pre-101)")
    log("══════════════════════════════════════════════════════════")

    for (label, preSendDelay) in [("A (immediate, pre-TCP)", 0.0), ("B (200ms, post-TCP pre-101)", 0.2)] {
        print()
        log("── Sub-experiment \(label) ──")

        let delegate = SocketDelegate(name: "pre-open-\(label.prefix(1).lowercased())")
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let url = URL(string: "ws://localhost:8080/websocket/echo?openDelay=\(openDelayMs)")!
        let task = session.webSocketTask(with: url)

        log("Calling task.resume() — state before: \(task.state.name)")
        task.resume()
        log("State immediately after resume(): \(task.state.name)")

        if preSendDelay > 0 {
            log("Sleeping \(preSendDelay)s to let TCP connect before send()")
            try? await Task.sleep(for: .seconds(preSendDelay))
            log("State after sleep (TCP up, 101 still pending): \(task.state.name)")
        }

        // Track when the open fires relative to when we call send().
        let resumeInstant = ContinuousClock.now

        let openFired = Flag()

        // Watch for open in a background task — we don't await it before sending.
        let openWatcher = Task {
            do {
                try await delegate.awaitOpen()
                let elapsed = resumeInstant.duration(to: .now)
                log("  [watcher] didOpenWithProtocol fired after \(elapsed) — state: \(task.state.name)")
                openFired.set()
            } catch {
                log("  [watcher] open failed: \(error.localizedDescription)")
            }
        }

        // Call send() — the open has NOT fired yet.
        let sendStart = ContinuousClock.now
        log("Calling send() — didOpen has NOT fired yet, state: \(task.state.name)")
        let sendTask = Task {
            do {
                try await task.send(.string("hello before open"))
                let elapsed = sendStart.duration(to: .now)
                let openHadFired = openFired.get()
                log("  send() SUCCESS after \(elapsed) — didOpen had fired by then: \(openHadFired), state: \(task.state.name)")
            } catch {
                let elapsed = sendStart.duration(to: .now)
                log("  send() THREW after \(elapsed): \(error.localizedDescription)")
                log("  Full send error: \(error)")
            }
        }

        // Wait for both open and send to settle (openDelay + margin).
        try? await Task.sleep(for: .seconds(Double(openDelayMs) / 1000.0 + 1.0))
        await sendTask.value
        await openWatcher.value

        // Now call receive() to find out if the echo arrived.
        if task.state == .running {
            log("Calling receive() to check for echo")
            do {
                let msg = try await task.receive()
                switch msg {
                case .string(let t): log("  Received echo: \"\(t)\"")
                case .data(let d):   log("  Received binary echo (\(d.count) bytes)")
                @unknown default:    log("  Received unknown message type")
                }
            } catch {
                log("  receive() threw: \(error.localizedDescription)")
                log("  Full receive error: \(error)")
            }
        } else {
            log("Task is \(task.state.name) — skipping receive()")
        }

        log("── Sub-experiment \(label) complete ──")
    }
}

// MARK: - Experiment 4: Sending without calling resume() first

// A new URLSessionWebSocketTask starts in .suspended state.
// The normal path is resume() → connect → send(). This experiment asks:
//
//   A — send() on a never-resumed task (initial .suspended, no resume() ever called).
//         Does it block forever? Fail immediately? The task has no TCP connection at all.
//
//   B — explicit suspend() on an already-suspended new task, then send().
//         Does calling suspend() on a task that was never started behave differently
//         than simply never calling resume()?
//
// For both sub-experiments we wait 1s (to observe whether send() is blocking vs failing),
// then call resume() and see whether the queued send completes and an echo is returned.

func runNeverResumedExperiment() async {
    log("══════════════════════════════════════════════════════════")
    log("EXPERIMENT 4: Sending without calling resume() first")
    log("  A: send() on task that has never had resume() called")
    log("  B: explicit suspend() on new task, then send()")
    log("  Both: after 1s, call resume() — does the send complete?")
    log("══════════════════════════════════════════════════════════")

    let variants: [(label: String, explicitSuspend: Bool)] = [
        ("A (never resumed)", false),
        ("B (explicit suspend before send)", true),
    ]

    for variant in variants {
        print()
        log("── Sub-experiment \(variant.label) ──")

        let delegate = SocketDelegate(name: "never-resumed-\(variant.label.prefix(1).lowercased())")
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.webSocketTask(with: URL(string: "ws://localhost:8080/websocket/echo")!)
        log("Task created — state: \(task.state.name)")

        if variant.explicitSuspend {
            task.suspend()
            log("Called suspend() explicitly — state: \(task.state.name)")
        }

        // Arm a concurrent open-watcher so we can see if/when didOpenWithProtocol fires.
        let openWatcher = Task {
            do {
                try await delegate.awaitOpen()
                log("  [watcher] didOpenWithProtocol fired — state: \(task.state.name)")
            } catch {
                log("  [watcher] open error: \(error.localizedDescription)")
            }
        }

        // sendDone tracks whether the sendTask closure body has returned.
        // We check this flag instead of awaiting sendTask.value when there's a risk
        // the send is stuck — URLSessionWebSocketTask.send() in certain broken states
        // leaks its continuation and never returns even after session.invalidateAndCancel().
        let sendDone = Flag()
        let sendStart = ContinuousClock.now
        log("Calling send() — state: \(task.state.name), no resume() called yet")
        let sendTask = Task {
            do {
                try await task.send(.string("hello without resume"))
                log("  send() SUCCESS after \(sendStart.duration(to: .now)) — state: \(task.state.name)")
            } catch {
                log("  send() THREW after \(sendStart.duration(to: .now)): \(error.localizedDescription)")
            }
            sendDone.set()
        }

        // Observe for 1s without calling resume() — is send() blocking or has it already failed?
        try? await Task.sleep(for: .seconds(1))
        log("After 1s — state: \(task.state.name), send completed: \(sendDone.get())")

        // Now call resume() and see whether the task connects and the send completes.
        log("Calling resume() (first call)")
        task.resume()
        log("State after first resume(): \(task.state.name)")

        // Give the task 2s to connect and deliver the send.
        try? await Task.sleep(for: .seconds(2))

        if task.state == .suspended {
            // Suspend count may be > 1 — try a second resume().
            log("Still suspended after 2s — second resume() (suspend-count > 1 hypothesis)")
            task.resume()
            log("State after second resume(): \(task.state.name)")
            try? await Task.sleep(for: .seconds(2))
        }

        if sendDone.get() {
            // send() completed — wait briefly for openWatcher to settle.
            await openWatcher.value

            if task.state == .running {
                log("Calling receive() to check for echo")
                do {
                    let msg = try await task.receive()
                    switch msg {
                    case .string(let t): log("  Received echo: \"\(t)\"")
                    case .data(let d):   log("  Received binary echo (\(d.count) bytes)")
                    @unknown default:    log("  Received unknown message type")
                    }
                } catch {
                    log("  receive() threw: \(error.localizedDescription)")
                }
            } else {
                log("Task is \(task.state.name) after resume — no echo to receive")
            }
        } else {
            // send() is permanently stuck — force-cancel and report.
            // Do NOT await sendTask: its continuation is leaked and will never resume.
            sendTask.cancel()
            openWatcher.cancel()
            task.cancel()
            session.invalidateAndCancel()
            log("  send() still blocking after all resume() attempts — session invalidated")
            log("  didOpenWithProtocol fired: \(delegate.openProtocol != nil)")
            log("  didFinishCollecting transactions: \(delegate.completeEvent == nil ? "pending" : "received")")
        }

        log("── Sub-experiment \(variant.label) complete ──")
    }
}


// MARK: - Entry point

@main
struct WebSocketSuspendExperiment {
    static func main() async {
        // Optional argument: "1" | "2" | "3" | "4" — runs only that experiment.
        // With no argument, all four experiments run in sequence.
        let arg = CommandLine.arguments.dropFirst().first

        let experiments: [(String, () async -> Void)] = [
            ("1", runEchoExperiment),
            ("2", runPayloadsExperiment),
            ("3", runPreOpenExperiment),
            ("4", runNeverResumedExperiment),
        ]

        for (number, run) in experiments {
            guard arg == nil || arg == number else { continue }
            await run()
            print()
        }
    }
}

