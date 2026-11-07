// combineLatest and zip: tuples of several publishers' values. One core
// each, for two to four publishers, keeping each child's values as Any (the
// publisher's receive builds the typed tuple).
//
// combineLatest asks its publishers for everything and sends the latest
// tuple whenever one sends, once all have; when downstream wants none, the
// next tuple waits for its request (only the latest is kept). It finishes
// when all have, or when one finishes without ever sending.
//
// zip passes downstream's demand to each publisher (so an endless
// sequence zipped with something stays bounded), and sends the oldest
// value of each as a tuple once each has one. It finishes when one has
// finished and has nothing left to pair.

final class CombineLatestCore<Downstream: Subscriber>: Subscription, CustomStringConvertible {
    let description = "CombineLatest"
    private let lock = Lock()
    private let downstreamLock = RecursiveLock.recursive()
    private let downstream: Downstream
    private let combine: ([Any]) -> Downstream.Input
    private var values: [Any?]
    private var finished: [Bool]
    private var subscriptions: [(any Subscription)?]
    private var demand = Subscribers.Demand.none
    private var waiting = false
    private var terminal = false

    init(count: Int, downstream: Downstream, combine: @escaping ([Any]) -> Downstream.Input) {
        self.downstream = downstream
        self.combine = combine
        values = Array(repeating: nil, count: count)
        finished = Array(repeating: false, count: count)
        subscriptions = Array(repeating: nil, count: count)
    }

    func start<P: Publisher>(_ index: Int, _ publisher: P) where P.Failure == Downstream.Failure {
        publisher.subscribe(ClosureSubscriber<P.Output, P.Failure>(
            onSubscribe: { [self] subscription in
                let accepted = lock.withLock { () -> Bool in
                    guard !terminal else { return false }
                    subscriptions[index] = subscription
                    return true
                }
                if accepted { subscription.request(.unlimited) } else { subscription.cancel() }
            },
            onValue: { [self] value in
                received(index, value)
                return .none
            },
            onCompletion: { [self] completion in completed(index, completion) }))
    }

    private func received(_ index: Int, _ value: Any) {
        lock.lock()
        guard !terminal else {
            lock.unlock()
            return
        }
        values[index] = value
        guard let tuple = currentTuple() else {
            lock.unlock()
            return
        }
        guard demand > 0 else {
            waiting = true
            lock.unlock()
            return
        }
        demand.consumeOne()
        waiting = false
        lock.unlock()
        deliver(tuple)
    }

    /// The tuple's values, once every child has sent one (the lock held).
    private func currentTuple() -> [Any]? {
        let all = values.compactMap { $0 }
        return all.count == values.count ? all : nil
    }

    private func deliver(_ tuple: [Any]) {
        let more = downstreamLock.withLock { downstream.receive(combine(tuple)) }
        if more > 0 { request(more) }
    }

    private func completed(_ index: Int, _ completion: Subscribers.Completion<Downstream.Failure>) {
        let (others, proceed) = lock.withLock { () -> ([any Subscription], Bool) in
            guard !terminal else { return ([], false) }
            finished[index] = true
            subscriptions[index] = nil
            if case .finished = completion, values[index] != nil, finished.contains(false) { return ([], false) }
            terminal = true
            defer { subscriptions = subscriptions.map { _ in nil } }
            return (subscriptions.compactMap { $0 }, true)
        }
        guard proceed else { return }
        for subscription in others { subscription.cancel() }
        downstreamLock.withLock { downstream.receive(completion: completion) }
    }

    func request(_ demand: Subscribers.Demand) {
        lock.lock()
        self.demand += demand
        guard waiting, !terminal, let tuple = currentTuple() else {
            lock.unlock()
            return
        }
        waiting = false
        self.demand.consumeOne()
        lock.unlock()
        deliver(tuple)
    }

    func cancel() {
        let all = lock.withLock { () -> [any Subscription] in
            terminal = true
            defer { subscriptions = subscriptions.map { _ in nil } }
            return subscriptions.compactMap { $0 }
        }
        for subscription in all { subscription.cancel() }
    }
}

