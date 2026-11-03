import Dispatch
import Foundation
import Synchronization

// MARK: - Helpers

/// Thread-safe event log so each experiment can print what happened, in order.
final class Log: Sendable {
    private let events = Mutex<[String]>([])
    private let start = ContinuousClock.now

    func add(_ event: String) {
        let elapsed = ContinuousClock.now - start
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        events.withLock { $0.append("  [+\(String(ms).leftPad(4))ms] \(event)") }
    }

    func dump() {
        events.withLock { $0.forEach { print($0) } }
    }

    func contains(_ text: String) -> Bool {
        events.withLock { $0.contains { $0.contains(text) } }
    }
}

extension String {
    func leftPad(_ n: Int) -> String { String(repeating: " ", count: max(0, n - count)) + self }
}

/// Reports when it is deallocated, so we can observe when a work item releases its block.
final class Sentinel: Sendable {
    let name: String
    let log: Log
    init(_ name: String, log: Log) { self.name = name; self.log = log }
    deinit { log.add("Sentinel '\(name)' deinit") }
}

func sleepMs(_ ms: Int) { Thread.sleep(forTimeInterval: Double(ms) / 1000) }

func experiment(_ title: String, question: String, _ body: (Log) -> Void) {
    print("\n=== \(title) ===")
    print("Q: \(question)")
    let log = Log()
    body(log)
    log.dump()
}

func makeQueue(_ label: String, concurrent: Bool = false) -> DispatchQueue {
    DispatchQueue(label: "experiment.\(label)", attributes: concurrent ? .concurrent : [])
}

/// Blocks a serial queue until `open()` is called, so subsequently enqueued items stay pending.
final class Gate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func open() { semaphore.signal() }
    func hold(on queue: DispatchQueue, log: Log) {
        let started = DispatchSemaphore(value: 0)
        queue.async { [semaphore] in
            log.add("gate item running (blocking queue)")
            started.signal()
            semaphore.wait()
            log.add("gate item released")
        }
        started.wait()
    }
}

/// Lets a block refer to its own work item without tripping region isolation.
final class ItemBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _item: DispatchWorkItem?
    var item: DispatchWorkItem? { lock.withLock { _item } }
    func set(_ newValue: DispatchWorkItem?) { lock.withLock { _item = newValue } }
}

// MARK: - Experiments

