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
    @usableFromInline
    struct State {
        @usableFromInline var ring: [Element?]
        @usableFromInline var head = 0
        @usableFromInline var count = 0
        @usableFromInline var closed = false
        /// Consumers waiting on an empty queue, and producers on a full one, each with the element it brings.
        @usableFromInline var consumers: WaiterQueue<Continuation<Element?>>
        @usableFromInline var producers: WaiterQueue<(Continuation<Bool>, Element)>

        @inlinable
        init(capacity: Int, waiters: Int) {
            ring = Array(repeating: nil, count: max(1, capacity))
            consumers = WaiterQueue(capacity: waiters)
            producers = WaiterQueue(capacity: 4)
        }

        /// Takes the oldest element, moving a waiting producer's in behind it.
        @inlinable
        mutating func take() -> (element: Element, producer: Continuation<Bool>?)? {
            guard count > 0 else { return nil }
            let element = ring[head]!
            ring[head] = nil
            head = (head + 1) % ring.count
            count -= 1
            var producer: Continuation<Bool>?
            if let (waiting, waitingElement) = producers.popFirst() {
                ring[(head + count) % ring.count] = waitingElement
                count += 1
                producer = waiting
            }
            return (element, producer)
        }

        @inlinable
        mutating func offer(_ element: Element) -> Offer {
            if closed { return .closed }
            // Consumers wait only on an empty queue: the element goes straight to the first.
            if let consumer = consumers.popFirst() { return .handed(consumer) }
            guard count < ring.count else { return .full }
            ring[(head + count) % ring.count] = element
            count += 1
            return .added
        }
    }

    // `Sendable` (as `Send` and `Receive` below): they leave the lock's closure holding only continuations and
    // elements, both `Sendable`.
    @usableFromInline
    enum Offer: Sendable {
        case added
        case handed(Continuation<Element?>)
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
        case .handed(let consumer):
            consumer.resume(returning: element)
            return true
        case .full:
            return await withContinuation { (continuation: Continuation<Bool>) in
                // A consumer moves the element in and resumes this one with `true`; closing resumes it with `false`.
                let offer = state.withLock { state in
                    let offer = state.offer(element)
                    if case .full = offer { state.producers.append((continuation, element)) }
                    return offer
                }
                switch offer {
                case .full: break
                case .added: continuation.resume(returning: true)
                case .closed: continuation.resume(returning: false)
                case .handed(let consumer):
                    consumer.resume(returning: element)
                    continuation.resume(returning: true)
                }
            }
        }
    }

    /// Takes the oldest element, suspending while the queue is empty; `nil` once it's closed and empty.
    @inlinable
    public nonisolated(nonsending) func pop() async -> Element? {
        // `.some(nil)`: closed and empty; `nil`: wait.
        let now: (element: Element, producer: Continuation<Bool>?)?? = state.withLock { state in
            if let taken = state.take() { return .some(taken) }
            return state.closed ? .some(nil) : nil
        }
        if let now {
            guard let now else { return nil }
            now.producer?.resume(returning: true)
            return now.element
        }
        return await withContinuation { (continuation: Continuation<Element?>) in
            let ready: (element: Element, producer: Continuation<Bool>?)?? = state.withLock { state in
                if let taken = state.take() { return .some(taken) }
                if state.closed { return .some(nil) }
                state.consumers.append(continuation)
                return nil
            }
            guard let ready else { return }
            guard let ready else {
                continuation.resume(returning: nil)
                return
            }
            ready.producer?.resume(returning: true)
            continuation.resume(returning: ready.element)
        }
    }

    /// Takes every element left without waiting (after the tasks using the queue have ended), to release what they
    /// hold.
    @inlinable
    public func drain(_ body: (Element) -> Void) {
        while let taken = state.withLock({ $0.take() }) {
            taken.producer?.resume(returning: true)
            body(taken.element)
        }
    }

    /// No more elements: consumers waiting on an empty queue get `nil` (as do later pops, once it's empty), and
    /// producers waiting for room get `false` (as do later pushes).
    @inlinable
    public func close() {
        let (consumers, producers) = state.withLock { state -> ([Continuation<Element?>], [Continuation<Bool>]) in
            guard !state.closed else { return ([], []) }
            state.closed = true
            return (state.consumers.removeAll(), state.producers.removeAll().map(\.0))
        }
        for consumer in consumers { consumer.resume(returning: nil) }
        for producer in producers { producer.resume(returning: false) }
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
    @usableFromInline
    struct State {
        /// The consumer, waiting for an element.
        @usableFromInline var consumer: Continuation<Element?>?
        /// The producer, waiting for the consumer to take its element.
        @usableFromInline var producer: (continuation: Continuation<Bool>, element: Element)?
        /// No more elements are coming.
        @usableFromInline var closed = false
        /// The consumer failed: elements are refused.
        @usableFromInline var failed = false

        @inlinable
        init() {}

        /// What `send` does now; a waiting consumer is taken out.
        @inlinable
        mutating func send() -> Send {
            if failed { return .refused }
            guard let waiting = consumer else { return .wait }
            consumer = nil
            return .handed(waiting)
        }

        /// What `receive` does now; a waiting producer is taken out.
        @inlinable
        mutating func receive() -> Receive {
            guard let (waiting, element) = producer else { return closed ? .closed : .wait }
            producer = nil
            return .taken(element, producer: waiting)
        }
    }

    /// What `send` does, decided under the lock.
    @usableFromInline
    enum Send: Sendable {
        /// Refused (the consumer failed).
        case refused
        /// Taken by the waiting consumer, which is to be resumed with it.
        case handed(Continuation<Element?>)
        /// The consumer is busy: wait for it.
        case wait
    }

    /// What `receive` does, decided under the lock.
    @usableFromInline
    enum Receive: Sendable {
        /// A waiting producer's element; the producer is to be resumed with `true`.
        case taken(Element, producer: Continuation<Bool>)
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
        switch state.withLock({ $0.send() }) {
        case .refused: return false
        case let .handed(consumer):
            consumer.resume(returning: element)
            return true
        case .wait: break
        }
        return await withContinuation { (continuation: Continuation<Bool>) in
            // Again under the lock: the consumer may have come (or failed) since.
            let ready = state.withLock { state in
                let now = state.send()
                if case .wait = now { state.producer = (continuation, element) }
                return now
            }
            switch ready {
            case .refused: continuation.resume(returning: false)
            case let .handed(consumer):
                consumer.resume(returning: element)
                continuation.resume(returning: true)
            case .wait: break // Stored: `receive` or `fail` resumes it.
            }
        }
    }

    /// The next element, waiting for one; `nil` once the producer is done. Calling it again means the previous
    /// element is finished with.
    @inlinable
    public nonisolated(nonsending) func receive() async -> Element? {
        // Fast path: the producer is already waiting with an element (or done): no suspension.
        switch state.withLock({ $0.receive() }) {
        case let .taken(element, producer):
            producer.resume(returning: true)
            return element
        case .closed: return nil
        case .wait: break
        }
        return await withContinuation { (continuation: Continuation<Element?>) in
            // Again under the lock: the producer may have sent (or closed) since.
            let ready = state.withLock { state in
                let now = state.receive()
                if case .wait = now { state.consumer = continuation }
                return now
            }
            switch ready {
            case let .taken(element, producer):
                producer.resume(returning: true)
                continuation.resume(returning: element)
            case .closed: continuation.resume(returning: nil)
            case .wait: break // Stored: `send` or `close` resumes it.
            }
        }
    }

    /// No more elements: a waiting consumer gets `nil`, and so does every later `receive` (after an element a waiting
    /// producer still holds).
    @inlinable
    public func close() {
        let consumer = state.withLock { state in
            state.closed = true
            defer { state.consumer = nil }
            return state.consumer
        }
        consumer?.resume(returning: nil)
    }

    /// The consumer failed: a waiting producer gets `false`, and so does every later `send`.
    @inlinable
    public func fail() {
        let producer = state.withLock { state in
            state.failed = true
            defer { state.producer = nil }
            return state.producer?.continuation
        }
        producer?.resume(returning: false)
    }
}
