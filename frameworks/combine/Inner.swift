// The subscriptions the operators are made of. Each operator's publisher
// is a value (its upstream and its closures); subscribing makes one of
// these, which stands between the upstream subscription and the downstream
// subscriber, and holds what that one subscription needs (a count, the
// last value, an accumulator) in the closures it was made with.
//
// - OperatorInner: one value in, at most one out (map, filter, first,
//   prefix, scan, ...). Demand passes through: a value dropped asks
//   upstream for one more, as Apple's do.
// - ReducerInner: one value out at the end (reduce, collect, count, last,
//   min, contains, ...). It asks upstream for everything and holds its
//   result until downstream asks.
// - Relay: one upstream at a time, switched to another as the operator
//   decides (append, catch, retry, switchToLatest). Demand not yet met
//   carries over to the next.

/// What an OperatorInner does with a value from upstream.
enum Step<Output, Failure: Error> {
    case send(Output)
    /// Drop it (and ask upstream for another).
    case skip
    case sendAndFinish(Output)
    case finish
    case fail(Failure)
}

/// What an OperatorInner sends when its upstream completes: a last value
/// (collect(_:)'s partial batch, replaceError's and replaceEmpty's value),
/// if any, and the completion.
typealias Ending<Output, Failure: Error> = (last: Output?, completion: Subscribers.Completion<Failure>)

final class OperatorInner<Input, UpstreamFailure: Error, Downstream: Subscriber>: Subscriber, Subscription,
    CustomStringConvertible {
    typealias Failure = UpstreamFailure

    let description: String
    private let lock = Lock()
    private var status = SubscriptionStatus.awaiting
    /// What downstream has asked for and not been sent: a last value waits
    /// for it.
    private var demand = Subscribers.Demand.none
    private var ending: Ending<Downstream.Input, Downstream.Failure>?
    private let downstream: Downstream
    private let onValue: (Input) -> Step<Downstream.Input, Downstream.Failure>
    private let onCompletion: (Subscribers.Completion<UpstreamFailure>) -> Ending<Downstream.Input, Downstream.Failure>

    init(_ name: String, downstream: Downstream,
         onValue: @escaping (Input) -> Step<Downstream.Input, Downstream.Failure>,
         onCompletion: @escaping (Subscribers.Completion<UpstreamFailure>) -> Ending<Downstream.Input, Downstream.Failure>) {
        description = name
        self.downstream = downstream
        self.onValue = onValue
        self.onCompletion = onCompletion
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
        guard lock.withLock({ if case .subscribed = status { return true } else { return false } }) else {
            return .none
        }
        switch onValue(input) {
        case .send(let output):
            lock.withLock { demand.consumeOne() }
            let more = downstream.receive(output)
            lock.withLock { demand += more }
            return more
        case .skip:
            return .max(1)
        case .sendAndFinish(let output):
            guard let upstream = terminate() else { return .none }
            upstream.cancel()
            _ = downstream.receive(output)
            downstream.receive(completion: .finished)
            return .none
        case .finish:
            guard let upstream = terminate() else { return .none }
            upstream.cancel()
            downstream.receive(completion: .finished)
            return .none
        case .fail(let error):
            guard let upstream = terminate() else { return .none }
            upstream.cancel()
            downstream.receive(completion: .failure(error))
            return .none
        }
    }

    func receive(completion: Subscribers.Completion<UpstreamFailure>) {
        guard terminate() != nil else { return }
        let ending = onCompletion(completion)
        guard ending.last != nil else {
            downstream.receive(completion: ending.completion)
            return
        }
        // A last value goes when downstream has asked for one.
        let now = lock.withLock { () -> Bool in
            if demand > 0 { return true }
            self.ending = ending
            return false
        }
        if now { end(ending) }
    }

    private func end(_ ending: Ending<Downstream.Input, Downstream.Failure>) {
        if let last = ending.last { _ = downstream.receive(last) }
        downstream.receive(completion: ending.completion)
    }

    func request(_ demand: Subscribers.Demand) {
        lock.lock()
        self.demand += demand
        if let ending {
            self.ending = nil
            lock.unlock()
            end(ending)
            return
        }
        var upstream: (any Subscription)?
        if case .subscribed(let subscription) = status { upstream = subscription }
        lock.unlock()
        upstream?.request(demand)
    }

    func cancel() {
        lock.withLock { ending = nil }
        terminate()?.cancel()
    }

    /// Ends the subscription, handing back the upstream one (nil when it
    /// had ended already).
    @discardableResult
    private func terminate() -> (any Subscription)? {
        lock.withLock {
            guard case .subscribed(let upstream) = status else {
                status = .terminal
                return nil
            }
            status = .terminal
            return upstream
        }
    }
}

