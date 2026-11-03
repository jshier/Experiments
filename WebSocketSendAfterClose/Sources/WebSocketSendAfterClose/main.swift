import Foundation

// MARK: - Experiment
//
// Question: What happens when URLSessionWebSocketTask.send() is called after the
// connection is closed — either by the server or by the task itself?
//
// Does send() throw immediately with a descriptive error, hang indefinitely, or
// silently succeed? Does the closure-based API behave identically to async/await?
// Do URLSessionTaskDelegate / URLSessionWebSocketTaskDelegate receive the same
// failures, and in what order relative to the send() result?
//
// Scenario A — Server closes (async/await):
//   Connect to /websocket, which sends one message and then closes with a normal
//   closure. Drain receive() until it throws (confirming the close has been
//   observed by URLSession), then call send().
//
// Scenario B — Task closes (async/await):
//   Connect to /websocket/echo (stays open indefinitely). Call
//   cancel(with: .normalClosure), wait briefly for the close to propagate, then
//   call send().
//
// Scenario C — Server closes (closure):
//   Identical setup to A, but using the completion-handler overloads of both
//   receive() and send() throughout.
//
// Scenario D — Task closes (closure):
//   Identical setup to B, but using the completion-handler overload of send().
//
// Scenario E — Server closes (delegate):
//   Identical setup to A, with a URLSessionTaskDelegate +
//   URLSessionWebSocketDelegate attached. Logs every delegate callback with
//   its timestamp to reveal ordering relative to the send() failure.
//
// Scenario F — Task closes (delegate):
//   Identical setup to B, with the same delegate attached.

// MARK: - Helpers

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

/// Drain async receive() until it throws. Returns the number of messages received.
@discardableResult
func drainUntilClosed(_ task: URLSessionWebSocketTask) async -> Int {
    var count = 0
    while true {
        do {
            _ = try await task.receive()
            count += 1
        } catch {
            print("[\(ts())] receive() threw (connection closed): \(describe(error))")
            return count
        }
    }
}

/// Drain closure-based receive() until the completion handler delivers an error.
/// Returns the number of messages received.
@discardableResult
func drainUntilClosedClosure(_ task: URLSessionWebSocketTask) async -> Int {
    var count = 0
    while true {
        let result = await withCheckedContinuation { continuation in
            task.receive { continuation.resume(returning: $0) }
        }
        switch result {
        case .success:
            count += 1
        case .failure(let error):
            print("[\(ts())] receive(completionHandler:) delivered error (connection closed): \(describe(error))")
            return count
        }
    }
}

/// Call the closure-based send() and await its completion handler.
func sendClosure(_ task: URLSessionWebSocketTask, _ message: URLSessionWebSocketTask.Message) async -> Error? {
    await withCheckedContinuation { continuation in
        task.send(message) { continuation.resume(returning: $0) }
    }
}

// MARK: - Delegate infrastructure

/// Thread-safe, timestamped event log for delegate callbacks.
actor EventLog {
    private(set) var entries: [String] = []

    func record(_ event: String) {
        let line = "  [delegate \(ts())] \(event)"
        entries.append(line)
        print(line)
    }
}

/// Logs every URLSessionTaskDelegate and URLSessionWebSocketDelegate callback.
final class WebSocketDelegate: NSObject, URLSessionTaskDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    let log: EventLog

    init(log: EventLog) { self.log = log }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        let proto = `protocol` ?? "nil"
        Task { await log.record("didOpenWithProtocol(\(proto))") }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
        Task { await log.record("didCloseWith(code: \(closeCode.rawValue), reason: \(reasonStr))") }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let errorStr = error.map { describe($0) } ?? "nil (success)"
        Task { await log.record("didCompleteWithError(\(errorStr))") }
    }
}

/// Build a fresh URLSession backed by a logging delegate.
func makeSession(log: EventLog) -> URLSession {
    let delegate = WebSocketDelegate(log: log)
    return URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
}

// MARK: - Scenario A: server closes the connection

section("Scenario A: send() after server close")
print("""
  Server: ws://127.0.0.1:8080/websocket
  → Sends one message and immediately closes with normal closure.
  Client: drain receive() until it throws, then call send().
""")

let taskA = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8080/websocket")!)
taskA.resume()

let receivedA = await drainUntilClosed(taskA)
print("[\(ts())] Drained \(receivedA) message(s). Connection is closed.")

print("[\(ts())] Calling send() on the closed task…")
do {
    try await taskA.send(.string("hello after server close"))
    print("[\(ts())] → send() returned WITHOUT error  ⚠️")
} catch {
    print("[\(ts())] → send() threw: \(describe(error))")
}

// MARK: - Scenario B: task closes the connection

section("Scenario B: send() after task cancel")
print("""
  Server: ws://127.0.0.1:8080/websocket/echo
  → Stays open; echoes anything sent.
  Client: connect, cancel(with: .normalClosure), wait 200 ms, then call send().
""")

let taskB = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8080/websocket/echo")!)
taskB.resume()
try await Task.sleep(for: .milliseconds(100)) // let the handshake complete

