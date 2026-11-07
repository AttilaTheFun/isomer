// Sharing one upstream subscription: multicast (through a subject, once
// connected), makeConnectable, autoconnect and share.

public protocol ConnectablePublisher<Output, Failure>: Publisher {
    func connect() -> any Cancellable
}

extension ConnectablePublisher {
    public func autoconnect() -> Publishers.Autoconnect<Self> {
        Publishers.Autoconnect(upstream: self)
    }
}

extension Publisher {
    public func multicast<S>(_ createSubject: @escaping () -> S) -> Publishers.Multicast<Self, S>
    where S: Subject, Self.Failure == S.Failure, Self.Output == S.Output {
        Publishers.Multicast(upstream: self, createSubject: createSubject)
    }

    public func multicast<S>(subject: S) -> Publishers.Multicast<Self, S>
    where S: Subject, Self.Failure == S.Failure, Self.Output == S.Output {
        Publishers.Multicast(upstream: self) { subject }
    }

    public func share() -> Publishers.Share<Self> {
        Publishers.Share(upstream: self)
    }
}

extension Publisher where Self.Failure == Never {
    public func makeConnectable() -> Publishers.MakeConnectable<Self> {
        Publishers.MakeConnectable(upstream: self)
    }
}

extension Publishers {
    /// Subscribers attach to one subject (made at the first use); upstream
    /// feeds it once connected.
    final public class Multicast<Upstream, SubjectType>: ConnectablePublisher
    where Upstream: Publisher, SubjectType: Subject, Upstream.Failure == SubjectType.Failure,
        Upstream.Output == SubjectType.Output {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        final public let upstream: Upstream
        final public let createSubject: () -> SubjectType

        private let lock = Lock()
        private var made: SubjectType?

        public init(upstream: Upstream, createSubject: @escaping () -> SubjectType) {
            self.upstream = upstream
            self.createSubject = createSubject
        }

        private var subject: SubjectType {
            lock.withLock {
                if let made { return made }
                let subject = createSubject()
                made = subject
                return subject
            }
        }

        final public func receive<S>(subscriber: S) where S: Subscriber, SubjectType.Failure == S.Failure,
            SubjectType.Output == S.Input {
            subject.subscribe(subscriber)
        }

        final public func connect() -> any Cancellable {
            upstream.subscribe(subject)
        }
    }

    public struct MakeConnectable<Upstream>: ConnectablePublisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        private let inner: Multicast<Upstream, PassthroughSubject<Upstream.Output, Upstream.Failure>>

        public init(upstream: Upstream) {
            inner = Multicast(upstream: upstream) { PassthroughSubject() }
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            inner.receive(subscriber: subscriber)
        }

        public func connect() -> any Cancellable {
            inner.connect()
        }
    }

    /// Connects when the first subscriber comes, and disconnects when the
    /// last goes (so a later one connects again).
    public class Autoconnect<Upstream>: Publisher where Upstream: ConnectablePublisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        final public let upstream: Upstream

        private let lock = Lock()
        private var connection: (any Cancellable)?
        private var subscribers = 0

        public init(upstream: Upstream) {
            self.upstream = upstream
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            let first = lock.withLock { () -> Bool in
                subscribers += 1
                return subscribers == 1 && connection == nil
            }
            upstream.subscribe(AutoconnectInner(downstream: subscriber, parent: self))
            if first {
                let made = upstream.connect()
                // The last subscriber may already be gone (a synchronous
                // upstream completes them during connect).
                let keep = lock.withLock { () -> Bool in
                    guard subscribers > 0 else { return false }
                    connection = made
                    return true
                }
                if !keep { made.cancel() }
            }
        }

        func subscriberLeft() {
            let connection = lock.withLock { () -> (any Cancellable)? in
                subscribers -= 1
                guard subscribers == 0 else { return nil }
                defer { self.connection = nil }
                return self.connection
            }
            connection?.cancel()
        }
    }

    /// One upstream subscription, shared by every subscriber while any
    /// remains: multicast through a PassthroughSubject, autoconnected.
    /// Equal by identity.
    final public class Share<Upstream>: Publisher, Equatable where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        final public let upstream: Upstream
        private let inner: Autoconnect<Multicast<Upstream, PassthroughSubject<Upstream.Output, Upstream.Failure>>>

        public init(upstream: Upstream) {
            self.upstream = upstream
            inner = Autoconnect(upstream: Multicast(upstream: upstream) { PassthroughSubject() })
        }

        final public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure,
            Upstream.Output == S.Input {
            inner.receive(subscriber: subscriber)
        }

        public static func == (lhs: Publishers.Share<Upstream>, rhs: Publishers.Share<Upstream>) -> Bool {
            lhs === rhs
        }
    }
}

/// Tells its Autoconnect when its subscriber has gone (cancelled or completed).
final class AutoconnectInner<Downstream: Subscriber, Upstream: ConnectablePublisher>: Subscriber, Subscription
where Upstream.Output == Downstream.Input, Upstream.Failure == Downstream.Failure {
    typealias Input = Downstream.Input
    typealias Failure = Downstream.Failure

    private let lock = Lock()
    private var status = SubscriptionStatus.awaiting
    private let downstream: Downstream
    private var parent: Publishers.Autoconnect<Upstream>?

    init(downstream: Downstream, parent: Publishers.Autoconnect<Upstream>) {
        self.downstream = downstream
        self.parent = parent
    }

    private func leave() {
        let parent = lock.withLock { () -> Publishers.Autoconnect<Upstream>? in
            defer { self.parent = nil }
            return self.parent
        }
        parent?.subscriberLeft()
    }

    func receive(subscription: any Subscription) {
        lock.lock()
        guard case .awaiting = status else {
            lock.unlock()
            subscription.cancel()
            return
        }
        status = .subscribed(subscription)
        lock.unlock()
        downstream.receive(subscription: self)
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        downstream.receive(input)
    }

    func receive(completion: Subscribers.Completion<Failure>) {
        lock.withLock { status = .terminal }
        downstream.receive(completion: completion)
        leave()
    }

    func request(_ demand: Subscribers.Demand) {
        let upstream = lock.withLock { () -> (any Subscription)? in
            if case .subscribed(let upstream) = status { return upstream }
            return nil
        }
        upstream?.request(demand)
    }

    func cancel() {
        let upstream = lock.withLock { () -> (any Subscription)? in
            defer { status = .terminal }
            if case .subscribed(let upstream) = status { return upstream }
            return nil
        }
        upstream?.cancel()
        leave()
    }
}