extension OperatorInner where UpstreamFailure == Downstream.Failure {
    /// An operator that passes its upstream's completion on as it is.
    convenience init(_ name: String, downstream: Downstream,
                     onValue: @escaping (Input) -> Step<Downstream.Input, Downstream.Failure>) {
        self.init(name, downstream: downstream, onValue: onValue, onCompletion: { (nil, $0) })
    }
}

extension OperatorInner where Downstream.Failure == any Error {
    /// A try- operator: what its closure throws fails the stream, and an
    /// upstream failure arrives as any Error.
    convenience init(trying name: String, downstream: Downstream,
                     onValue: @escaping (Input) throws -> Step<Downstream.Input, any Error>) {
        self.init(name, downstream: downstream, onValue: { value in
            do { return try onValue(value) } catch { return .fail(error) }
        }, onCompletion: { (nil, $0.eraseError) })
    }
}

/// What a ReducerInner does with a value from upstream.
enum ReduceStep<Failure: Error> {
    case `continue`
    /// The result is known: stop upstream and deliver it.
    case finish
    case fail(Failure)
}

final class ReducerInner<Input, UpstreamFailure: Error, Downstream: Subscriber>: Subscriber, Subscription,
    CustomStringConvertible {
    typealias Failure = UpstreamFailure

    let description: String
    private let lock = Lock()
    private var status = SubscriptionStatus.awaiting
    private var requested = false
    private var result: Downstream.Input?
    /// The result is in, waiting for downstream to ask.
    private var resultReady = false
    private var finished = false
    private let downstream: Downstream
    private let onValue: (Input) -> ReduceStep<Downstream.Failure>
    private let makeResult: () -> Downstream.Input?
    private let mapFailure: (UpstreamFailure) -> Downstream.Failure

    init(_ name: String, downstream: Downstream,
         onValue: @escaping (Input) -> ReduceStep<Downstream.Failure>,
         result: @escaping () -> Downstream.Input?,
         mapFailure: @escaping (UpstreamFailure) -> Downstream.Failure) {
        description = name
        self.downstream = downstream
        self.onValue = onValue
        makeResult = result
        self.mapFailure = mapFailure
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
        // Everything, whatever downstream asks for: the result waits for it.
        subscription.request(.unlimited)
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        guard lock.withLock({ if case .subscribed = status { return true } else { return false } }) else {
            return .none
        }
        switch onValue(input) {
        case .continue:
            break
        case .finish:
            let upstream = lock.withLock { () -> (any Subscription)? in
                guard case .subscribed(let upstream) = status else { return nil }
                status = .terminal
                return upstream
            }
            guard let upstream else { return .none }
            upstream.cancel()
            deliver()
        case .fail(let error):
            let upstream = lock.withLock { () -> (any Subscription)? in
                guard case .subscribed(let upstream) = status else { return nil }
                status = .terminal
                return upstream
            }
            guard let upstream else { return .none }
            upstream.cancel()
            downstream.receive(completion: .failure(error))
        }
        return .none
    }

    func receive(completion: Subscribers.Completion<UpstreamFailure>) {
        let wasSubscribed = lock.withLock { () -> Bool in
            defer { status = .terminal }
            if case .subscribed = status { return true }
            return false
        }
        guard wasSubscribed else { return }
        switch completion {
        case .finished:
            deliver()
        case .failure(let error):
            downstream.receive(completion: .failure(mapFailure(error)))
        }
    }

    /// Sends the result and finishes now if downstream has asked, or when
    /// it does.
    private func deliver() {
        let value = makeResult()
        let send = lock.withLock { () -> Bool in
            result = value
            resultReady = true
            if requested && !finished {
                finished = true
                return true
            }
            return false
        }
        if send { complete(with: value) }
    }

    private func complete(with value: Downstream.Input?) {
        if let value { _ = downstream.receive(value) }
        downstream.receive(completion: .finished)
    }

    func request(_ demand: Subscribers.Demand) {
        precondition(demand > 0, "A request must be for at least one value")
        lock.lock()
        requested = true
        guard resultReady && !finished else {
            lock.unlock()
            return
        }
        finished = true
        let value = result
        lock.unlock()
        complete(with: value)
    }

    func cancel() {
        let upstream = lock.withLock { () -> (any Subscription)? in
            defer {
                status = .terminal
                finished = true
            }
            if case .subscribed(let upstream) = status { return upstream }
            return nil
        }
        upstream?.cancel()
    }
}

