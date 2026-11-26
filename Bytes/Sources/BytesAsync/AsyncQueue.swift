public import Synchronization

/// A first-in, first-out queue with a fixed capacity, between tasks: `push` suspends while it's full and `pop` while
/// it's empty. An element pushed while a consumer waits goes straight to it; a consumer taking from a full queue moves
/// a waiting producer's element in. The ring and the waiters' storage are allocated once: nothing per element.
///
/// ```swift
/// let jobs = AsyncQueue<Job>(capacity: 64, waiters: workers)
/// // Producer:                          // Each worker:
/// for job in work { await jobs.push(job) }     while let job = await jobs.pop() { run(job) }
/// jobs.close()
/// ```
///
/// Waits aren't cancellable one at a time: ``close()`` wakes every waiter (call it from the operation's one
/// cancellation handler).
public final class AsyncQueue<Element: Sendable>: Sendable {
    /// A producer waiting for room, with the element it brings.
    @usableFromInline
    struct Producer: ~Copyable, Sendable {
        @usableFromInline var continuation: Continuation<Bool, Never>
        @usableFromInline var element: Element

        @inlinable
        init(continuation: consuming Continuation<Bool, Never>, element: Element) {
            self.continuation = continuation
            self.element = element
        }
    }

    /// An element taken, and the producer whose element moved in behind it (to resume with `true`).
    @usableFromInline
    struct Taken: ~Copyable, Sendable {
        @usableFromInline var element: Element
        @usableFromInline var producer: Continuation<Bool, Never>?

        @inlinable
        init(element: Element, producer: consuming Continuation<Bool, Never>?) {
            self.element = element
            self.producer = producer
        }
    }

    @usableFromInline
    struct State: ~Copyable {
        /// The ring: `head..<head + count`, wrapping, holds the elements; the other slots are `nil`. A `UniqueArray`:
        /// no copy-on-write check on a store.
        @usableFromInline var ring: UniqueArray<Element?>
        @usableFromInline var head = 0
        @usableFromInline var count = 0
        @usableFromInline var closed = false
        /// Consumers waiting on an empty queue, and producers on a full one.
        @usableFromInline var consumers: WaiterQueue<Continuation<Element?, Never>>
        @usableFromInline var producers: WaiterQueue<Producer>

        @inlinable
        init(capacity: Int, waiters: Int) {
            let capacity = max(1, capacity)
            ring = UniqueArray(capacity: capacity) { output in
                for _ in 0..<capacity {
                    output.append(nil)
                }
            }
            consumers = WaiterQueue(capacity: waiters)
            producers = WaiterQueue(capacity: 4)
        }

        /// The slot `offset` places after the head, wrapped by a compare.
        @inlinable @inline(__always)
        func slot(_ offset: Int) -> Int {
            let index = head &+ offset
            return index >= ring.count ? index &- ring.count : index
        }

        /// Takes the oldest element, moving a waiting producer's in behind it.
        @inlinable
        mutating func take() -> Taken? {
            guard count > 0 else { return nil }
            let element = ring[head].take()!
            head &+= 1
            if head == ring.count { head = 0 }
            count &-= 1
            guard let waiting = producers.popFirst() else { return Taken(element: element, producer: nil) }
            ring[slot(count)] = waiting.element
            count &+= 1
            return Taken(element: element, producer: waiting.continuation)
        }

        @inlinable
        mutating func offer(_ element: Element) -> Offer {
            if closed { return .closed }
            // Consumers wait only on an empty queue: the element goes straight to the first.
            if let consumer = consumers.popFirst() { return .handed(consumer) }
            guard count < ring.count else { return .full }
            ring[slot(count)] = element
            count &+= 1
            return .added
        }
    }

    /// What `pop` does now, decided under the lock.
    @usableFromInline
    enum Pop: ~Copyable, Sendable {
        case taken(Taken)
        case closed
        case wait
    }

    /// What `push` does, decided under the lock: noncopyable, as it can carry a consumer's continuation out.
    @usableFromInline
    enum Offer: ~Copyable, Sendable {
        case added
        case handed(Continuation<Element?, Never>)
        case full
        case closed
    }

    @usableFromInline let state: Mutex<State>

    /// - Parameters:
    ///   - capacity: Elements held at once (at least 1).
    ///   - waiters: Consumers expected to wait at once, reserved for (more grow the storage once).
    @inlinable
    public init(capacity: Int, waiters: Int = 32) {
        state = Mutex(State(capacity: capacity, waiters: waiters))
    }

