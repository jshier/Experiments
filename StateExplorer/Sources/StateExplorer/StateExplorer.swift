import Foundation

// MARK: - State name

extension URLSessionTask.State {
    var name: String {
        switch self {
        case .suspended: return "suspended"
        case .running:   return "running"
        case .canceling: return "canceling"
        case .completed: return "completed"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}

// MARK: - Value types (Sendable by synthesis)

struct Transition: Hashable, Sendable {
    let from: URLSessionTask.State
    let to: URLSessionTask.State
    var description: String { "\(from.name) → \(to.name)" }
}

struct ScenarioResult: Sendable {
    let name: String
    let taskType: String
    let transitions: [Transition]
    let timedOut: Bool

    /// Full state chain as a readable string, e.g. "suspended → running → completed".
    /// Chains longer than 9 states are truncated with a count to keep output readable.
    var stateChain: String {
        guard !transitions.isEmpty else { return "suspended (no transitions observed)" }
        var names = [transitions[0].from.name]
        for t in transitions { names.append(t.to.name) }
        guard names.count > 9 else { return names.joined(separator: " → ") }
        let head = names.prefix(3).joined(separator: " → ")
        let tail = names.suffix(2).joined(separator: " → ")
        return "\(head) → … \(transitions.count) transitions … → \(tail)"
    }
}

// MARK: - Once
// Guarantees a closure is executed at most once across concurrent callers.

final class Once: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()

    func fire(_ f: () -> Void) {
        lock.lock(); let go = !fired; fired = true; lock.unlock()
        if go { f() }
    }
}

// MARK: - TransitionRecorder
// Uses old-style NSObject KVO (addObserver:forKeyPath:) and reads task.state
// directly in the callback, because macOS 26's new Swift Foundation doesn't
// bridge typed old/new values through the modern observe(_:options:) API.

final class TransitionRecorder: NSObject, @unchecked Sendable {
    private var _transitions: [Transition] = []
    private let lock = NSLock()
    private var lastState: URLSessionTask.State
    private let task: URLSessionTask   // strong ref keeps task alive until finalized
    private var unregistered = false   // guards removeObserver — called exactly once

    init(observing task: URLSessionTask) {
        self.task = task
        self.lastState = task.state
        super.init()
        task.addObserver(self, forKeyPath: #keyPath(URLSessionTask.state),
                         options: [.new], context: nil)
    }

    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard keyPath == #keyPath(URLSessionTask.state) else { return }
        // Prefer the change-dict value: it captures the state atomically at the
        // moment KVO fires, which matters for transient states like .canceling that
        // may have already advanced by the time we read task.state directly.
        let newState: URLSessionTask.State
        if let raw = change?[.newKey] as? Int,
           let s = URLSessionTask.State(rawValue: raw) {
            newState = s
        } else {
            newState = task.state  // fallback for macOS versions that drop the dict value
        }
        lock.lock()
        let prev = lastState
        if newState != prev {
            lastState = newState
            _transitions.append(Transition(from: prev, to: newState))
        }
        lock.unlock()
    }

    /// Deregisters KVO and returns the recorded transitions. Safe to call from any thread.
    func finalize() -> [Transition] {
        removeObserverOnce()
        lock.lock()
        defer { lock.unlock() }
        return _transitions
    }