extension ReducerInner where UpstreamFailure == Downstream.Failure {
    convenience init(_ name: String, downstream: Downstream,
                     onValue: @escaping (Input) -> ReduceStep<Downstream.Failure>,
                     result: @escaping () -> Downstream.Input?) {
        self.init(name, downstream: downstream, onValue: onValue, result: result, mapFailure: { $0 })
    }
}

/// One upstream at a time (see above). An operator gives downstream the
/// relay, then attaches its first source; each source's completion goes to
/// the closure it was attached with, which finishes the relay or attaches
/// the next.
final class Relay<Downstream: Subscriber>: Subscription, CustomStringConvertible {
    typealias Output = Downstream.Input
    typealias Failure = Downstream.Failure

    let description: String
    private let lock = Lock()
    private let downstreamLock = RecursiveLock.recursive()
    private let downstream: Downstream
    private var demand = Subscribers.Demand.none
    private var generation = 0
    private var current: (any Subscription)?
    private var terminal = false
    /// Cancelled with the relay: a subscription of the operator's own
    /// beside the sources (switchToLatest's outer one, prefix(untilOutputFrom:)'s).
    private var companion: (any Subscription)?

    init(_ name: String, downstream: Downstream) {
        description = name
        self.downstream = downstream
    }

    var isTerminal: Bool { lock.withLock { terminal } }

    /// Hands downstream this subscription.
    func start() {
        downstream.receive(subscription: self)
    }

    func setCompanion(_ subscription: any Subscription) {
        lock.lock()
        guard !terminal, companion == nil else {
            lock.unlock()
            subscription.cancel()
            return
        }
        companion = subscription
        lock.unlock()
    }

    /// Switches to `publisher`, cancelling the source before it.
    func attach<P: Publisher>(_ publisher: P,
                              completion: @escaping (Subscribers.Completion<P.Failure>) -> Void) where P.Output == Output {
        lock.lock()
        guard !terminal else {
            lock.unlock()
            return
        }
        generation += 1
        let source = RelaySource<Downstream, P.Failure>(relay: self, generation: generation, completion: completion)
        let previous = current
        current = nil
        lock.unlock()
        previous?.cancel()
        publisher.subscribe(source)
    }

    /// Cancels the current source without another (switchToLatest between
    /// children).
    func detach() {
        let previous = lock.withLock { () -> (any Subscription)? in
            generation += 1
            defer { current = nil }
            return current
        }
        previous?.cancel()
    }

    func finish(_ completion: Subscribers.Completion<Failure>) {
        lock.lock()
        guard !terminal else {
            lock.unlock()
            return
        }
        terminal = true
        let source = current
        let other = companion
        current = nil
        companion = nil
        lock.unlock()
        source?.cancel()
        other?.cancel()
        downstreamLock.withLock { downstream.receive(completion: completion) }
    }

