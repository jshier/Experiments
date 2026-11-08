import Foundation

// MARK: - Experiment

//
// Question: Does URLSessionWebSocketTask buffer messages that arrive before receive() is called,
// or are they silently dropped?
//
// Setup: Firewalk's /websocket/payloads/:count endpoint sends :count messages immediately upon
// connection and then closes the socket after a 30ms delay. By waiting well past that window
// before calling receive(), we force all server-side sends — and the subsequent close — to
// complete while the client is not yet listening. Whatever receive() returns then reflects
// only what the task chose to buffer internally.

let count = 5
let delayBeforeReceiving = Duration.seconds(2)

print("""
Experiment: URLSessionWebSocketTask message buffering
=====================================================
Server: ws://127.0.0.1:8080/websocket/payloads/\(count)
  → Sends \(count) messages immediately on connect, then closes after 30 ms.

Client delay before calling receive(): \(delayBeforeReceiving)
  → By this point the server will have sent all messages and closed the connection.

If all \(count) messages are received the task buffered them.
If fewer are received (or receive() errors immediately) they were dropped.
""")

let url = URL(string: "ws://127.0.0.1:8080/websocket/payloads/\(count)")!
let task = URLSession.shared.webSocketTask(with: url)
task.resume()

print("[\(timestamp())] Connected — waiting \(delayBeforeReceiving) before receiving…\n")
try await Task.sleep(for: delayBeforeReceiving)
print("[\(timestamp())] Delay complete — calling receive() up to \(count) times.\n")

var received = 0
for i in 1...count {
    do {
        let message = try await task.receive()
        received += 1
        switch message {
        case let .string(text):
            print("  [\(i)] string  \(text.count) chars")
        case let .data(data):
            print("  [\(i)] data    \(data.count) bytes")
        @unknown default:
            print("  [\(i)] unknown message type")
        }
    } catch {
        print("  [\(i)] receive() threw: \(error)\n  (stopping early)")
        break
    }
}

print("""

Result: received \(received) / \(count) messages after a \(delayBeforeReceiving) delay.
\(received == count ? "✅  All messages were buffered — none dropped." : "❌  \(count - received) message(s) were dropped (or the task errored).")
""")

// MARK: - Helpers

func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}