taskB.cancel(with: .normalClosure, reason: nil)
print("[\(ts())] cancel() called.")

try await Task.sleep(for: .milliseconds(200)) // let the close propagate

print("[\(ts())] Calling send() on the cancelled task…")
do {
    try await taskB.send(.string("hello after task cancel"))
    print("[\(ts())] → send() returned WITHOUT error  ⚠️")
} catch {
    print("[\(ts())] → send() threw: \(describe(error))")
}

// MARK: - Scenario C: server closes the connection (closure API)

section("Scenario C: send(completionHandler:) after server close")
print("""
  Server: ws://127.0.0.1:8080/websocket
  → Sends one message and immediately closes with normal closure.
  Client: drain receive(completionHandler:) until it errors, then call
          send(completionHandler:).
""")

let taskC = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8080/websocket")!)
taskC.resume()

let receivedC = await drainUntilClosedClosure(taskC)
print("[\(ts())] Drained \(receivedC) message(s). Connection is closed.")

print("[\(ts())] Calling send(completionHandler:) on the closed task…")
if let error = await sendClosure(taskC, .string("hello after server close")) {
    print("[\(ts())] → completionHandler received error: \(describe(error))")
} else {
    print("[\(ts())] → completionHandler called with nil error (no error)  ⚠️")
}

// MARK: - Scenario D: task closes the connection (closure API)

section("Scenario D: send(completionHandler:) after task cancel")
print("""
  Server: ws://127.0.0.1:8080/websocket/echo
  → Stays open; echoes anything sent.
  Client: connect, cancel(with: .normalClosure), wait 200 ms, then call
          send(completionHandler:).
""")

let taskD = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8080/websocket/echo")!)
taskD.resume()
try await Task.sleep(for: .milliseconds(100)) // let the handshake complete

taskD.cancel(with: .normalClosure, reason: nil)
print("[\(ts())] cancel() called.")

try await Task.sleep(for: .milliseconds(200)) // let the close propagate

print("[\(ts())] Calling send(completionHandler:) on the cancelled task…")
if let error = await sendClosure(taskD, .string("hello after task cancel")) {
    print("[\(ts())] → completionHandler received error: \(describe(error))")
} else {
    print("[\(ts())] → completionHandler called with nil error (no error)  ⚠️")
}

// MARK: - Scenario E: server closes the connection (delegate)

section("Scenario E: send() after server close — with delegate")
print("""
  Server: ws://127.0.0.1:8080/websocket
  → Sends one message and immediately closes with normal closure.
  Client: drain receive() until it throws, call send(), then wait for any
          remaining delegate callbacks to arrive.
  Delegate: URLSessionTaskDelegate + URLSessionWebSocketDelegate — logs
            didOpenWithProtocol, didCloseWith, and didCompleteWithError.
""")

let logE = EventLog()
let sessionE = makeSession(log: logE)
let taskE = sessionE.webSocketTask(with: URL(string: "ws://127.0.0.1:8080/websocket")!)
taskE.resume()

let receivedE = await drainUntilClosed(taskE)
print("[\(ts())] Drained \(receivedE) message(s). Connection is closed.")

print("[\(ts())] Calling send() on the closed task…")
do {
    try await taskE.send(.string("hello after server close"))
    print("[\(ts())] → send() returned WITHOUT error  ⚠️")
} catch {
    print("[\(ts())] → send() threw: \(describe(error))")
}

try await Task.sleep(for: .milliseconds(300)) // let any async delegate callbacks arrive
print("[\(ts())] Done waiting for delegate callbacks.")

// MARK: - Scenario F: task closes the connection (delegate)

section("Scenario F: send() after task cancel — with delegate")
print("""
  Server: ws://127.0.0.1:8080/websocket/echo
  → Stays open; echoes anything sent.
  Client: connect, cancel(with: .normalClosure), wait 200 ms, call send(), then
          wait for any remaining delegate callbacks to arrive.
  Delegate: URLSessionTaskDelegate + URLSessionWebSocketDelegate — logs
            didOpenWithProtocol, didCloseWith, and didCompleteWithError.
""")

let logF = EventLog()
let sessionF = makeSession(log: logF)
let taskF = sessionF.webSocketTask(with: URL(string: "ws://127.0.0.1:8080/websocket/echo")!)
taskF.resume()
try await Task.sleep(for: .milliseconds(100)) // let the handshake complete

taskF.cancel(with: .normalClosure, reason: nil)
print("[\(ts())] cancel() called.")

try await Task.sleep(for: .milliseconds(200)) // let the close propagate

print("[\(ts())] Calling send() on the cancelled task…")
do {
    try await taskF.send(.string("hello after task cancel"))
    print("[\(ts())] → send() returned WITHOUT error  ⚠️")
} catch {
    print("[\(ts())] → send() threw: \(describe(error))")
}

try await Task.sleep(for: .milliseconds(300)) // let any async delegate callbacks arrive
print("[\(ts())] Done waiting for delegate callbacks.")