    func sourceSubscribed(_ generation: Int, _ subscription: any Subscription) {
        lock.lock()
        guard !terminal, generation == self.generation, current == nil else {
            lock.unlock()
            subscription.cancel()
            return
        }
        current = subscription
        let outstanding = demand
        lock.unlock()
        if outstanding > 0 { subscription.request(outstanding) }
    }

    func sourceValue(_ generation: Int, _ value: Output) -> Subscribers.Demand {
        lock.lock()
        guard !terminal, generation == self.generation else {
            lock.unlock()
            return .none
        }
        demand.consumeOne()
        lock.unlock()
        let more = downstreamLock.withLock { downstream.receive(value) }
        lock.withLock { demand += more }
        return more
    }

    /// Whether the completion is the current source's (and so counts).
    func sourceCompleted(_ generation: Int) -> Bool {
        lock.withLock {
            guard !terminal, generation == self.generation else { return false }
            current = nil
            return true
        }
    }

    func request(_ demand: Subscribers.Demand) {
        let source = lock.withLock { () -> (any Subscription)? in
            self.demand += demand
            return current
        }
        source?.request(demand)
    }

    func cancel() {
        let (source, other) = lock.withLock { () -> ((any Subscription)?, (any Subscription)?) in
            terminal = true
            defer {
                current = nil
                companion = nil
            }
            return (current, companion)
        }
        source?.cancel()
        other?.cancel()
    }
}

final class RelaySource<Downstream: Subscriber, SourceFailure: Error>: Subscriber {
    typealias Input = Downstream.Input
    typealias Failure = SourceFailure

    private let relay: Relay<Downstream>
    private let generation: Int
    private let completion: (Subscribers.Completion<SourceFailure>) -> Void

    init(relay: Relay<Downstream>, generation: Int, completion: @escaping (Subscribers.Completion<SourceFailure>) -> Void) {
        self.relay = relay
        self.generation = generation
        self.completion = completion
    }

    func receive(subscription: any Subscription) {
        relay.sourceSubscribed(generation, subscription)
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        relay.sourceValue(generation, input)
    }

    func receive(completion: Subscribers.Completion<SourceFailure>) {
        if relay.sourceCompleted(generation) { self.completion(completion) }
    }
}

/// A subscriber of closures, for an operator's side subscription (the
/// other publisher of prefix(untilOutputFrom:) and drop(untilOutputFrom:),
/// switchToLatest's outer one).
final class ClosureSubscriber<Input, Failure: Error>: Subscriber, Cancellable {
    private let lock = Lock()
    private var subscription: (any Subscription)?
    private var cancelled = false
    private let onSubscribe: (any Subscription) -> Void
    private let onValue: (Input) -> Subscribers.Demand
    private let onCompletion: (Subscribers.Completion<Failure>) -> Void

    init(onSubscribe: @escaping (any Subscription) -> Void = { _ in },
         onValue: @escaping (Input) -> Subscribers.Demand,
         onCompletion: @escaping (Subscribers.Completion<Failure>) -> Void) {
        self.onSubscribe = onSubscribe
        self.onValue = onValue
        self.onCompletion = onCompletion
    }

    func receive(subscription: any Subscription) {
        lock.lock()
        guard !cancelled, self.subscription == nil else {
            lock.unlock()
            subscription.cancel()
            return
        }
        self.subscription = subscription
        lock.unlock()
        onSubscribe(subscription)
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        guard !lock.withLock({ cancelled }) else { return .none }
        return onValue(input)
    }

    func receive(completion: Subscribers.Completion<Failure>) {
        guard !lock.withLock({ cancelled }) else { return }
        onCompletion(completion)
    }

    func cancel() {
        let subscription = lock.withLock { () -> (any Subscription)? in
            cancelled = true
            defer { self.subscription = nil }
            return self.subscription
        }
        subscription?.cancel()
    }
}
