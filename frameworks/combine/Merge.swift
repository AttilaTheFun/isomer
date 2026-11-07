// merge, MergeMany and flatMap: values from several publishers, each sent
// on as it comes. One MergeCore serves them all: Merge's publishers are
// its children from the start; flatMap's are made from its upstream's
// values, as many at once as maxPublishers allows.
//
// Demand: with unlimited demand every child is asked for everything. With
// a count, each child is asked for one value at a time while downstream
// still wants some; a value that arrives when downstream has none left
// (two children answered one request) waits with its child until
// downstream asks again, and that child is asked for no more till then.

final class MergeCore<Downstream: Subscriber>: Subscription, CustomStringConvertible {
    typealias Output = Downstream.Input
    typealias Failure = Downstream.Failure

    private struct Child {
        var subscription: (any Subscription)?
        var pending: Output?
        /// Has no request outstanding.
        var idle = true
        var askedUnlimited = false
        var finished = false
    }

    let description: String
    private let lock = Lock()
    private let downstreamLock = RecursiveLock.recursive()
    private let downstream: Downstream
    private var demand = Subscribers.Demand.none
    private var children: [Int: Child] = [:]
    private var order: [Int] = []
    private var nextID = 0
    /// More children may come (flatMap's upstream, or Merge still adding).
    private var open = true
    private var terminal = false
    private var draining = false
    private var drainAgain = false
    /// flatMap's upstream.
    private var outer: (any Subscription)?
    /// Called when a child finishes (flatMap asks its upstream for another).
    var childFinished: (() -> Void)?

    init(_ name: String, downstream: Downstream) {
        description = name
        self.downstream = downstream
    }

    func start() {
        downstream.receive(subscription: self)
    }

    func add<P: Publisher>(_ publisher: P) where P.Output == Output, P.Failure == Failure {
        let id = lock.withLock { () -> Int? in
            guard !terminal else { return nil }
            let id = nextID
            nextID += 1
            children[id] = Child()
            order.append(id)
            return id
        }
        guard let id else { return }
        publisher.subscribe(MergeChild(core: self, id: id))
    }

    /// No more children will come: finished once those there are.
    func close() {
        let done = lock.withLock { () -> Bool in
            open = false
            outer = nil
            guard !terminal, children.isEmpty else { return false }
            terminal = true
            return true
        }
        if done { send(.finished) }
    }

    func setOuter(_ subscription: any Subscription) {
        let accepted = lock.withLock { () -> Bool in
            guard !terminal, outer == nil else { return false }
            outer = subscription
            return true
        }
        if !accepted { subscription.cancel() }
    }

    func requestOuter(_ demand: Subscribers.Demand) {
        lock.withLock { outer }?.request(demand)
    }

    func fail(_ error: Failure) {
        let (subscriptions, proceed) = lock.withLock { () -> ([any Subscription], Bool) in
            guard !terminal else { return ([], false) }
            terminal = true
            return (takeSubscriptions(), true)
        }
        guard proceed else { return }
        for subscription in subscriptions { subscription.cancel() }
        send(.failure(error))
    }

    private func takeSubscriptions() -> [any Subscription] {
        var subscriptions = order.compactMap { children[$0]?.subscription }
        if let outer { subscriptions.append(outer) }
        children = [:]
        order = []
        outer = nil
        return subscriptions
    }

    private func send(_ completion: Subscribers.Completion<Failure>) {
        downstreamLock.withLock { downstream.receive(completion: completion) }
    }

    // MARK: Children

    func childSubscribed(_ id: Int, _ subscription: any Subscription) {
        lock.lock()
        guard !terminal, children[id] != nil, children[id]?.subscription == nil else {
            lock.unlock()
            subscription.cancel()
            return
        }
        children[id]?.subscription = subscription
        lock.unlock()
        drain()
    }

    func childValue(_ id: Int, _ value: Output) -> Subscribers.Demand {
        lock.lock()
        guard !terminal, children[id] != nil else {
            lock.unlock()
            return .none
        }
        if demand == .unlimited {
            lock.unlock()
            _ = downstreamLock.withLock { downstream.receive(value) }
            return .none
        }
        children[id]?.idle = true
        guard demand > 0 else {
            children[id]?.pending = value
            children[id]?.idle = false
            lock.unlock()
            return .none
        }
        demand.consumeOne()
        lock.unlock()
        let more = downstreamLock.withLock { downstream.receive(value) }
        lock.withLock { demand += more }
        drain()
        return .none
    }

