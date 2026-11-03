import Foundation

// Experiment: URLSessionWebSocketTask.sendPing behavior when the connection is
// closed before the pong is sent.
//
// Server endpoint: ws://127.0.0.1:8080/websocket/pingDelay/:interval
//   On receiving a ping, the server immediately calls socket.close(), then
//   sleeps for :interval seconds.  No pong is ever sent — the connection is
//   closed first.  The sleep controls how long the event-loop thread is blocked
//   *after* the close call, which affects how quickly the close frame is
//   flushed to the client and the TCP connection is torn down.
//
// Question: Does sendPing receive a callback at all in this case, and if so,
//           what does it return?  Does the post-close sleep duration affect the
//           result?
//
// Scenarios (interval = post-close server sleep duration):
//   A  0s  — close is called; event loop yields immediately (no block)
//   B  1s  — event loop blocked 1s after close
//   C  2s  — event loop blocked 2s after close
//   D  5s  — event loop blocked 5s after close
//
// Each measurement races sendPing against a deadline of (interval + 10)s so
// the experiment terminates even if the callback is never invoked.
//
// RESULTS (multiple independent runs, fully reproducible for B–E):
//   A  pingDelay/0   → NON-DETERMINISTIC: sometimes callback success ~2ms,
//                       sometimes NO CALLBACK (deadline hit).  The interval=0
//                       case races NIO's pong flush against the close frame;
//                       with no post-close sleep the event loop occasionally
//                       flushes the pong before closing, yielding a genuine
//                       pong response.
//   B  pingDelay/1   → NO CALLBACK (deadline hit at ~11s)
//   C  pingDelay/2   → NO CALLBACK (deadline hit at ~12s)
//   D  pingDelay/5   → NO CALLBACK (deadline hit at ~15s)
//   E  un-resumed    → NO CALLBACK (deadline hit at ~10s)
//
// CONCLUSION:
//   URLSessionWebSocketTask.sendPing silently drops its callback in two cases:
//     1. The connection is closed before the pong is received (scenarios B–D).
//     2. The task has never been resumed (scenario E).
//   In both cases the callback is never invoked — not with an error, not with
//   success.  Callers cannot rely on sendPing to detect either condition; any
//   code awaiting the sendPing callback will hang indefinitely unless it
//   imposes its own timeout.

// MARK: - Helpers

func section(_ title: String) {
    print("\n" + String(repeating: "─", count: 70))
    print(title)
    print(String(repeating: "─", count: 70))
}

func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

func describe(_ e: Error) -> String {
    let ns = e as NSError
    return "[\(ns.domain) \(ns.code)] \(ns.localizedDescription)"
}

func pingDelayURL(_ interval: Int) -> URL {
    URL(string: "ws://127.0.0.1:8080/websocket/pingDelay/\(interval)")!
}

// MARK: - Result type

enum PingResult: Sendable {
    /// sendPing called the callback with the given error (nil = success).
    case callback(Error?)
    /// sendPing never called the callback within the deadline.
    case noCallback(deadline: TimeInterval)
}

// MARK: - Measurement

/// Connect to pingDelay/:interval, wait for the upgrade, call sendPing, and
/// return (elapsed, PingResult).  If sendPing never fires, the measurement
/// resolves after `interval + 10` seconds and reports noCallback.
func measure(interval: Int) async -> (TimeInterval, PingResult) {
    let wsTask = URLSession.shared.webSocketTask(with: pingDelayURL(interval))
    wsTask.resume()
    // Let the HTTP → WebSocket upgrade complete before sending the ping.
    try? await Task.sleep(for: .milliseconds(150))

    let deadline = TimeInterval(interval) + 10.0
    let start = Date()
    print("[\(ts())] sendPing called  (post-close server sleep = \(interval)s, deadline = \(Int(deadline))s) …")

    // Race sendPing callback vs. deadline.  A lock-protected box ensures the
    // outer continuation is resumed exactly once regardless of which fires first.
    let result: PingResult = await withCheckedContinuation { outer in
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var resolved = false
        }
        let box = Box()

        @Sendable func resolve(_ r: PingResult) {
            box.lock.lock()
            guard !box.resolved else { box.lock.unlock(); return }
            box.resolved = true
            box.lock.unlock()
            outer.resume(returning: r)
        }

        wsTask.sendPing { error in
            resolve(.callback(error))
        }

        Task {
            try? await Task.sleep(for: .seconds(deadline))
            resolve(.noCallback(deadline: deadline))
        }
    }

    wsTask.cancel()
    let elapsed = Date().timeIntervalSince(start)
    return (elapsed, result)
}