// Declared nonisolated (not top-level code) so the blocks below are not inferred @MainActor,
// which would make libdispatch trap when they run on a background queue.
nonisolated func runAllExperiments() {

experiment("1. Cancel before it starts (pending on queue)",
           question: "Is the block executed if cancel() is called before the queue starts it?") { log in
    let queue = makeQueue("e1")
    let gate = Gate()
    gate.hold(on: queue, log: log)

    let item = DispatchWorkItem { log.add("BLOCK EXECUTED") }
    queue.async(execute: item)
    log.add("item enqueued, isCancelled=\(item.isCancelled)")
    item.cancel()
    log.add("item.cancel() called, isCancelled=\(item.isCancelled)")
    gate.open()
    queue.sync { log.add("queue drained") }
    log.add("block executed? \(log.contains("BLOCK EXECUTED"))")
}

experiment("2. Cancel during execution",
           question: "Does cancel() interrupt a running block? Is isCancelled visible inside?") { log in
    let queue = makeQueue("e2")
    let started = DispatchSemaphore(value: 0)
    let box = ItemBox()

    let item = DispatchWorkItem {
        log.add("block started")
        started.signal()
        for step in 1...5 {
            sleepMs(50)
            let cancelled = box.item!.isCancelled
            log.add("step \(step) done, isCancelled=\(cancelled)")
        }
        log.add("block finished (nothing stopped it)")
    }
    box.set(item)
    queue.async(execute: item)
    started.wait()
    sleepMs(75)
    item.cancel()
    log.add("item.cancel() called from outside")
    item.wait()
    log.add("item.wait() returned")
    box.set(nil)
}

experiment("3. Cancel after completion",
           question: "What does cancel() do once the block has finished?") { log in
    let queue = makeQueue("e3")
    let item = DispatchWorkItem { log.add("block ran") }
    queue.async(execute: item)
    item.wait()
    log.add("finished, isCancelled=\(item.isCancelled)")
    item.cancel()
    log.add("after cancel(), isCancelled=\(item.isCancelled)")
}

experiment("4. Drop all references while pending",
           question: "If the caller releases the work item before it runs, does it still run?") { log in
    let queue = makeQueue("e4")
    let gate = Gate()
    gate.hold(on: queue, log: log)
    do {
        let sentinel = Sentinel("e4", log: log)
        let item = DispatchWorkItem {
            log.add("block ran, sentinel=\(sentinel.name)")
        }
        queue.async(execute: item)
        log.add("item enqueued; leaving scope (dropping our only reference)")
    }
    sleepMs(100)
    log.add("gate still closed; a Sentinel deinit above would mean the block was discarded")
    gate.open()
    queue.sync { log.add("queue drained") }
}

experiment("5. Weak reference to pending item",
           question: "Does the queue retain the DispatchWorkItem object itself, or only its block?") { log in
    let queue = makeQueue("e5")
    let gate = Gate()
    gate.hold(on: queue, log: log)
    nonisolated(unsafe) weak var weakItem: DispatchWorkItem?
    do {
        let item = DispatchWorkItem { log.add("block ran") }
        weakItem = item
        queue.async(execute: item)
    }
    log.add("after scope exit, weakItem is \(weakItem == nil ? "nil (item deallocated; queue kept only the block)" : "non-nil (queue retains the item)")")
    gate.open()
    queue.sync { log.add("queue drained") }
    sleepMs(50)
    log.add("after run, weakItem is \(weakItem == nil ? "nil (deallocated)" : "non-nil")")
}

experiment("6. Block lifetime: run vs cancelled-before-run",
           question: "When is the captured block released: after running? after cancel? only when item dies?") { log in
    let queue = makeQueue("e6")
    let gate = Gate()
    gate.hold(on: queue, log: log)

    var ran: DispatchWorkItem? = {
        let s = Sentinel("ran", log: log)
        return DispatchWorkItem { log.add("'ran' block executing with \(s.name)") }
    }()
    var cancelled: DispatchWorkItem? = {
        let s = Sentinel("cancelled", log: log)
        return DispatchWorkItem { log.add("'cancelled' block executing with \(s.name)") }
    }()
    queue.async(execute: ran!)
    queue.async(execute: cancelled!)
    cancelled!.cancel()
    log.add("'cancelled' item cancel()'d; we still hold both items")
    gate.open()
    queue.sync { log.add("queue drained") }
    sleepMs(50)
    log.add("-- still holding both references; a Sentinel deinit above means the block was released early --")
    ran = nil
    log.add("released our reference to 'ran'")
    cancelled = nil
    log.add("released our reference to 'cancelled'")
}

experiment("7. perform() on a cancelled item",
           question: "Does calling perform() manually run a cancelled item?") { log in
    let item = DispatchWorkItem { log.add("BLOCK EXECUTED") }
    item.cancel()
    item.perform()
    log.add("perform() on cancelled item returned; executed? \(log.contains("BLOCK EXECUTED"))")
}

experiment("8. Running one item multiple times",
           question: "Can an item run more than once (perform twice, enqueue twice)?") { log in
    let counter = Mutex(0)
    let item = DispatchWorkItem { log.add("block run #\(counter.withLock { $0 += 1; return $0 })") }
    item.perform()
    item.perform()
    log.add("after two perform() calls")
    let queue = makeQueue("e8")
    queue.async(execute: item)
    queue.async(execute: item)
    queue.sync {}
    log.add("after two async enqueues; total runs = \(counter.withLock { $0 })")
}

experiment("9. Enqueue after cancel",
           question: "After cancel(), is the item permanently dead? Does enqueueing it later run it?") { log in
    let queue = makeQueue("e9")
    let item = DispatchWorkItem { log.add("BLOCK EXECUTED") }
    item.cancel()
    queue.async(execute: item)
    queue.sync {}
    log.add("enqueued after cancel; executed? \(log.contains("BLOCK EXECUTED")), isCancelled=\(item.isCancelled)")
}

experiment("10. wait() on a cancelled-before-run item",
           question: "Does wait() return, or hang, if the item is cancelled and the block is skipped?") { log in
    let queue = makeQueue("e10")
    let gate = Gate()
    gate.hold(on: queue, log: log)
    let item = DispatchWorkItem { log.add("BLOCK EXECUTED") }
    queue.async(execute: item)
    item.cancel()
    let first = item.wait(timeout: .now() + .milliseconds(300))
    log.add("wait(300ms) while queue still blocked -> \(first)")
    gate.open()
    let second = item.wait(timeout: .now() + .seconds(2))
    log.add("wait(2s) after queue reaches it -> \(second)")
    log.add("executed? \(log.contains("BLOCK EXECUTED"))")
}

experiment("11. notify() on cancelled-before-run item",
           question: "Does the notify block fire for an item that was cancelled and skipped?") { log in
    let queue = makeQueue("e11")
    let gate = Gate()
    gate.hold(on: queue, log: log)
    let item = DispatchWorkItem { log.add("BLOCK EXECUTED") }
    item.notify(queue: .global()) { log.add("notify fired") }
    queue.async(execute: item)
    item.cancel()
    gate.open()
    sleepMs(300)
    log.add("executed? \(log.contains("BLOCK EXECUTED")), notify fired? \(log.contains("notify fired"))")
}

experiment("12. notify() when cancelled mid-run",
           question: "Does notify fire after a block that was cancelled mid-execution returns?") { log in
    let queue = makeQueue("e12")
    let started = DispatchSemaphore(value: 0)
    let item = DispatchWorkItem {
        started.signal()
        sleepMs(150)
        log.add("block body finished")
    }
    item.notify(queue: .global()) { log.add("notify fired") }
    queue.async(execute: item)
    started.wait()
    item.cancel()
    log.add("cancelled while running")
    sleepMs(300)
}

experiment("13. Self-cancellation",
           question: "Can a block cancel its own item, and does execution continue?") { log in
    let queue = makeQueue("e13")
    let box = ItemBox()
    let item = DispatchWorkItem {
        box.item!.cancel()
        log.add("cancelled self; isCancelled=\(box.item!.isCancelled); continuing")
    }
    box.set(item)
    queue.async(execute: item)
    item.wait()
    box.set(nil)
    log.add("wait returned")
}

experiment("14. Retain cycle via captured item",
           question: "If the block captures its own item strongly, is the cycle broken after running?") { log in
    let queue = makeQueue("e14")
    nonisolated(unsafe) weak var weakItem: DispatchWorkItem?
    do {
        let sentinel = Sentinel("cycle", log: log)
        let box = ItemBox()
        let item = DispatchWorkItem {
            _ = sentinel
            _ = box.item
            log.add("block ran")
        }
        box.set(item)
        weakItem = item
        queue.async(execute: item)
        item.wait()
    }
    sleepMs(100)
    log.add("after run + scope exit, weakItem is \(weakItem == nil ? "nil (cycle broken)" : "non-nil (cycle leaked)")")
}

experiment("15. Dropping an item that is never enqueued",
           question: "Does a never-submitted item release its block on dealloc (no crash, no run)?") { log in
    do {
        let s = Sentinel("never-enqueued", log: log)
        let item = DispatchWorkItem { log.add("BLOCK EXECUTED \(s.name)") }
        _ = item
    }
    log.add("scope exited; executed? \(log.contains("BLOCK EXECUTED"))")
}

experiment("16. Concurrent queue, cancel half",
           question: "On a concurrent queue, which of 20 items run if the odd ones are cancelled before submission?") { log in
    let queue = makeQueue("e16", concurrent: true)
    let ran = Mutex(Set<Int>())
    let group = DispatchGroup()
    var items: [DispatchWorkItem] = []
    for i in 0..<20 {
        items.append(DispatchWorkItem { sleepMs(20); ran.withLock { _ = $0.insert(i) } })
    }
    for (i, item) in items.enumerated() where i % 2 == 1 { item.cancel() }
    for item in items { queue.async(group: group, execute: item) }
    group.wait()
    log.add("ran indices: \(ran.withLock { $0.sorted() })")
}

experiment("17. DispatchGroup with cancelled items",
           question: "Does group.wait() still complete when a cancelled item never runs its block?") { log in
    let queue = makeQueue("e17")
    let group = DispatchGroup()
    let gate = Gate()
    gate.hold(on: queue, log: log)
    let item = DispatchWorkItem { log.add("BLOCK EXECUTED") }
    queue.async(group: group, execute: item)
    item.cancel()
    gate.open()
    let r = group.wait(timeout: .now() + .seconds(2))
    log.add("group.wait -> \(r); executed? \(log.contains("BLOCK EXECUTED"))")
}

experiment("18. asyncAfter + cancel / dropped reference",
           question: "Does cancelling a pending asyncAfter item prevent it; does dropping the ref still let it fire?") { log in
    let queue = makeQueue("e18")
    let cancelledItem = DispatchWorkItem { log.add("CANCELLED-ITEM EXECUTED") }
    queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: cancelledItem)
    cancelledItem.cancel()
    do {
        let dropped = DispatchWorkItem { log.add("dropped-ref item executed") }
        queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: dropped)
    }
    sleepMs(300)
    log.add("cancelledItem executed? \(log.contains("CANCELLED-ITEM EXECUTED"))")
}