    func childCompleted(_ id: Int, _ completion: Subscribers.Completion<Failure>) {
        if case .failure(let error) = completion {
            fail(error)
            return
        }
        let (done, removed) = lock.withLock { () -> (Bool, Bool) in
            guard !terminal, children[id] != nil else { return (false, false) }
            if children[id]?.pending != nil {
                // Finished once its value is sent (drain).
                children[id]?.finished = true
                return (false, false)
            }
            return (removeChild(id), true)
        }
        if removed { childFinished?() }
        if done { send(.finished) }
    }

    /// Removes a finished child; whether that finishes the whole (the lock held).
    private func removeChild(_ id: Int) -> Bool {
        children[id] = nil
        order.removeAll { $0 == id }
        guard children.isEmpty, !open, !terminal else { return false }
        terminal = true
        return true
    }

    /// Sends what children hold while downstream wants it, then asks idle
    /// children for more. One drain at a time; a call during one makes it
    /// go round again.
    private func drain() {
        lock.lock()
        if draining {
            drainAgain = true
            lock.unlock()
            return
        }
        draining = true
        while true {
            drainAgain = false
            if terminal { break }
            // A held value first.
            if demand > 0, let id = order.first(where: { children[$0]?.pending != nil }),
               let value = children[id]?.pending {
                children[id]?.pending = nil
                children[id]?.idle = true
                demand.consumeOne()
                var done = false
                var removed = false
                if children[id]?.finished == true {
                    done = removeChild(id)
                    removed = true
                }
                lock.unlock()
                let more = downstreamLock.withLock { downstream.receive(value) }
                if removed { childFinished?() }
                if done {
                    send(.finished)
                    lock.lock()
                    break
                }
                lock.lock()
                demand += more
                continue
            }
            // Then requests: everything when downstream wants everything,
            // else one per idle child while downstream wants more.
            var requests: [(any Subscription, Subscribers.Demand)] = []
            if demand == .unlimited {
                for id in order {
                    guard let child = children[id], let subscription = child.subscription,
                          !child.askedUnlimited, child.pending == nil else { continue }
                    children[id]?.askedUnlimited = true
                    children[id]?.idle = false
                    requests.append((subscription, .unlimited))
                }
            } else if demand > 0 {
                for id in order {
                    guard let child = children[id], let subscription = child.subscription,
                          child.idle, child.pending == nil, !child.finished else { continue }
                    children[id]?.idle = false
                    requests.append((subscription, .max(1)))
                }
            }
            if requests.isEmpty && !drainAgain { break }
            lock.unlock()
            for (subscription, amount) in requests { subscription.request(amount) }
            lock.lock()
        }
        draining = false
        lock.unlock()
    }

    // MARK: Subscription

    func request(_ demand: Subscribers.Demand) {
        precondition(demand > 0, "A request must be for at least one value")
        lock.withLock { self.demand += demand }
        drain()
    }

    func cancel() {
        let subscriptions = lock.withLock { () -> [any Subscription] in
            terminal = true
            return takeSubscriptions()
        }
        for subscription in subscriptions { subscription.cancel() }
    }
}

final class MergeChild<Downstream: Subscriber>: Subscriber {
    typealias Input = Downstream.Input
    typealias Failure = Downstream.Failure

    private let core: MergeCore<Downstream>
    private let id: Int

    init(core: MergeCore<Downstream>, id: Int) {
        self.core = core
        self.id = id
    }

    func receive(subscription: any Subscription) { core.childSubscribed(id, subscription) }
    func receive(_ input: Input) -> Subscribers.Demand { core.childValue(id, input) }
    func receive(completion: Subscribers.Completion<Failure>) { core.childCompleted(id, completion) }
}

extension MergeCore {
    /// Merge's: the children all there from the start.
    static func merge(_ name: String, _ downstream: Downstream, _ add: (MergeCore) -> Void) {
        let core = MergeCore(name, downstream: downstream)
        core.start()
        add(core)
        core.close()
    }
}

// MARK: - merge

extension Publisher {
    public func merge<P>(with other: P) -> Publishers.Merge<Self, P>
    where P: Publisher, Self.Failure == P.Failure, Self.Output == P.Output {
        Publishers.Merge(self, other)
    }

    public func merge(with other: Self) -> Publishers.MergeMany<Self> {
        Publishers.MergeMany(self, other)
    }
}