/// Call sendPing on a task that has never been resumed and return
/// (elapsed, PingResult).  A 10s deadline bounds the measurement.
func measureUnresumed() async -> (TimeInterval, PingResult) {
    let wsTask = URLSession.shared.webSocketTask(with: pingDelayURL(0))
    // Intentionally NOT calling wsTask.resume().

    let deadline: TimeInterval = 10.0
    let start = Date()
    print("[\(ts())] sendPing called on un-resumed task  (deadline = \(Int(deadline))s) …")

    let result: PingResult = await withCheckedContinuation { outer in
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var resolved = false
        }
        let box = Box()

        @Sendable func resolve(_ r: PingResult) {
            box.lock.lock()
            guard !box.resolved else { box.lock.unlock(); return }
            box.resolved = true
            box.lock.unlock()
            outer.resume(returning: r)
        }

        wsTask.sendPing { error in
            resolve(.callback(error))
        }

        Task {
            try? await Task.sleep(for: .seconds(deadline))
            resolve(.noCallback(deadline: deadline))
        }
    }

    wsTask.cancel()
    let elapsed = Date().timeIntervalSince(start)
    return (elapsed, result)
}

func report(_ elapsed: TimeInterval, _ result: PingResult, interval: Int) {
    let t = String(format: "%.3f", elapsed)
    switch result {
    case .callback(let err):
        if let err {
            print("[\(ts())] sendPing CALLBACK — error  in \(t)s")
            print("          \(describe(err))")
        } else {
            print("[\(ts())] sendPing CALLBACK — success  in \(t)s")
        }
    case .noCallback(let deadline):
        print("[\(ts())] sendPing NO CALLBACK after \(Int(deadline))s deadline  (elapsed \(t)s)")
    }
}

// MARK: - Scenario A: interval = 0s

section("A — pingDelay/0  (server closes; event loop not blocked)")
let (elapsedA, resultA) = await measure(interval: 0)
report(elapsedA, resultA, interval: 0)

try? await Task.sleep(for: .milliseconds(500))

// MARK: - Scenario B: interval = 1s

section("B — pingDelay/1  (server closes; event loop blocked 1s after close)")
let (elapsedB, resultB) = await measure(interval: 1)
report(elapsedB, resultB, interval: 1)

try? await Task.sleep(for: .milliseconds(500))

// MARK: - Scenario C: interval = 2s

section("C — pingDelay/2  (server closes; event loop blocked 2s after close)")
let (elapsedC, resultC) = await measure(interval: 2)
report(elapsedC, resultC, interval: 2)

try? await Task.sleep(for: .milliseconds(500))

// MARK: - Scenario D: interval = 5s

section("D — pingDelay/5  (server closes; event loop blocked 5s after close)")
let (elapsedD, resultD) = await measure(interval: 5)
report(elapsedD, resultD, interval: 5)

print("\n" + String(repeating: "═", count: 70))
print("Done.")
print(String(repeating: "═", count: 70))

// MARK: - Scenario E: sendPing before resume

section("E — sendPing on un-resumed task  (resume never called)")
let (elapsedE, resultE) = await measureUnresumed()
report(elapsedE, resultE, interval: 0)

print("\n" + String(repeating: "═", count: 70))
print("Done.")
print(String(repeating: "═", count: 70))