final class ZipCore<Downstream: Subscriber>: Subscription, CustomStringConvertible {
    let description = "Zip"
    private let lock = Lock()
    private let downstreamLock = RecursiveLock.recursive()
    private let downstream: Downstream
    private let combine: ([Any]) -> Downstream.Input
    private var queues: [[Any]]
    private var finished: [Bool]
    private var subscriptions: [(any Subscription)?]
    private var demand = Subscribers.Demand.none
    private var terminal = false
    private var emitting = false

    init(count: Int, downstream: Downstream, combine: @escaping ([Any]) -> Downstream.Input) {
        self.downstream = downstream
        self.combine = combine
        queues = Array(repeating: [], count: count)
        finished = Array(repeating: false, count: count)
        subscriptions = Array(repeating: nil, count: count)
    }

    func start<P: Publisher>(_ index: Int, _ publisher: P) where P.Failure == Downstream.Failure {
        publisher.subscribe(ClosureSubscriber<P.Output, P.Failure>(
            onSubscribe: { [self] subscription in
                let (accepted, outstanding) = lock.withLock { () -> (Bool, Subscribers.Demand) in
                    guard !terminal else { return (false, .none) }
                    subscriptions[index] = subscription
                    return (true, demand)
                }
                if !accepted {
                    subscription.cancel()
                } else if outstanding > 0 {
                    subscription.request(outstanding)
                }
            },
            onValue: { [self] value in
                lock.withLock { if !terminal { queues[index].append(value) } }
                emit()
                return .none
            },
            onCompletion: { [self] completion in
                switch completion {
                case .finished:
                    lock.withLock {
                        finished[index] = true
                        subscriptions[index] = nil
                    }
                    emit()
                case .failure:
                    end(completion)
                }
            }))
    }

    /// Sends tuples while each child has a value and downstream wants
    /// them, then finishes if a finished child has none left.
    private func emit() {
        lock.lock()
        guard !emitting else {
            lock.unlock()
            return
        }
        emitting = true
        while !terminal, demand > 0, !queues.contains(where: { $0.isEmpty }) {
            let tuple = queues.indices.map { queues[$0].removeFirst() }
            demand.consumeOne()
            lock.unlock()
            let more = downstreamLock.withLock { downstream.receive(combine(tuple)) }
            lock.lock()
            if more > 0 {
                demand += more
                let children = subscriptions.compactMap { $0 }
                lock.unlock()
                for child in children { child.request(more) }
                lock.lock()
            }
        }
        emitting = false
        let exhausted = queues.indices.contains { finished[$0] && queues[$0].isEmpty }
        lock.unlock()
        if exhausted { end(.finished) }
    }

    private func end(_ completion: Subscribers.Completion<Downstream.Failure>) {
        let (all, proceed) = lock.withLock { () -> ([any Subscription], Bool) in
            guard !terminal else { return ([], false) }
            terminal = true
            defer { subscriptions = subscriptions.map { _ in nil } }
            return (subscriptions.compactMap { $0 }, true)
        }
        guard proceed else { return }
        for subscription in all { subscription.cancel() }
        downstreamLock.withLock { downstream.receive(completion: completion) }
    }

    func request(_ demand: Subscribers.Demand) {
        let children = lock.withLock { () -> [any Subscription] in
            self.demand += demand
            return terminal ? [] : subscriptions.compactMap { $0 }
        }
        for child in children { child.request(demand) }
        emit()
    }

    func cancel() {
        let all = lock.withLock { () -> [any Subscription] in
            terminal = true
            defer { subscriptions = subscriptions.map { _ in nil } }
            return subscriptions.compactMap { $0 }
        }
        for subscription in all { subscription.cancel() }
    }
}

// MARK: - combineLatest

extension Publisher {
    public func combineLatest<P>(_ other: P) -> Publishers.CombineLatest<Self, P> where P: Publisher, Self.Failure == P.Failure {
        Publishers.CombineLatest(self, other)
    }

