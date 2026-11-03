import Alamofire
import Foundation

// MARK: - Experiment
//
// Question: How many WebSocket echo round-trips per second can URLSessionWebSocketTask
// and Alamofire sustain against Firewalk's /websocket/echo endpoint?
//
// Setup: Connect to the echo endpoint, send a message, and immediately send each reply
// straight back. Count completed round-trips over 5 seconds, then report the rate.

let testDuration = 5.0
let url = URL(string: "ws://127.0.0.1:8080/websocket/echo")!
let binaryPayload = Data(repeating: 0x42, count: 64)

print("""
Experiment: WebSocket echo round-trip rate
==========================================
Server:   \(url)
Payload:  64 bytes binary
Duration: \(Int(testDuration)) seconds per run

""")

try await Task.detached(priority: .userInitiated) {

// MARK: - URLSession

print("── URLSession ──────────────────────────────────────")

let urlTask = URLSession.shared.webSocketTask(with: url)
urlTask.resume()

let urlMessage = URLSessionWebSocketTask.Message.data(binaryPayload)
try await urlTask.send(urlMessage)

var urlCount = 0
let urlStart = Date.now

repeat {
    _ = try await urlTask.receive()
    urlCount += 1

    let elapsed = Date.now.timeIntervalSince(urlStart)
    if elapsed >= testDuration { break }

    try await urlTask.send(urlMessage)
} while true

let urlElapsed = Date.now.timeIntervalSince(urlStart)
urlTask.cancel(with: .normalClosure, reason: nil)
let urlRate = Double(urlCount) / urlElapsed

print("""
Round-trips:  \(urlCount)
Elapsed:      \(String(format: "%.3f", urlElapsed)) s
Rate:         \(String(format: "%.1f", urlRate)) msg/s

""")

// MARK: - Alamofire

print("── Alamofire ───────────────────────────────────────")

let socket = AF.webSocketRequest(to: url)
let messages = socket.streamingMessages()

// Kick off the ping-pong. send() awaits until the message is handed off to the socket.
_ = await socket.send(binaryPayload)

var afCount = 0
let afStart = Date.now

for await _ in messages {
    afCount += 1

    let elapsed = Date.now.timeIntervalSince(afStart)
    if elapsed >= testDuration { break }

    _ = await socket.send(binaryPayload)
}

let afElapsed = Date.now.timeIntervalSince(afStart)
let afRate = Double(afCount) / afElapsed

print("""
Round-trips:  \(afCount)
Elapsed:      \(String(format: "%.3f", afElapsed)) s
Rate:         \(String(format: "%.1f", afRate)) msg/s

""")

// MARK: - Summary

print("""
── Summary ─────────────────────────────────────────
URLSession:  \(String(format: "%.1f", urlRate)) msg/s
Alamofire:   \(String(format: "%.1f", afRate)) msg/s
""")

}.value