extension Publisher {
    public func merge<B, C>(with b: B, _ c: C) -> Publishers.Merge3<Self, B, C>
    where B: Publisher, C: Publisher, Self.Failure == B.Failure, Self.Output == B.Output, B.Failure == C.Failure, B.Output == C.Output {
        Publishers.Merge3(self, b, c)
    }

    public func merge<B, C, D>(with b: B, _ c: C, _ d: D) -> Publishers.Merge4<Self, B, C, D>
    where B: Publisher, C: Publisher, D: Publisher, Self.Failure == B.Failure, Self.Output == B.Output, B.Failure == C.Failure, B.Output == C.Output, C.Failure == D.Failure, C.Output == D.Output {
        Publishers.Merge4(self, b, c, d)
    }

    public func merge<B, C, D, E>(with b: B, _ c: C, _ d: D, _ e: E) -> Publishers.Merge5<Self, B, C, D, E>
    where B: Publisher, C: Publisher, D: Publisher, E: Publisher, Self.Failure == B.Failure, Self.Output == B.Output, B.Failure == C.Failure, B.Output == C.Output, C.Failure == D.Failure, C.Output == D.Output, D.Failure == E.Failure, D.Output == E.Output {
        Publishers.Merge5(self, b, c, d, e)
    }

    public func merge<B, C, D, E, F>(with b: B, _ c: C, _ d: D, _ e: E, _ f: F) -> Publishers.Merge6<Self, B, C, D, E, F>
    where B: Publisher, C: Publisher, D: Publisher, E: Publisher, F: Publisher, Self.Failure == B.Failure, Self.Output == B.Output, B.Failure == C.Failure, B.Output == C.Output, C.Failure == D.Failure, C.Output == D.Output, D.Failure == E.Failure, D.Output == E.Output, E.Failure == F.Failure, E.Output == F.Output {
        Publishers.Merge6(self, b, c, d, e, f)
    }

    public func merge<B, C, D, E, F, G>(with b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G) -> Publishers.Merge7<Self, B, C, D, E, F, G>
    where B: Publisher, C: Publisher, D: Publisher, E: Publisher, F: Publisher, G: Publisher, Self.Failure == B.Failure, Self.Output == B.Output, B.Failure == C.Failure, B.Output == C.Output, C.Failure == D.Failure, C.Output == D.Output, D.Failure == E.Failure, D.Output == E.Output, E.Failure == F.Failure, E.Output == F.Output, F.Failure == G.Failure, F.Output == G.Output {
        Publishers.Merge7(self, b, c, d, e, f, g)
    }

    public func merge<B, C, D, E, F, G, H>(with b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G, _ h: H) -> Publishers.Merge8<Self, B, C, D, E, F, G, H>
    where B: Publisher, C: Publisher, D: Publisher, E: Publisher, F: Publisher, G: Publisher, H: Publisher, Self.Failure == B.Failure, Self.Output == B.Output, B.Failure == C.Failure, B.Output == C.Output, C.Failure == D.Failure, C.Output == D.Output, D.Failure == E.Failure, D.Output == E.Output, E.Failure == F.Failure, E.Output == F.Output, F.Failure == G.Failure, F.Output == G.Output, G.Failure == H.Failure, G.Output == H.Output {
        Publishers.Merge8(self, b, c, d, e, f, g, h)
    }
}