    private func removeObserverOnce() {
        lock.lock()
        let shouldRemove = !unregistered
        unregistered = true
        lock.unlock()
        if shouldRemove {
            task.removeObserver(self, forKeyPath: #keyPath(URLSessionTask.state))
        }
    }

    deinit { removeObserverOnce() }
}

// MARK: - SessionDelegate
// Uses urlSession(_:task:didCompleteWithError:) as the universal "task is done"
// signal for all task types — data, upload, download, and WebSocket.

final class SessionDelegate: NSObject, @unchecked Sendable,
                             URLSessionTaskDelegate,
                             URLSessionDataDelegate,
                             URLSessionDownloadDelegate {

    private var completionHandlers: [Int: @Sendable () -> Void] = [:]
    private let lock = NSLock()

    func onComplete(for task: URLSessionTask, _ handler: @escaping @Sendable () -> Void) {
        lock.lock(); completionHandlers[task.taskIdentifier] = handler; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let h = completionHandlers.removeValue(forKey: task.taskIdentifier); lock.unlock()
        h?()
    }

    // Discard received bytes — we only care about state transitions, not data.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {}

    // Required for download tasks; discard the temporary file.
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

// MARK: - Globals

let sessionDelegate = SessionDelegate()
let sessionConfig: URLSessionConfiguration = {
    let c = URLSessionConfiguration.default
    // One round runs 14 concurrent tasks. The default limit of 6 connections per host
    // would queue tasks 7-14, causing their timing-sensitive cancel/suspend delays to
    // fire before the task is running. 20 gives each round's tasks room to proceed.
    c.httpMaximumConnectionsPerHost = 20
    return c
}()
let session = URLSession(configuration: sessionConfig, delegate: sessionDelegate, delegateQueue: nil)

let base   = "http://127.0.0.1:8080"
let wsBase = "ws://127.0.0.1:8080"

// MARK: - Core scenario runner
//
// `setup`   — creates and returns a task (do NOT call resume here).
// `actions` — called immediately after KVO+delegate are wired up; call
//             resume here and schedule any delays (cancel/suspend/etc.).
//
// The function returns once the task's delegate fires didCompleteWithError,
// or after `timeout` elapses (whichever comes first).

func runScenario(
    name: String,
    taskType: String,
    timeout: Duration = .seconds(5),
    setup: @escaping @Sendable (URLSession) -> URLSessionTask,
    actions: @escaping @Sendable (URLSessionTask) -> Void
) async -> ScenarioResult {
    await withCheckedContinuation { continuation in
        let task     = setup(session)
        let recorder = TransitionRecorder(observing: task)
        let once     = Once()

        // `done` is the single point of truth for completing this scenario.
        let done: @Sendable (Bool) -> Void = { timedOut in
            once.fire {
                continuation.resume(returning: ScenarioResult(
                    name: name, taskType: taskType,
                    transitions: recorder.finalize(), timedOut: timedOut
                ))
            }
        }

        sessionDelegate.onComplete(for: task) { done(false) }
        Task { try? await Task.sleep(for: timeout); done(true) }

        actions(task)
    }
}

// MARK: - Entry point

@main
struct StateExplorer {
    static let runCount = 100

    static func main() async {
        let results = await collectResults()
        printSummary(results)
    }

    /// Run `runCount` sequential rounds, each round running all 14 scenarios concurrently.
    /// Completing a round before starting the next ensures timing-sensitive actions
    /// (suspend/cancel delays) fire while their task is actually running, not queued.
    static func collectResults() async -> [ScenarioResult] {
        var results: [ScenarioResult] = []
        results.reserveCapacity(runCount * 14)
        for _ in 0..<runCount {
            let round = await withTaskGroup(of: ScenarioResult.self) { group in
                addBatch(&group)
                var r: [ScenarioResult] = []
                for await result in group { r.append(result) }
                return r
            }
            results.append(contentsOf: round)
        }
        return results
    }

    /// Enqueue one complete batch of 14 scenario tasks into the group.
    static func addBatch(_ group: inout TaskGroup<ScenarioResult>) {

        // ── DataTask ─────────────────────────────────────────────────────

        // Intended: suspended → running → completed
        group.addTask {
            await runScenario(name: "Normal completion", taskType: "DataTask",
                setup: { $0.dataTask(with: URL(string: "\(base)/bytes/1000")!) },
                actions: { $0.resume() })
        }

        // Intended: suspended → running → canceling → completed
        group.addTask {
            await runScenario(name: "Cancel while running", taskType: "DataTask",
                setup: { $0.dataTask(with: URL(string: "\(base)/infinite")!) },
                actions: { task in
                    task.resume()
                    Task { try? await Task.sleep(for: .milliseconds(50)); task.cancel() }
                })
        }

        // Intended: suspended → canceling → completed
        group.addTask {
            await runScenario(name: "Cancel before resume", taskType: "DataTask",
                setup: { $0.dataTask(with: URL(string: "\(base)/bytes/1000")!) },
                actions: { $0.cancel() })
        }

        // Intended: suspended → running → suspended → running → completed
        // /chunked/50 sends 50 individual bytes at 20 ms intervals (~1 s total),
        // giving generous windows to observe suspend and resume before completion.
        group.addTask {
            await runScenario(name: "Suspend then resume", taskType: "DataTask",
                timeout: .seconds(5),
                setup: { $0.dataTask(with: URL(string: "\(base)/chunked/50")!) },
                actions: { task in
                    task.resume()
                    Task {
                        try? await Task.sleep(for: .milliseconds(200)); task.suspend()
                        try? await Task.sleep(for: .milliseconds(200)); task.resume()
                    }
                })
        }

        // Intended: suspended → running → suspended → canceling → completed
        // /chunked/100 sends data at 20 ms/byte — slow enough to suspend cleanly
        // without triggering download task's internal rapid-write state cycling.
        group.addTask {
            await runScenario(name: "Cancel after suspend", taskType: "DataTask",
                setup: { $0.dataTask(with: URL(string: "\(base)/chunked/100")!) },
                actions: { task in
                    task.resume()
                    Task {
                        try? await Task.sleep(for: .milliseconds(100)); task.suspend()
                        try? await Task.sleep(for: .milliseconds(100)); task.cancel()
                    }
                })
        }

        // ── UploadTask ────────────────────────────────────────────────────

        // Intended: suspended → running → completed
        group.addTask {
            await runScenario(name: "Normal completion", taskType: "UploadTask",
                setup: {
                    var req = URLRequest(url: URL(string: "\(base)/upload")!)
                    req.httpMethod = "POST"
                    return $0.uploadTask(with: req, from: Data(repeating: 0x41, count: 10_000))
                },
                actions: { $0.resume() })
        }

        // Intended: suspended → running → canceling → completed
        // Cancel synchronously after resume to ensure the cancel races the HTTP
        // response rather than completing after a concurrent upload's buffering.
        group.addTask {
            await runScenario(name: "Cancel while running", taskType: "UploadTask",
                setup: {
                    var req = URLRequest(url: URL(string: "\(base)/upload")!)
                    req.httpMethod = "POST"
                    return $0.uploadTask(with: req, from: Data(repeating: 0x41, count: 5_000_000))
                },
                actions: { task in
                    task.resume()
                    task.cancel()   // synchronous: fires before the HTTP response returns
                })
        }

        // Intended: suspended → running → suspended → canceling → completed
        group.addTask {
            await runScenario(name: "Cancel after suspend", taskType: "UploadTask",
                setup: {
                    var req = URLRequest(url: URL(string: "\(base)/upload")!)
                    req.httpMethod = "POST"
                    return $0.uploadTask(with: req, from: Data(repeating: 0x41, count: 5_000_000))
                },
                actions: { task in
                    task.resume()
                    Task {
                        try? await Task.sleep(for: .milliseconds(20)); task.suspend()
                        try? await Task.sleep(for: .milliseconds(50)); task.cancel()
                    }
                })
        }

        // ── DownloadTask ──────────────────────────────────────────────────

        // Intended: suspended → running → completed
        group.addTask {
            await runScenario(name: "Normal completion", taskType: "DownloadTask",
                setup: { $0.downloadTask(with: URL(string: "\(base)/download/10000")!) },
                actions: { $0.resume() })
        }

        // Intended: suspended → running → canceling → completed
        group.addTask {
            await runScenario(name: "Cancel while running", taskType: "DownloadTask",
                setup: { $0.downloadTask(with: URL(string: "\(base)/infinite")!) },
                actions: { task in
                    task.resume()
                    Task { try? await Task.sleep(for: .milliseconds(20)); task.cancel() }
                })
        }

        // Intended: suspended → running → suspended → canceling → completed
        // Uses /chunked/100 (20 ms/byte) to avoid the rapid internal suspend/resume
        // cycling that URLSessionDownloadTask exhibits on fast /infinite streams.
        group.addTask {
            await runScenario(name: "Cancel after suspend", taskType: "DownloadTask",
                setup: { $0.downloadTask(with: URL(string: "\(base)/chunked/100")!) },
                actions: { task in
                    task.resume()
                    Task {
                        try? await Task.sleep(for: .milliseconds(100)); task.suspend()
                        try? await Task.sleep(for: .milliseconds(100)); task.cancel()
                    }
                })
        }

        // Intended: suspended → running → suspended → running → completed
        // Same /chunked/50 trick: natural completion after ~1 s, no explicit cancel needed.
        group.addTask {
            await runScenario(name: "Suspend then resume", taskType: "DownloadTask",
                timeout: .seconds(5),
                setup: { $0.downloadTask(with: URL(string: "\(base)/chunked/50")!) },
                actions: { task in
                    task.resume()
                    Task {
                        try? await Task.sleep(for: .milliseconds(200)); task.suspend()
                        try? await Task.sleep(for: .milliseconds(200)); task.resume()
                    }
                })
        }

        // ── WebSocketTask ─────────────────────────────────────────────────

        // Intended: suspended → running → completed
        // /websocket sends one JSON message then closes the connection.
        // A continuous receive loop keeps a pending receive so the server's
        // close frame is processed promptly and the task transitions to .completed.
        group.addTask {
            await runScenario(name: "Normal close (server-initiated)", taskType: "WebSocketTask",
                setup: { $0.webSocketTask(with: URL(string: "\(wsBase)/websocket")!) },
                actions: { task in
                    task.resume()
                    @Sendable func receiveLoop(_ ws: URLSessionWebSocketTask) {
                        ws.receive { result in
                            if case .success = result { receiveLoop(ws) }
                            // On .failure the connection closed; task will complete naturally.
                        }
                    }
                    if let ws = task as? URLSessionWebSocketTask { receiveLoop(ws) }
                })
        }

        // Intended: suspended → running → canceling → completed
        group.addTask {
            await runScenario(name: "Cancel while running", taskType: "WebSocketTask",
                setup: { $0.webSocketTask(with: URL(string: "\(wsBase)/websocket/echo")!) },
                actions: { task in
                    task.resume()
                    Task {
                        try? await Task.sleep(for: .milliseconds(50))
                        (task as? URLSessionWebSocketTask)?.cancel(with: .goingAway, reason: nil)
                    }
                })
        }
    }
}

// MARK: - Summary printer

func printSummary(_ results: [ScenarioResult]) {
    let thick = String(repeating: "═", count: 62)
    let typeOrder = ["DataTask", "UploadTask", "DownloadTask", "WebSocketTask"]

    // Determine the number of unique scenarios so we can compute runs-per-scenario.
    let scenarioKeys = Set(results.map { "\($0.taskType)/\($0.name)" })
    let scenarioCount = scenarioKeys.count
    let runsEach = results.count / scenarioCount

    let byType = Dictionary(grouping: results, by: \.taskType)
    let cancelingToCompleted = Transition(from: .canceling, to: .completed)

    print("\n\(thick)")
    print("  URLSessionTask State Transition Explorer")
    print("  \(results.count) runs — \(scenarioCount) scenarios × \(runsEach) each")
    print(thick)

    for taskType in typeOrder {
        guard let typeResults = byType[taskType], !typeResults.isEmpty else { continue }

        let scenarioGroups = Dictionary(grouping: typeResults, by: \.name)
        let sortedNames    = scenarioGroups.keys.sorted()
        let totalRuns      = typeResults.count

        print("\n── \(taskType) (\(sortedNames.count) scenarios, \(totalRuns) runs) ──")

        for name in sortedNames {
            let runs = scenarioGroups[name]!
            let n    = runs.count

            // Frequency distribution of observed state chains, most common first.
            let chainFreq = Dictionary(grouping: runs, by: \.stateChain)
                .sorted { $0.value.count != $1.value.count
                    ? $0.value.count > $1.value.count
                    : $0.key < $1.key }

            let timedOutNote = runs.filter(\.timedOut).count > 0
                ? " (\(runs.filter(\.timedOut).count) timed out)" : ""
            print("  \(name)\(timedOutNote)")
            for (chain, chainRuns) in chainFreq {
                print("    \(chainRuns.count)/\(n)  \(chain)")
            }
        }

        // Aggregate transition counts across all runs of this task type.
        var counts: [Transition: Int] = [:]
        for r in typeResults { for t in r.transitions { counts[t, default: 0] += 1 } }
        let sortedTransitions = counts.keys.sorted {
            ($0.from.rawValue, $0.to.rawValue) < ($1.from.rawValue, $1.to.rawValue)
        }

        print()
        print("  Transition counts (\(totalRuns) runs):")
        for t in sortedTransitions {
            let label = t.description.padding(toLength: 32, withPad: " ", startingAt: 0)
            print("    \(label)  ×\(counts[t]!)")
        }

        // For the three concrete task types, check whether any run ever demonstrated
        // a canceling → completed transition. WebSocketTask is intentionally excluded
        // because a server-initiated close naturally produces that path.
        guard taskType != "WebSocketTask" else { continue }

        let evidenceRuns = typeResults.filter { $0.transitions.contains(cancelingToCompleted) }
        print()
        if evidenceRuns.isEmpty {
            print("  canceling → completed  ✓ never observed in \(totalRuns) runs")
        } else {
            print("  canceling → completed  — OBSERVED in \(evidenceRuns.count)/\(totalRuns) runs:")
            for name in sortedNames {
                let allRuns  = scenarioGroups[name]!
                let evRuns   = allRuns.filter { $0.transitions.contains(cancelingToCompleted) }
                guard !evRuns.isEmpty else { continue }
                // Show the most-common chain that includes this transition.
                let topChain = Dictionary(grouping: evRuns, by: \.stateChain)
                    .max { $0.value.count < $1.value.count }!.key
                print("    · \"\(name)\" (\(evRuns.count)/\(allRuns.count))  \(topChain)")
            }
        }
    }

    print("\n\(thick)\n")
}