experiment("19. Suspended queue, cancel, resume",
           question: "Cancelled item enqueued on a suspended queue: does it run after resume?") { log in
    let queue = makeQueue("e19")
    queue.suspend()
    let item = DispatchWorkItem { log.add("BLOCK EXECUTED") }
    queue.async(execute: item)
    item.cancel()
    queue.resume()
    queue.sync {}
    log.add("executed? \(log.contains("BLOCK EXECUTED"))")
}

experiment("20. Cancel racing start (500 trials per delay)",
           question: "If cancel() races the start of execution, is the outcome consistent (no crash/hang)?") { log in
    let queue = makeQueue("e20", concurrent: true)
    for delayMicros in [0, 20, 50, 100, 200, 500] {
        var ranCount = 0
        for _ in 0..<500 {
            let ran = Mutex(false)
            let item = DispatchWorkItem { ran.withLock { $0 = true } }
            queue.async(execute: item)
            let deadline = ContinuousClock.now + .microseconds(delayMicros)
            while ContinuousClock.now < deadline {}
            item.cancel()
            item.wait()
            if ran.withLock({ $0 }) { ranCount += 1 }
        }
        log.add("cancel after ~\(delayMicros)us: ran=\(ranCount) skipped=\(500 - ranCount)")
    }
}

experiment("21. wait() on a never-enqueued item",
           question: "Does wait(timeout:) on a never-submitted item hang, cancelled or not?") { log in
    let item = DispatchWorkItem { log.add("BLOCK EXECUTED") }
    let r = item.wait(timeout: .now() + .milliseconds(200))
    log.add("never-enqueued, not cancelled: wait -> \(r)")
    item.cancel()
    let r2 = item.wait(timeout: .now() + .milliseconds(200))
    log.add("never-enqueued, cancelled: wait -> \(r2)")
}

experiment("22. wait() after cancelling a running item",
           question: "Does wait() on an item cancelled mid-run still block until the running block returns?") { log in
    let queue = makeQueue("e22")
    let started = DispatchSemaphore(value: 0)
    let item = DispatchWorkItem {
        started.signal()
        sleepMs(200)
        log.add("block body finished")
    }
    queue.async(execute: item)
    started.wait()
    item.cancel()
    log.add("cancel() returned immediately; calling wait()")
    item.wait()
    log.add("wait() returned (after body finished)")
}

print("\nDone.")
}