extension Publishers {
    public struct Merge<A, B>: Publisher
    where A: Publisher, B: Publisher, A.Failure == B.Failure, A.Output == B.Output {
        public typealias Output = A.Output
        public typealias Failure = A.Failure

        public let a: A
        public let b: B

        public init(_ a: A, _ b: B) {
            self.a = a
            self.b = b
        }

        public func receive<S>(subscriber: S) where S: Subscriber, B.Failure == S.Failure, B.Output == S.Input {
            MergeCore.merge("Merge", subscriber) { core in
                core.add(a)
                core.add(b)
            }
        }

        public func merge<P>(with other: P) -> Publishers.Merge3<A, B, P>
        where P: Publisher, B.Failure == P.Failure, B.Output == P.Output {
            Publishers.Merge3(a, b, other)
        }

        public func merge<Z, Y>(with z: Z, _ y: Y) -> Publishers.Merge4<A, B, Z, Y>
        where Z: Publisher, Y: Publisher, B.Failure == Z.Failure, B.Output == Z.Output, Z.Failure == Y.Failure, Z.Output == Y.Output {
            Publishers.Merge4(a, b, z, y)
        }

        public func merge<Z, Y, X>(with z: Z, _ y: Y, _ x: X) -> Publishers.Merge5<A, B, Z, Y, X>
        where Z: Publisher, Y: Publisher, X: Publisher, B.Failure == Z.Failure, B.Output == Z.Output, Z.Failure == Y.Failure, Z.Output == Y.Output, Y.Failure == X.Failure, Y.Output == X.Output {
            Publishers.Merge5(a, b, z, y, x)
        }

        public func merge<Z, Y, X, W>(with z: Z, _ y: Y, _ x: X, _ w: W) -> Publishers.Merge6<A, B, Z, Y, X, W>
        where Z: Publisher, Y: Publisher, X: Publisher, W: Publisher, B.Failure == Z.Failure, B.Output == Z.Output, Z.Failure == Y.Failure, Z.Output == Y.Output, Y.Failure == X.Failure, Y.Output == X.Output, X.Failure == W.Failure, X.Output == W.Output {
            Publishers.Merge6(a, b, z, y, x, w)
        }

        public func merge<Z, Y, X, W, V>(with z: Z, _ y: Y, _ x: X, _ w: W, _ v: V) -> Publishers.Merge7<A, B, Z, Y, X, W, V>
        where Z: Publisher, Y: Publisher, X: Publisher, W: Publisher, V: Publisher, B.Failure == Z.Failure, B.Output == Z.Output, Z.Failure == Y.Failure, Z.Output == Y.Output, Y.Failure == X.Failure, Y.Output == X.Output, X.Failure == W.Failure, X.Output == W.Output, W.Failure == V.Failure, W.Output == V.Output {
            Publishers.Merge7(a, b, z, y, x, w, v)
        }

        public func merge<Z, Y, X, W, V, U>(with z: Z, _ y: Y, _ x: X, _ w: W, _ v: V, _ u: U) -> Publishers.Merge8<A, B, Z, Y, X, W, V, U>
        where Z: Publisher, Y: Publisher, X: Publisher, W: Publisher, V: Publisher, U: Publisher, B.Failure == Z.Failure, B.Output == Z.Output, Z.Failure == Y.Failure, Z.Output == Y.Output, Y.Failure == X.Failure, Y.Output == X.Output, X.Failure == W.Failure, X.Output == W.Output, W.Failure == V.Failure, W.Output == V.Output, V.Failure == U.Failure, V.Output == U.Output {
            Publishers.Merge8(a, b, z, y, x, w, v, u)
        }
    }

    public struct Merge3<A, B, C>: Publisher
    where A: Publisher, B: Publisher, C: Publisher, A.Failure == B.Failure, A.Output == B.Output, B.Failure == C.Failure, B.Output == C.Output {
        public typealias Output = A.Output
        public typealias Failure = A.Failure

        public let a: A
        public let b: B
        public let c: C

        public init(_ a: A, _ b: B, _ c: C) {
            self.a = a
            self.b = b
            self.c = c
        }

        public func receive<S>(subscriber: S) where S: Subscriber, C.Failure == S.Failure, C.Output == S.Input {
            MergeCore.merge("Merge", subscriber) { core in
                core.add(a)
                core.add(b)
                core.add(c)
            }
        }

        public func merge<P>(with other: P) -> Publishers.Merge4<A, B, C, P>
        where P: Publisher, C.Failure == P.Failure, C.Output == P.Output {
            Publishers.Merge4(a, b, c, other)
        }

        public func merge<Z, Y>(with z: Z, _ y: Y) -> Publishers.Merge5<A, B, C, Z, Y>
        where Z: Publisher, Y: Publisher, C.Failure == Z.Failure, C.Output == Z.Output, Z.Failure == Y.Failure, Z.Output == Y.Output {
            Publishers.Merge5(a, b, c, z, y)
        }

        public func merge<Z, Y, X>(with z: Z, _ y: Y, _ x: X) -> Publishers.Merge6<A, B, C, Z, Y, X>
        where Z: Publisher, Y: Publisher, X: Publisher, C.Failure == Z.Failure, C.Output == Z.Output, Z.Failure == Y.Failure, Z.Output == Y.Output, Y.Failure == X.Failure, Y.Output == X.Output {
            Publishers.Merge6(a, b, c, z, y, x)
        }

        public func merge<Z, Y, X, W>(with z: Z, _ y: Y, _ x: X, _ w: W) -> Publishers.Merge7<A, B, C, Z, Y, X, W>
        where Z: Publisher, Y: Publisher, X: Publisher, W: Publisher, C.Failure == Z.Failure, C.Output == Z.Output, Z.Failure == Y.Failure, Z.Output == Y.Output, Y.Failure == X.Failure, Y.Output == X.Output, X.Failure == W.Failure, X.Output == W.Output {
            Publishers.Merge7(a, b, c, z, y, x, w)
        }

        public func merge<Z, Y, X, W, V>(with z: Z, _ y: Y, _ x: X, _ w: W, _ v: V) -> Publishers.Merge8<A, B, C, Z, Y, X, W, V>
        where Z: Publisher, Y: Publisher, X: Publisher, W: Publisher, V: Publisher, C.Failure == Z.Failure, C.Output == Z.Output, Z.Failure == Y.Failure, Z.Output == Y.Output, Y.Failure == X.Failure, Y.Output == X.Output, X.Failure == W.Failure, X.Output == W.Output, W.Failure == V.Failure, W.Output == V.Output {
            Publishers.Merge8(a, b, c, z, y, x, w, v)
        }
    }