    /// Adds an element, suspending while the queue is full.
    ///
    /// - Returns: `false` if the queue was closed instead (the element isn't added: what it holds is the caller's).
    @inlinable @discardableResult
    public nonisolated(nonsending) func push(_ element: Element) async -> Bool {
        switch state.withLock({ $0.offer(element) }) {
        case .added: return true
        case .closed: return false
        case let .handed(consumer):
            consumer.resume(returning: element)
            return true
        case .full:
            var consumer: Continuation<Element?, Never>?
            let added = await wait(in: state) { state, continuation in
                // A consumer moves the element in and resumes this one with `true`; closing resumes it with `false`.
                switch state.offer(element) {
                case .full:
                    state.producers.append(Producer(continuation: continuation.take()!, element: element))
                    return nil
                case .added: return true
                case .closed: return false
                case let .handed(waiting):
                    // A consumer came since: resumed below, after this task's own answer is decided.
                    consumer = consume waiting
                    return true
                }
            }
            consumer?.resume(returning: element)
            return added
        }
    }

    /// Takes the oldest element, suspending while the queue is empty; `nil` once it's closed and empty.
    @inlinable
    public nonisolated(nonsending) func pop() async -> Element? {
        switch state.withLock({ state -> Pop in
            if let taken = state.take() { return .taken(taken) }
            return state.closed ? .closed : .wait
        }) {
        case var .taken(taken):
            taken.producer.take()?.resume(returning: true)
            return taken.element
        case .closed: return nil
        case .wait: break
        }
        var producer: Continuation<Bool, Never>?
        let element = await wait(in: state) { state, continuation -> Element?? in
            if var taken = state.take() {
                producer = taken.producer.take()
                return .some(taken.element)
            }
            if state.closed { return .some(nil) }
            state.consumers.append(continuation.take()!)
            return nil
        }
        producer?.resume(returning: true)
        return element
    }

    /// Takes every element left without waiting (after the tasks using the queue have ended), to release what they
    /// hold.
    @inlinable
    public func drain(_ body: (Element) -> Void) {
        while var taken = state.withLock({ $0.take() }) {
            taken.producer.take()?.resume(returning: true)
            body(taken.element)
        }
    }

    /// No more elements: consumers waiting on an empty queue get `nil` (as do later pops, once it's empty), and
    /// producers waiting for room get `false` (as do later pushes).
    @inlinable
    public func close() {
        var waiting = state.withLock { state -> Waiting in
            guard !state.closed else { return Waiting(consumers: WaiterQueue(), producers: WaiterQueue()) }
            state.closed = true
            return Waiting(consumers: state.consumers.removeAll(), producers: state.producers.removeAll())
        }
        while let consumer = waiting.consumers.popFirst() {
            consumer.resume(returning: nil)
        }
        while let producer = waiting.producers.popFirst() {
            producer.continuation.resume(returning: false)
        }
    }

    /// The waiters ``close()`` takes out of the lock.
    @usableFromInline
    struct Waiting: ~Copyable, Sendable {
        @usableFromInline var consumers: WaiterQueue<Continuation<Element?, Never>>
        @usableFromInline var producers: WaiterQueue<Producer>

        @inlinable
        init(consumers: consuming WaiterQueue<Continuation<Element?, Never>>, producers: consuming WaiterQueue<Producer>) {
            self.consumers = consumers
            self.producers = producers
        }
    }
}

/// A rendezvous between one task making elements and one task consuming them, in order: `send` returns once the
/// consumer has finished with the previous element and taken the new one, so the producer can reuse what the
/// previous one referred to (two buffers alternating). Nothing is allocated per element.
///
/// ```swift
/// // Producer (a child task):              // Consumer:
/// defer { handoff.close() }                do {
/// while let chunk = decode() {                 while let chunk = await handoff.receive() { try write(chunk) }
///     guard await handoff.send(chunk)      } catch { handoff.fail(); throw error }
///     else { return }
/// }
/// ```
public final class AsyncHandoff<Element: Sendable>: Sendable {
    /// The producer, waiting for the consumer to take its element.
    @usableFromInline
    struct Producer: ~Copyable, Sendable {
        @usableFromInline var continuation: Continuation<Bool, Never>
        @usableFromInline var element: Element