    public func combineLatest<P, T>(_ other: P, _ transform: @escaping (Self.Output, P.Output) -> T)
        -> Publishers.Map<Publishers.CombineLatest<Self, P>, T> where P: Publisher, Self.Failure == P.Failure {
        Publishers.CombineLatest(self, other).map(transform)
    }

    public func combineLatest<P, Q>(_ publisher1: P, _ publisher2: Q) -> Publishers.CombineLatest3<Self, P, Q>
    where P: Publisher, Q: Publisher, Self.Failure == P.Failure, P.Failure == Q.Failure {
        Publishers.CombineLatest3(self, publisher1, publisher2)
    }

    public func combineLatest<P, Q, T>(_ publisher1: P, _ publisher2: Q,
                                       _ transform: @escaping (Self.Output, P.Output, Q.Output) -> T)
        -> Publishers.Map<Publishers.CombineLatest3<Self, P, Q>, T>
    where P: Publisher, Q: Publisher, Self.Failure == P.Failure, P.Failure == Q.Failure {
        Publishers.CombineLatest3(self, publisher1, publisher2).map(transform)
    }

    public func combineLatest<P, Q, R>(_ publisher1: P, _ publisher2: Q, _ publisher3: R)
        -> Publishers.CombineLatest4<Self, P, Q, R>
    where P: Publisher, Q: Publisher, R: Publisher, Self.Failure == P.Failure, P.Failure == Q.Failure,
        Q.Failure == R.Failure {
        Publishers.CombineLatest4(self, publisher1, publisher2, publisher3)
    }

    public func combineLatest<P, Q, R, T>(_ publisher1: P, _ publisher2: Q, _ publisher3: R,
                                          _ transform: @escaping (Self.Output, P.Output, Q.Output, R.Output) -> T)
        -> Publishers.Map<Publishers.CombineLatest4<Self, P, Q, R>, T>
    where P: Publisher, Q: Publisher, R: Publisher, Self.Failure == P.Failure, P.Failure == Q.Failure,
        Q.Failure == R.Failure {
        Publishers.CombineLatest4(self, publisher1, publisher2, publisher3).map(transform)
    }
}

extension Publishers {
    public struct CombineLatest<A, B>: Publisher where A: Publisher, B: Publisher, A.Failure == B.Failure {
        public typealias Output = (A.Output, B.Output)
        public typealias Failure = A.Failure

        public let a: A
        public let b: B

        public init(_ a: A, _ b: B) {
            self.a = a
            self.b = b
        }

        public func receive<S>(subscriber: S) where S: Subscriber, B.Failure == S.Failure, S.Input == (A.Output, B.Output) {
            let core = CombineLatestCore(count: 2, downstream: subscriber) { ($0[0] as! A.Output, $0[1] as! B.Output) }
            subscriber.receive(subscription: core)
            core.start(0, a)
            core.start(1, b)
        }
    }

    public struct CombineLatest3<A, B, C>: Publisher
    where A: Publisher, B: Publisher, C: Publisher, A.Failure == B.Failure, B.Failure == C.Failure {
        public typealias Output = (A.Output, B.Output, C.Output)
        public typealias Failure = A.Failure

        public let a: A
        public let b: B
        public let c: C

        public init(_ a: A, _ b: B, _ c: C) {
            self.a = a
            self.b = b
            self.c = c
        }

        public func receive<S>(subscriber: S) where S: Subscriber, C.Failure == S.Failure,
            S.Input == (A.Output, B.Output, C.Output) {
            let core = CombineLatestCore(count: 3, downstream: subscriber) {
                ($0[0] as! A.Output, $0[1] as! B.Output, $0[2] as! C.Output)
            }
            subscriber.receive(subscription: core)
            core.start(0, a)
            core.start(1, b)
            core.start(2, c)
        }
    }