    public struct Merge4<A, B, C, D>: Publisher
    where A: Publisher, B: Publisher, C: Publisher, D: Publisher, A.Failure == B.Failure, A.Output == B.Output, B.Failure == C.Failure, B.Output == C.Output, C.Failure == D.Failure, C.Output == D.Output {
        public typealias Output = A.Output
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

        public func receive<S>(subscriber: S) where S: Subscriber, D.Failure == S.Failure, D.Output == S.Input {
            MergeCore.merge("Merge", subscriber) { core in
                core.add(a)
                core.add(b)
                core.add(c)
                core.add(d)
            }
        }

        public func merge<P>(with other: P) -> Publishers.Merge5<A, B, C, D, P>
        where P: Publisher, D.Failure == P.Failure, D.Output == P.Output {
            Publishers.Merge5(a, b, c, d, other)
        }

        public func merge<Z, Y>(with z: Z, _ y: Y) -> Publishers.Merge6<A, B, C, D, Z, Y>
        where Z: Publisher, Y: Publisher, D.Failure == Z.Failure, D.Output == Z.Output, Z.Failure == Y.Failure, Z.Output == Y.Output {
            Publishers.Merge6(a, b, c, d, z, y)
        }

        public func merge<Z, Y, X>(with z: Z, _ y: Y, _ x: X) -> Publishers.Merge7<A, B, C, D, Z, Y, X>
        where Z: Publisher, Y: Publisher, X: Publisher, D.Failure == Z.Failure, D.Output == Z.Output, Z.Failure == Y.Failure, Z.Output == Y.Output, Y.Failure == X.Failure, Y.Output == X.Output {
            Publishers.Merge7(a, b, c, d, z, y, x)
        }

        public func merge<Z, Y, X, W>(with z: Z, _ y: Y, _ x: X, _ w: W) -> Publishers.Merge8<A, B, C, D, Z, Y, X, W>
        where Z: Publisher, Y: Publisher, X: Publisher, W: Publisher, D.Failure == Z.Failure, D.Output == Z.Output, Z.Failure == Y.Failure, Z.Output == Y.Output, Y.Failure == X.Failure, Y.Output == X.Output, X.Failure == W.Failure, X.Output == W.Output {
            Publishers.Merge8(a, b, c, d, z, y, x, w)
        }
    }

