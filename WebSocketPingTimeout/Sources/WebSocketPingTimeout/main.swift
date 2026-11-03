import Foundation

// MARK: - Experiment (Round 2)
//
// Round 1 established: no URLSession/URLRequest timeout setting affects
// URLSessionWebSocketTask.sendPing.  sendPing always waits the full server
// delay regardless of timeoutIntervalForRequest, timeoutIntervalForResource,
// or URLRequest.timeoutInterval.
//
// Round 2 question: Is there *any* built-in absolute timeout on sendPing?
// We escalate the server delay in steps toward the 120s maximum, using only
// URLSession.shared (defaults), to see whether sendPing ever times out on
// its own before the server finally responds.
//
// Server endpoint: ws://127.0.0.1:8080/websocket/pingTimeout/:interval
//   Blocks the NIO event-loop thread for :interval seconds (so no pong is
//   sent during that window), then calls socket.close() + auto-pong.
//
// Scenarios (all URLSession.shared, escalating delay)
//   A  interval =  10s  ← repeat of prior baseline to confirm env is stable
//   B  interval =  30s
//   C  interval =  60s
//   D  interval =  90s
//   E  interval = 120s  ← maximum; does sendPing give up before this?
//
// If sendPing has a hidden timeout T we expect one scenario to fail *before*
// its configured delay and all shorter scenarios to succeed at their delay.

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

func pingTimeoutURL(_ interval: Int) -> URL {
    URL(string: "ws://127.0.0.1:8080/websocket/pingTimeout/\(interval)")!
}

// MARK: - Measurement

/// Connect to pingTimeout/:interval with the given session, wait for the
/// WebSocket handshake, call sendPing, and return (elapsed, error).
/// The timer starts *after* the handshake pause so it reflects only the
/// ping/pong round-trip time.
func measure(session: URLSession, interval: Int) async -> (TimeInterval, Error?) {
    let task = session.webSocketTask(with: pingTimeoutURL(interval))
    task.resume()
    // Let the HTTP → WebSocket upgrade complete before sending the ping.
    try? await Task.sleep(for: .milliseconds(150))

    let start = Date()
    print("[\(ts())] sendPing called  (server delay = \(interval)s) …")

    let pingError = await withCheckedContinuation { (cont: CheckedContinuation<Error?, Never>) in
        task.sendPing { cont.resume(returning: $0) }
    }

    let elapsed = Date().timeIntervalSince(start)
    task.cancel()
    return (elapsed, pingError)
}

func report(_ elapsed: TimeInterval, _ err: Error?, serverInterval: Int) {
    let t = String(format: "%.2f", elapsed)
    if let err {
        // Allow 1s of slop when deciding whether a timeout fired before the
        // server responded.
        let firedEarly = elapsed < Double(serverInterval) - 1.0
        let tag = firedEarly
            ? "⚠️  EARLY — timeout fired before server responded"
            : "✓  at server delay (no early timeout)"
        print("[\(ts())] sendPing FAILED   in \(t)s   \(tag)")
        print("          \(describe(err))")
    } else {
        print("[\(ts())] sendPing SUCCEEDED in \(t)s")
    }
}

// MARK: - Scenario A: 10s delay (stable-env confirmation)

section("A — URLSession.shared, server delay = 10s  (env check)")
print("  Expect: succeeds at ~10s (consistent with Round 1 results).")

let (elapsedA, errorA) = await measure(session: .shared, interval: 10)
report(elapsedA, errorA, serverInterval: 10)

try? await Task.sleep(for: .milliseconds(500))

// MARK: - Scenario B: 30s delay

section("B — URLSession.shared, server delay = 30s")
print("  Does sendPing wait the full 30s?")

let (elapsedB, errorB) = await measure(session: .shared, interval: 30)
report(elapsedB, errorB, serverInterval: 30)

try? await Task.sleep(for: .milliseconds(500))

// MARK: - Scenario C: 60s delay

section("C — URLSession.shared, server delay = 60s")
print("  Does sendPing wait the full 60s?")

let (elapsedC, errorC) = await measure(session: .shared, interval: 60)
report(elapsedC, errorC, serverInterval: 60)

try? await Task.sleep(for: .milliseconds(500))

// MARK: - Scenario D: 90s delay

section("D — URLSession.shared, server delay = 90s")
print("  Does sendPing wait the full 90s?")

let (elapsedD, errorD) = await measure(session: .shared, interval: 90)
report(elapsedD, errorD, serverInterval: 90)

try? await Task.sleep(for: .milliseconds(500))

// MARK: - Scenario E: 120s delay (maximum)

section("E — URLSession.shared, server delay = 120s  (maximum)")
print("  If there is NO built-in timeout sendPing should wait the full 120s.")
print("  Any earlier callback reveals the hidden timeout value.")

let (elapsedE, errorE) = await measure(session: .shared, interval: 120)
report(elapsedE, errorE, serverInterval: 120)

print("\n" + String(repeating: "═", count: 70))
print("Done.")
print(String(repeating: "═", count: 70))