    public struct CombineLatest4<A, B, C, D>: Publisher
    where A: Publisher, B: Publisher, C: Publisher, D: Publisher, A.Failure == B.Failure, B.Failure == C.Failure,
        C.Failure == D.Failure {
        public typealias Output = (A.Output, B.Output, C.Output, D.Output)
        public typealias Failure = A.Failure

        public let a: A
        public let b: B
        public let c: C
        public let d: D

        public init(_ a: A, _ b: B, _ c: C, _ d: D) {
            self.a = a
            self.b = b
            self.c = c
            self.d = d
        }

        public func receive<S>(subscriber: S) where S: Subscriber, D.Failure == S.Failure,
            S.Input == (A.Output, B.Output, C.Output, D.Output) {
            let core = CombineLatestCore(count: 4, downstream: subscriber) {
                ($0[0] as! A.Output, $0[1] as! B.Output, $0[2] as! C.Output, $0[3] as! D.Output)
            }
            subscriber.receive(subscription: core)
            core.start(0, a)
            core.start(1, b)
            core.start(2, c)
            core.start(3, d)
        }
    }
}

extension Publishers.CombineLatest: Equatable where A: Equatable, B: Equatable {
    public static func == (lhs: Publishers.CombineLatest<A, B>, rhs: Publishers.CombineLatest<A, B>) -> Bool {
        lhs.a == rhs.a && lhs.b == rhs.b
    }
}
extension Publishers.CombineLatest3: Equatable where A: Equatable, B: Equatable, C: Equatable {
    public static func == (lhs: Publishers.CombineLatest3<A, B, C>, rhs: Publishers.CombineLatest3<A, B, C>) -> Bool {
        lhs.a == rhs.a && lhs.b == rhs.b && lhs.c == rhs.c
    }
}
extension Publishers.CombineLatest4: Equatable where A: Equatable, B: Equatable, C: Equatable, D: Equatable {
    public static func == (lhs: Publishers.CombineLatest4<A, B, C, D>, rhs: Publishers.CombineLatest4<A, B, C, D>) -> Bool {
        lhs.a == rhs.a && lhs.b == rhs.b && lhs.c == rhs.c && lhs.d == rhs.d
    }
}

// MARK: - zip

extension Publisher {
    public func zip<P>(_ other: P) -> Publishers.Zip<Self, P> where P: Publisher, Self.Failure == P.Failure {
        Publishers.Zip(self, other)
    }

    public func zip<P, T>(_ other: P, _ transform: @escaping (Self.Output, P.Output) -> T)
        -> Publishers.Map<Publishers.Zip<Self, P>, T> where P: Publisher, Self.Failure == P.Failure {
        Publishers.Zip(self, other).map(transform)
    }

    public func zip<P, Q>(_ publisher1: P, _ publisher2: Q) -> Publishers.Zip3<Self, P, Q>
    where P: Publisher, Q: Publisher, Self.Failure == P.Failure, P.Failure == Q.Failure {
        Publishers.Zip3(self, publisher1, publisher2)
    }

    public func zip<P, Q, T>(_ publisher1: P, _ publisher2: Q, _ transform: @escaping (Self.Output, P.Output, Q.Output) -> T)
        -> Publishers.Map<Publishers.Zip3<Self, P, Q>, T>
    where P: Publisher, Q: Publisher, Self.Failure == P.Failure, P.Failure == Q.Failure {
        Publishers.Zip3(self, publisher1, publisher2).map(transform)
    }

    public func zip<P, Q, R>(_ publisher1: P, _ publisher2: Q, _ publisher3: R) -> Publishers.Zip4<Self, P, Q, R>
    where P: Publisher, Q: Publisher, R: Publisher, Self.Failure == P.Failure, P.Failure == Q.Failure,
        Q.Failure == R.Failure {
        Publishers.Zip4(self, publisher1, publisher2, publisher3)
    }

    public func zip<P, Q, R, T>(_ publisher1: P, _ publisher2: Q, _ publisher3: R,
                                _ transform: @escaping (Self.Output, P.Output, Q.Output, R.Output) -> T)
        -> Publishers.Map<Publishers.Zip4<Self, P, Q, R>, T>
    where P: Publisher, Q: Publisher, R: Publisher, Self.Failure == P.Failure, P.Failure == Q.Failure,
        Q.Failure == R.Failure {
        Publishers.Zip4(self, publisher1, publisher2, publisher3).map(transform)
    }
}