    public struct Merge5<A, B, C, D, E>: Publisher
    where A: Publisher, B: Publisher, C: Publisher, D: Publisher, E: Publisher, A.Failure == B.Failure, A.Output == B.Output, B.Failure == C.Failure, B.Output == C.Output, C.Failure == D.Failure, C.Output == D.Output, D.Failure == E.Failure, D.Output == E.Output {
        public typealias Output = A.Output
        public typealias Failure = A.Failure

        public let a: A
        public let b: B
        public let c: C
        public let d: D
        public let e: E

        public init(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E) {
            self.a = a
            self.b = b
            self.c = c
            self.d = d
            self.e = e
        }

        public func receive<S>(subscriber: S) where S: Subscriber, E.Failure == S.Failure, E.Output == S.Input {
            MergeCore.merge("Merge", subscriber) { core in
                core.add(a)
                core.add(b)
                core.add(c)
                core.add(d)
                core.add(e)
            }
        }

        public func merge<P>(with other: P) -> Publishers.Merge6<A, B, C, D, E, P>
        where P: Publisher, E.Failure == P.Failure, E.Output == P.Output {
            Publishers.Merge6(a, b, c, d, e, other)
        }

        public func merge<Z, Y>(with z: Z, _ y: Y) -> Publishers.Merge7<A, B, C, D, E, Z, Y>
        where Z: Publisher, Y: Publisher, E.Failure == Z.Failure, E.Output == Z.Output, Z.Failure == Y.Failure, Z.Output == Y.Output {
            Publishers.Merge7(a, b, c, d, e, z, y)
        }

        public func merge<Z, Y, X>(with z: Z, _ y: Y, _ x: X) -> Publishers.Merge8<A, B, C, D, E, Z, Y, X>
        where Z: Publisher, Y: Publisher, X: Publisher, E.Failure == Z.Failure, E.Output == Z.Output, Z.Failure == Y.Failure, Z.Output == Y.Output, Y.Failure == X.Failure, Y.Output == X.Output {
            Publishers.Merge8(a, b, c, d, e, z, y, x)
        }
    }

    public struct Merge6<A, B, C, D, E, F>: Publisher
    where A: Publisher, B: Publisher, C: Publisher, D: Publisher, E: Publisher, F: Publisher, A.Failure == B.Failure, A.Output == B.Output, B.Failure == C.Failure, B.Output == C.Output, C.Failure == D.Failure, C.Output == D.Output, D.Failure == E.Failure, D.Output == E.Output, E.Failure == F.Failure, E.Output == F.Output {
        public typealias Output = A.Output
        public typealias Failure = A.Failure

        public let a: A
        public let b: B
        public let c: C
        public let d: D
        public let e: E
        public let f: F

        public init(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F) {
            self.a = a
            self.b = b
            self.c = c
            self.d = d
            self.e = e
            self.f = f
        }

        public func receive<S>(subscriber: S) where S: Subscriber, F.Failure == S.Failure, F.Output == S.Input {
            MergeCore.merge("Merge", subscriber) { core in
                core.add(a)
                core.add(b)
                core.add(c)
                core.add(d)
                core.add(e)
                core.add(f)
            }
        }

        public func merge<P>(with other: P) -> Publishers.Merge7<A, B, C, D, E, F, P>
        where P: Publisher, F.Failure == P.Failure, F.Output == P.Output {
            Publishers.Merge7(a, b, c, d, e, f, other)
        }

        public func merge<Z, Y>(with z: Z, _ y: Y) -> Publishers.Merge8<A, B, C, D, E, F, Z, Y>
        where Z: Publisher, Y: Publisher, F.Failure == Z.Failure, F.Output == Z.Output, Z.Failure == Y.Failure, Z.Output == Y.Output {
            Publishers.Merge8(a, b, c, d, e, f, z, y)
        }
    }

    public struct Merge7<A, B, C, D, E, F, G>: Publisher
    where A: Publisher, B: Publisher, C: Publisher, D: Publisher, E: Publisher, F: Publisher, G: Publisher, A.Failure == B.Failure, A.Output == B.Output, B.Failure == C.Failure, B.Output == C.Output, C.Failure == D.Failure, C.Output == D.Output, D.Failure == E.Failure, D.Output == E.Output, E.Failure == F.Failure, E.Output == F.Output, F.Failure == G.Failure, F.Output == G.Output {
        public typealias Output = A.Output
        public typealias Failure = A.Failure

        public let a: A
        public let b: B
        public let c: C
        public let d: D
        public let e: E
        public let f: F
        public let g: G

        public init(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G) {
            self.a = a
            self.b = b
            self.c = c
            self.d = d
            self.e = e
            self.f = f
            self.g = g
        }

        public func receive<S>(subscriber: S) where S: Subscriber, G.Failure == S.Failure, G.Output == S.Input {
            MergeCore.merge("Merge", subscriber) { core in
                core.add(a)
                core.add(b)
                core.add(c)
                core.add(d)
                core.add(e)
                core.add(f)
                core.add(g)
            }
        }

        public func merge<P>(with other: P) -> Publishers.Merge8<A, B, C, D, E, F, G, P>
        where P: Publisher, G.Failure == P.Failure, G.Output == P.Output {
            Publishers.Merge8(a, b, c, d, e, f, g, other)
        }
    }