        @inlinable
        init(continuation: consuming Continuation<Bool, Never>, element: Element) {
            self.continuation = continuation
            self.element = element
        }
    }

    @usableFromInline
    struct State: ~Copyable {
        /// The consumer, waiting for an element.
        @usableFromInline var consumer: Continuation<Element?, Never>?
        /// The producer, waiting for the consumer to take its element.
        @usableFromInline var producer: Producer?
        /// No more elements are coming.
        @usableFromInline var closed = false
        /// The consumer failed: elements are refused.
        @usableFromInline var failed = false

        @inlinable
        init() {
            consumer = nil
            producer = nil
        }
    }

    /// What `send` does now, decided under the lock.
    @usableFromInline
    enum Send: ~Copyable, Sendable {
        /// Refused (the consumer failed).
        case refused
        /// Taken by the waiting consumer, which is to be resumed with it.
        case handed(Continuation<Element?, Never>)
        /// The consumer is busy: wait for it.
        case wait
    }

    /// What `receive` does now, decided under the lock.
    @usableFromInline
    enum Receive: ~Copyable, Sendable {
        /// A waiting producer's element; the producer is to be resumed with `true`.
        case taken(Producer)
        /// No more elements.
        case closed
        /// Nothing yet: wait for the producer.
        case wait
    }

    @usableFromInline let state = Mutex(State())

    @inlinable
    public init() {}

    /// Hands `element` to the consumer, waiting until it's free.
    ///
    /// - Returns: `false` if the consumer failed (the element wasn't taken).
    @inlinable
    public nonisolated(nonsending) func send(_ element: Element) async -> Bool {
        // Fast path: the consumer is already waiting (or has failed): no suspension.
        switch state.withLock({ state -> Send in
            if state.failed { return .refused }
            guard let consumer = state.consumer.take() else { return .wait }
            return .handed(consumer)
        }) {
        case .refused: return false
        case let .handed(consumer):
            consumer.resume(returning: element)
            return true
        case .wait: break
        }
        var consumer: Continuation<Element?, Never>?
        let sent = await wait(in: state) { state, continuation in
            // Again under the lock: the consumer may have come (or failed) since.
            if state.failed { return false }
            if let waiting = state.consumer.take() {
                consumer = consume waiting
                return true
            }
            precondition(state.producer == nil, "AsyncHandoff: one task sends")
            state.producer = Producer(continuation: continuation.take()!, element: element)
            return nil
        }
        consumer?.resume(returning: element)
        return sent
    }

    /// The next element, waiting for one; `nil` once the producer is done. Calling it again means the previous
    /// element is finished with.
    @inlinable
    public nonisolated(nonsending) func receive() async -> Element? {
        // Fast path: the producer is already waiting with an element (or done): no suspension.
        switch state.withLock({ state -> Receive in
            if let producer = state.producer.take() { return .taken(producer) }
            return state.closed ? .closed : .wait
        }) {
        case let .taken(producer):
            let element = producer.element
            producer.continuation.resume(returning: true)
            return element
        case .closed: return nil
        case .wait: break
        }
        var producer: Continuation<Bool, Never>?
        let element = await wait(in: state) { state, continuation -> Element?? in
            // Again under the lock: the producer may have sent (or closed) since.
            if let waiting = state.producer.take() {
                producer = consume waiting.continuation
                return .some(waiting.element)
            }
            if state.closed { return .some(nil) }
            precondition(state.consumer == nil, "AsyncHandoff: one task receives")
            state.consumer = continuation.take()
            return nil
        }
        producer?.resume(returning: true)
        return element
    }

    /// No more elements: a waiting consumer gets `nil`, and so does every later `receive` (after an element a waiting
    /// producer still holds).
    @inlinable
    public func close() {
        let consumer = state.withLock { state in
            state.closed = true
            return state.consumer.take()
        }
        consumer?.resume(returning: nil)
    }

    /// The consumer failed: a waiting producer gets `false`, and so does every later `send`.
    @inlinable
    public func fail() {
        let producer = state.withLock { state in
            state.failed = true
            return state.producer.take()
        }
        // Unwrapped first: `producer?.continuation.resume(…)` is "copy of noncopyable typed value. This is a compiler
        // bug" (Swift 6.4).
        if let producer = consume producer { producer.continuation.resume(returning: false) }
    }
}