extension Publishers {
    public struct Zip<A, B>: Publisher where A: Publisher, B: Publisher, A.Failure == B.Failure {
        public typealias Output = (A.Output, B.Output)
        public typealias Failure = A.Failure

        public let a: A
        public let b: B

        public init(_ a: A, _ b: B) {
            self.a = a
            self.b = b
        }

        public func receive<S>(subscriber: S) where S: Subscriber, B.Failure == S.Failure, S.Input == (A.Output, B.Output) {
            let core = ZipCore(count: 2, downstream: subscriber) { ($0[0] as! A.Output, $0[1] as! B.Output) }
            subscriber.receive(subscription: core)
            core.start(0, a)
            core.start(1, b)
        }
    }

    public struct Zip3<A, B, C>: Publisher
    where A: Publisher, B: Publisher, C: Publisher, A.Failure == B.Failure, B.Failure == C.Failure {
        public typealias Output = (A.Output, B.Output, C.Output)
        public typealias Failure = A.Failure

        public let a: A
        public let b: B
        public let c: C

        public init(_ a: A, _ b: B, _ c: C) {
            self.a = a
            self.b = b
            self.c = c
        }

        public func receive<S>(subscriber: S) where S: Subscriber, C.Failure == S.Failure,
            S.Input == (A.Output, B.Output, C.Output) {
            let core = ZipCore(count: 3, downstream: subscriber) {
                ($0[0] as! A.Output, $0[1] as! B.Output, $0[2] as! C.Output)
            }
            subscriber.receive(subscription: core)
            core.start(0, a)
            core.start(1, b)
            core.start(2, c)
        }
    }

    public struct Zip4<A, B, C, D>: Publisher
    where A: Publisher, B: Publisher, C: Publisher, D: Publisher, A.Failure == B.Failure, B.Failure == C.Failure,
        C.Failure == D.Failure {
        public typealias Output = (A.Output, B.Output, C.Output, D.Output)
        public typealias Failure = A.Failure

        public let a: A
        public let b: B
        public let c: C
        public let d: D

        public init(_ a: A, _ b: B, _ c: C, _ d: D) {
            self.a = a
            self.b = b
            self.c = c
            self.d = d
        }

        public func receive<S>(subscriber: S) where S: Subscriber, D.Failure == S.Failure,
            S.Input == (A.Output, B.Output, C.Output, D.Output) {
            let core = ZipCore(count: 4, downstream: subscriber) {
                ($0[0] as! A.Output, $0[1] as! B.Output, $0[2] as! C.Output, $0[3] as! D.Output)
            }
            subscriber.receive(subscription: core)
            core.start(0, a)
            core.start(1, b)
            core.start(2, c)
            core.start(3, d)
        }
    }
}

extension Publishers.Zip: Equatable where A: Equatable, B: Equatable {
    public static func == (lhs: Publishers.Zip<A, B>, rhs: Publishers.Zip<A, B>) -> Bool {
        lhs.a == rhs.a && lhs.b == rhs.b
    }
}
extension Publishers.Zip3: Equatable where A: Equatable, B: Equatable, C: Equatable {
    public static func == (lhs: Publishers.Zip3<A, B, C>, rhs: Publishers.Zip3<A, B, C>) -> Bool {
        lhs.a == rhs.a && lhs.b == rhs.b && lhs.c == rhs.c
    }
}
extension Publishers.Zip4: Equatable where A: Equatable, B: Equatable, C: Equatable, D: Equatable {
    public static func == (lhs: Publishers.Zip4<A, B, C, D>, rhs: Publishers.Zip4<A, B, C, D>) -> Bool {
        lhs.a == rhs.a && lhs.b == rhs.b && lhs.c == rhs.c && lhs.d == rhs.d
    }
}