    public struct Merge8<A, B, C, D, E, F, G, H>: Publisher
    where A: Publisher, B: Publisher, C: Publisher, D: Publisher, E: Publisher, F: Publisher, G: Publisher, H: Publisher, A.Failure == B.Failure, A.Output == B.Output, B.Failure == C.Failure, B.Output == C.Output, C.Failure == D.Failure, C.Output == D.Output, D.Failure == E.Failure, D.Output == E.Output, E.Failure == F.Failure, E.Output == F.Output, F.Failure == G.Failure, F.Output == G.Output, G.Failure == H.Failure, G.Output == H.Output {
        public typealias Output = A.Output
        public typealias Failure = A.Failure

        public let a: A
        public let b: B
        public let c: C
        public let d: D
        public let e: E
        public let f: F
        public let g: G
        public let h: H

        public init(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G, _ h: H) {
            self.a = a
            self.b = b
            self.c = c
            self.d = d
            self.e = e
            self.f = f
            self.g = g
            self.h = h
        }

        public func receive<S>(subscriber: S) where S: Subscriber, H.Failure == S.Failure, H.Output == S.Input {
            MergeCore.merge("Merge", subscriber) { core in
                core.add(a)
                core.add(b)
                core.add(c)
                core.add(d)
                core.add(e)
                core.add(f)
                core.add(g)
                core.add(h)
            }
        }
    }
}

extension Publishers.Merge: Equatable where A: Equatable, B: Equatable {
    public static func == (lhs: Publishers.Merge<A, B>, rhs: Publishers.Merge<A, B>) -> Bool {
        lhs.a == rhs.a && lhs.b == rhs.b
    }
}

extension Publishers.Merge3: Equatable where A: Equatable, B: Equatable, C: Equatable {
    public static func == (lhs: Publishers.Merge3<A, B, C>, rhs: Publishers.Merge3<A, B, C>) -> Bool {
        lhs.a == rhs.a && lhs.b == rhs.b && lhs.c == rhs.c
    }
}

extension Publishers.Merge4: Equatable where A: Equatable, B: Equatable, C: Equatable, D: Equatable {
    public static func == (lhs: Publishers.Merge4<A, B, C, D>, rhs: Publishers.Merge4<A, B, C, D>) -> Bool {
        lhs.a == rhs.a && lhs.b == rhs.b && lhs.c == rhs.c && lhs.d == rhs.d
    }
}

extension Publishers.Merge5: Equatable where A: Equatable, B: Equatable, C: Equatable, D: Equatable, E: Equatable {
    public static func == (lhs: Publishers.Merge5<A, B, C, D, E>, rhs: Publishers.Merge5<A, B, C, D, E>) -> Bool {
        lhs.a == rhs.a && lhs.b == rhs.b && lhs.c == rhs.c && lhs.d == rhs.d && lhs.e == rhs.e
    }
}

extension Publishers.Merge6: Equatable where A: Equatable, B: Equatable, C: Equatable, D: Equatable, E: Equatable, F: Equatable {
    public static func == (lhs: Publishers.Merge6<A, B, C, D, E, F>, rhs: Publishers.Merge6<A, B, C, D, E, F>) -> Bool {
        lhs.a == rhs.a && lhs.b == rhs.b && lhs.c == rhs.c && lhs.d == rhs.d && lhs.e == rhs.e && lhs.f == rhs.f
    }
}

extension Publishers.Merge7: Equatable where A: Equatable, B: Equatable, C: Equatable, D: Equatable, E: Equatable, F: Equatable, G: Equatable {
    public static func == (lhs: Publishers.Merge7<A, B, C, D, E, F, G>, rhs: Publishers.Merge7<A, B, C, D, E, F, G>) -> Bool {
        lhs.a == rhs.a && lhs.b == rhs.b && lhs.c == rhs.c && lhs.d == rhs.d && lhs.e == rhs.e && lhs.f == rhs.f && lhs.g == rhs.g
    }
}

