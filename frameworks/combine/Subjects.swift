// Subjects: publishers code sends values into. PassthroughSubject hands
// each value to the subscribers that have asked for one (others miss it);
// CurrentValueSubject keeps the latest and gives it to each subscriber when
// it asks, then every later one. @Published's publisher and
// ObservableObjectPublisher are made the same way (SubjectCore).

public protocol Subject<Output, Failure>: AnyObject, Publisher {
    func send(_ value: Self.Output)
    func send(completion: Subscribers.Completion<Self.Failure>)
    func send(subscription: any Subscription)
}

extension Subject where Self.Output == () {
    public func send() {
        send(())
    }
}

/// The subscribers of a subject, its completion once it has one, and the
/// upstream subscriptions feeding it.
final class SubjectCore<Output, Failure: Error> {
    private let lock = Lock()
    private var conduits: [Conduit<Output, Failure>] = []
    private var completion: Subscribers.Completion<Failure>?
    private var upstreams: [any Subscription] = []
    /// A current-value subject: what a subscriber is given when it asks.
    private var currentValue: Output?
    let holdsCurrentValue: Bool

    init(current: Output? = nil) {
        currentValue = current
        holdsCurrentValue = current != nil
    }

    var current: Output? {
        lock.withLock { currentValue }
    }

    func setCurrent(_ value: Output) {
        lock.withLock { currentValue = value }
    }

    var isCompleted: Bool { lock.withLock { completion != nil } }

    func attach<S: Subscriber>(_ subscriber: S) where S.Input == Output, S.Failure == Failure {
        lock.lock()
        if let completion {
            lock.unlock()
            subscriber.receive(subscription: Subscriptions.empty)
            subscriber.receive(completion: completion)
            return
        }
        let conduit = Conduit(core: self, downstream: AnySubscriber(subscriber), owesCurrent: holdsCurrentValue)
        conduits.append(conduit)
        lock.unlock()
        subscriber.receive(subscription: conduit)
    }

    func detach(_ conduit: Conduit<Output, Failure>) {
        lock.withLock { conduits.removeAll { $0 === conduit } }
    }

    /// Offers `value` to every subscriber.
    func broadcast(_ value: Output) {
        let current = lock.withLock { completion == nil ? conduits : [] }
        for conduit in current { conduit.offer(value) }
    }

    func complete(_ completion: Subscribers.Completion<Failure>) {
        let current = lock.withLock { () -> [Conduit<Output, Failure>] in
            guard self.completion == nil else { return [] }
            self.completion = completion
            defer {
                conduits = []
                upstreams = []
            }
            return conduits
        }
        for conduit in current { conduit.finish(completion) }
    }

    /// A subject asks its upstreams for everything (Publisher.subscribe(_:)
    /// with a subject).
    func add(upstream subscription: any Subscription) {
        let accepted = lock.withLock { () -> Bool in
            guard completion == nil else { return false }
            upstreams.append(subscription)
            return true
        }
        if accepted {
            subscription.request(.unlimited)
        } else {
            subscription.cancel()
        }
    }
}

/// One subscriber's subscription to a subject: its demand, and (for a
/// current-value subject) whether it is still owed the current value.
final class Conduit<Output, Failure: Error>: Subscription, CustomStringConvertible {
    private let lock = Lock()
    // Holds deliveries to one subscriber in order, letting the subscriber
    // send or request from inside one.
    private let deliveryLock = RecursiveLock.recursive()
    private var core: SubjectCore<Output, Failure>?
    private var downstream: AnySubscriber<Output, Failure>?
    private var demand = Subscribers.Demand.none
    private var owesCurrent: Bool

    init(core: SubjectCore<Output, Failure>, downstream: AnySubscriber<Output, Failure>, owesCurrent: Bool) {
        self.core = core
        self.downstream = downstream
        self.owesCurrent = owesCurrent
    }

    var description: String { "Conduit" }

    func offer(_ value: Output) {
        lock.lock()
        guard let downstream else {
            lock.unlock()
            return
        }
        guard demand > 0 else {
            // Missed; a current-value subject's subscriber gets the latest
            // when it next asks.
            if core?.holdsCurrentValue == true { owesCurrent = true }
            lock.unlock()
            return
        }
        demand.consumeOne()
        owesCurrent = false
        lock.unlock()
        deliver(value, to: downstream)
    }

    private func deliver(_ value: Output, to downstream: AnySubscriber<Output, Failure>) {
        let more = deliveryLock.withLock { downstream.receive(value) }
        guard more > 0 else { return }
        request(more)
    }

    func finish(_ completion: Subscribers.Completion<Failure>) {
        let downstream = lock.withLock { () -> AnySubscriber<Output, Failure>? in
            defer {
                self.downstream = nil
                core = nil
            }
            return self.downstream
        }
        guard let downstream else { return }
        deliveryLock.withLock { downstream.receive(completion: completion) }
    }

    func request(_ demand: Subscribers.Demand) {
        precondition(demand > 0, "A request must be for at least one value")
        lock.lock()
        self.demand += demand
        guard owesCurrent, let downstream, let core, let current = core.current else {
            lock.unlock()
            return
        }
        owesCurrent = false
        self.demand.consumeOne()
        lock.unlock()
        deliver(current, to: downstream)
    }

    func cancel() {
        let core = lock.withLock { () -> SubjectCore<Output, Failure>? in
            defer {
                downstream = nil
                self.core = nil
            }
            return self.core
        }
        core?.detach(self)
    }
}

final public class PassthroughSubject<Output, Failure>: Subject where Failure: Error {
    private let core = SubjectCore<Output, Failure>()

    public init() {}

    final public func send(subscription: any Subscription) {
        core.add(upstream: subscription)
    }

    final public func receive<S>(subscriber: __owned S) where Output == S.Input, Failure == S.Failure, S: Subscriber {
        core.attach(subscriber)
    }

    final public func send(_ input: Output) {
        core.broadcast(input)
    }

    final public func send(completion: Subscribers.Completion<Failure>) {
        core.complete(completion)
    }
}

final public class CurrentValueSubject<Output, Failure>: Subject where Failure: Error {
    private let core: SubjectCore<Output, Failure>

    /// Setting it sends the new value.
    final public var value: Output {
        get { core.current! }
        set { send(newValue) }
    }

    public init(_ value: Output) {
        core = SubjectCore(current: value)
    }

    final public func send(subscription: any Subscription) {
        core.add(upstream: subscription)
    }

    final public func receive<S>(subscriber: S) where Output == S.Input, Failure == S.Failure, S: Subscriber {
        core.attach(subscriber)
    }

    final public func send(_ input: Output) {
        // A completed subject keeps its value.
        guard !core.isCompleted else { return }
        core.setCurrent(input)
        core.broadcast(input)
    }

    final public func send(completion: Subscribers.Completion<Failure>) {
        core.complete(completion)
    }
}