extension Publishers.Merge8: Equatable where A: Equatable, B: Equatable, C: Equatable, D: Equatable, E: Equatable, F: Equatable, G: Equatable, H: Equatable {
    public static func == (lhs: Publishers.Merge8<A, B, C, D, E, F, G, H>, rhs: Publishers.Merge8<A, B, C, D, E, F, G, H>) -> Bool {
        lhs.a == rhs.a && lhs.b == rhs.b && lhs.c == rhs.c && lhs.d == rhs.d && lhs.e == rhs.e && lhs.f == rhs.f && lhs.g == rhs.g && lhs.h == rhs.h
    }
}

extension Publishers {
    public struct MergeMany<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let publishers: [Upstream]

        public init(_ upstream: Upstream...) {
            publishers = upstream
        }

        public init<S>(_ upstream: S) where Upstream == S.Element, S: Swift.Sequence {
            publishers = Array(upstream)
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            MergeCore.merge("Merge", subscriber) { core in
                for publisher in publishers { core.add(publisher) }
            }
        }

        public func merge(with other: Upstream) -> Publishers.MergeMany<Upstream> {
            Publishers.MergeMany(publishers + [other])
        }
    }
}

extension Publishers.MergeMany: Equatable where Upstream: Equatable {
    public static func == (lhs: Publishers.MergeMany<Upstream>, rhs: Publishers.MergeMany<Upstream>) -> Bool {
        lhs.publishers == rhs.publishers
    }
}


// MARK: - flatMap

extension Publisher {
    public func flatMap<T, P>(maxPublishers: Subscribers.Demand = .unlimited, _ transform: @escaping (Self.Output) -> P)
        -> Publishers.FlatMap<P, Self> where T == P.Output, P: Publisher, Self.Failure == P.Failure {
        Publishers.FlatMap(upstream: self, maxPublishers: maxPublishers, transform: transform)
    }

    public func flatMap<P>(maxPublishers: Subscribers.Demand = .unlimited, _ transform: @escaping (Self.Output) -> P)
        -> Publishers.FlatMap<Publishers.SetFailureType<P, Self.Failure>, Self> where P: Publisher, P.Failure == Never {
        Publishers.FlatMap(upstream: self, maxPublishers: maxPublishers) { transform($0).setFailureType(to: Failure.self) }
    }
}

extension Publisher where Self.Failure == Never {
    public func flatMap<P>(maxPublishers: Subscribers.Demand = .unlimited, _ transform: @escaping (Self.Output) -> P)
        -> Publishers.FlatMap<P, Publishers.SetFailureType<Self, P.Failure>> where P: Publisher {
        Publishers.FlatMap(upstream: setFailureType(to: P.Failure.self), maxPublishers: maxPublishers, transform: transform)
    }

    public func flatMap<P>(maxPublishers: Subscribers.Demand = .unlimited, _ transform: @escaping (Self.Output) -> P)
        -> Publishers.FlatMap<P, Self> where P: Publisher, P.Failure == Never {
        Publishers.FlatMap(upstream: self, maxPublishers: maxPublishers, transform: transform)
    }
}

extension Publishers {
    /// A publisher made from each upstream value, their values merged.
    public struct FlatMap<NewPublisher, Upstream>: Publisher
    where NewPublisher: Publisher, Upstream: Publisher, NewPublisher.Failure == Upstream.Failure {
        public typealias Output = NewPublisher.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let maxPublishers: Subscribers.Demand
        public let transform: (Upstream.Output) -> NewPublisher

        public init(upstream: Upstream, maxPublishers: Subscribers.Demand,
                    transform: @escaping (Upstream.Output) -> NewPublisher) {
            self.upstream = upstream
            self.maxPublishers = maxPublishers
            self.transform = transform
        }

        public func receive<S>(subscriber: S) where S: Subscriber, NewPublisher.Output == S.Input,
            Upstream.Failure == S.Failure {
            let core = MergeCore("FlatMap", downstream: subscriber)
            let (maxPublishers, transform) = (self.maxPublishers, self.transform)
            let outer = ClosureSubscriber<Upstream.Output, Upstream.Failure>(
                onSubscribe: { subscription in
                    core.setOuter(subscription)
                    subscription.request(maxPublishers)
                },
                onValue: { value in
                    core.add(transform(value))
                    return .none
                },
                onCompletion: { completion in
                    switch completion {
                    case .finished: core.close()
                    case .failure(let error): core.fail(error)
                    }
                })
            if maxPublishers != .unlimited {
                // A child done: room for another.
                core.childFinished = { [weak core] in core?.requestOuter(.max(1)) }
            }
            core.start()
            upstream.subscribe(outer)
        }
    }
}
