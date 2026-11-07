// The operators that move from one upstream to another: prepend and append
// (Concatenate), catch, retry, switchToLatest, prefix(untilOutputFrom:) and
// drop(untilOutputFrom:); and handleEvents and print, which watch a stream
// go by. The switching ones are a Relay (Inner.swift).

// MARK: - prepend, append

extension Publisher {
    public func prepend(_ elements: Self.Output...) -> Publishers.Concatenate<Publishers.Sequence<[Self.Output], Self.Failure>, Self> {
        prepend(elements)
    }

    public func prepend<S>(_ elements: S) -> Publishers.Concatenate<Publishers.Sequence<S, Self.Failure>, Self>
    where S: Sequence, Self.Output == S.Element {
        Publishers.Concatenate(prefix: Publishers.Sequence(sequence: elements), suffix: self)
    }

    public func prepend<P>(_ publisher: P) -> Publishers.Concatenate<P, Self>
    where P: Publisher, Self.Failure == P.Failure, Self.Output == P.Output {
        Publishers.Concatenate(prefix: publisher, suffix: self)
    }

    public func append(_ elements: Self.Output...) -> Publishers.Concatenate<Self, Publishers.Sequence<[Self.Output], Self.Failure>> {
        append(elements)
    }

    public func append<S>(_ elements: S) -> Publishers.Concatenate<Self, Publishers.Sequence<S, Self.Failure>>
    where S: Sequence, Self.Output == S.Element {
        Publishers.Concatenate(prefix: self, suffix: Publishers.Sequence(sequence: elements))
    }

    public func append<P>(_ publisher: P) -> Publishers.Concatenate<Self, P>
    where P: Publisher, Self.Failure == P.Failure, Self.Output == P.Output {
        Publishers.Concatenate(prefix: self, suffix: publisher)
    }
}

extension Publishers {
    /// The prefix's values, then (once it finishes) the suffix's.
    public struct Concatenate<Prefix, Suffix>: Publisher
    where Prefix: Publisher, Suffix: Publisher, Prefix.Failure == Suffix.Failure, Prefix.Output == Suffix.Output {
        public typealias Output = Suffix.Output
        public typealias Failure = Suffix.Failure

        public let prefix: Prefix
        public let suffix: Suffix

        public init(prefix: Prefix, suffix: Suffix) {
            self.prefix = prefix
            self.suffix = suffix
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Suffix.Failure == S.Failure, Suffix.Output == S.Input {
            let relay = Relay("Concatenate", downstream: subscriber)
            let suffix = self.suffix
            relay.start()
            relay.attach(prefix) { [relay] completion in
                guard case .finished = completion else {
                    relay.finish(completion)
                    return
                }
                relay.attach(suffix) { relay.finish($0) }
            }
        }
    }
}

extension Publishers.Concatenate: Equatable where Prefix: Equatable, Suffix: Equatable {
    public static func == (lhs: Publishers.Concatenate<Prefix, Suffix>, rhs: Publishers.Concatenate<Prefix, Suffix>) -> Bool {
        lhs.prefix == rhs.prefix && lhs.suffix == rhs.suffix
    }
}

// MARK: - catch, retry

extension Publisher {
    public func `catch`<P>(_ handler: @escaping (Self.Failure) -> P) -> Publishers.Catch<Self, P>
    where P: Publisher, Self.Output == P.Output {
        Publishers.Catch(upstream: self, handler: handler)
    }

    public func tryCatch<P>(_ handler: @escaping (Self.Failure) throws -> P) -> Publishers.TryCatch<Self, P>
    where P: Publisher, Self.Output == P.Output {
        Publishers.TryCatch(upstream: self, handler: handler)
    }

    public func retry(_ retries: Int) -> Publishers.Retry<Self> {
        Publishers.Retry(upstream: self, retries: retries)
    }
}

extension Publishers {
    /// On a failure, the publisher the handler makes in upstream's place.
    public struct Catch<Upstream, NewPublisher>: Publisher
    where Upstream: Publisher, NewPublisher: Publisher, Upstream.Output == NewPublisher.Output {
        public typealias Output = Upstream.Output
        public typealias Failure = NewPublisher.Failure

        public let upstream: Upstream
        public let handler: (Upstream.Failure) -> NewPublisher

        public init(upstream: Upstream, handler: @escaping (Upstream.Failure) -> NewPublisher) {
            self.upstream = upstream
            self.handler = handler
        }

        public func receive<S>(subscriber: S) where S: Subscriber, NewPublisher.Failure == S.Failure,
            NewPublisher.Output == S.Input {
            let relay = Relay("Catch", downstream: subscriber)
            let handler = self.handler
            relay.start()
            relay.attach(upstream) { [relay] completion in
                switch completion {
                case .finished:
                    relay.finish(.finished)
                case .failure(let error):
                    relay.attach(handler(error)) { relay.finish($0) }
                }
            }
        }
    }

    public struct TryCatch<Upstream, NewPublisher>: Publisher
    where Upstream: Publisher, NewPublisher: Publisher, Upstream.Output == NewPublisher.Output {
        public typealias Output = Upstream.Output
        public typealias Failure = Error

        public let upstream: Upstream
        public let handler: (Upstream.Failure) throws -> NewPublisher

        public init(upstream: Upstream, handler: @escaping (Upstream.Failure) throws -> NewPublisher) {
            self.upstream = upstream
            self.handler = handler
        }

        public func receive<S>(subscriber: S) where S: Subscriber, NewPublisher.Output == S.Input, S.Failure == any Error {
            let relay = Relay("TryCatch", downstream: subscriber)
            let handler = self.handler
            relay.start()
            relay.attach(upstream) { [relay] completion in
                switch completion {
                case .finished:
                    relay.finish(.finished)
                case .failure(let error):
                    do {
                        relay.attach(try handler(error)) { relay.finish($0.eraseError) }
                    } catch {
                        relay.finish(.failure(error))
                    }
                }
            }
        }
    }

    /// Subscribes again on a failure, up to `retries` times (nil: always).
    public struct Retry<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let retries: Int?

        public init(upstream: Upstream, retries: Int?) {
            self.upstream = upstream
            self.retries = retries
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            let relay = Relay("Retry", downstream: subscriber)
            relay.start()
            Self.attempt(upstream, relay: relay, remaining: retries)
        }

        private static func attempt<S: Subscriber>(_ upstream: Upstream, relay: Relay<S>, remaining: Int?)
        where Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            relay.attach(upstream) { completion in
                guard case .failure = completion, remaining.map({ $0 > 0 }) ?? true else {
                    relay.finish(completion)
                    return
                }
                attempt(upstream, relay: relay, remaining: remaining.map { $0 - 1 })
            }
        }
    }
}

extension Publishers.Retry: Equatable where Upstream: Equatable {
    public static func == (lhs: Publishers.Retry<Upstream>, rhs: Publishers.Retry<Upstream>) -> Bool {
        lhs.upstream == rhs.upstream && lhs.retries == rhs.retries
    }
}

// MARK: - switchToLatest

extension Publisher where Self.Failure == Self.Output.Failure, Self.Output: Publisher {
    public func switchToLatest() -> Publishers.SwitchToLatest<Self.Output, Self> {
        Publishers.SwitchToLatest(upstream: self)
    }
}

extension Publisher where Self.Failure == Never, Self.Output: Publisher {
    public func switchToLatest() -> Publishers.SwitchToLatest<Self.Output, Publishers.SetFailureType<Self, Self.Output.Failure>> {
        Publishers.SwitchToLatest(upstream: setFailureType(to: Output.Failure.self))
    }
}

extension Publisher where Self.Failure == Never, Self.Output: Publisher, Self.Output.Failure == Never {
    public func switchToLatest() -> Publishers.SwitchToLatest<Self.Output, Self> {
        Publishers.SwitchToLatest(upstream: self)
    }
}

extension Publisher where Self.Output: Publisher, Self.Output.Failure == Never {
    public func switchToLatest() -> Publishers.SwitchToLatest<Publishers.SetFailureType<Self.Output, Self.Failure>,
        Publishers.Map<Self, Publishers.SetFailureType<Self.Output, Self.Failure>>> {
        Publishers.SwitchToLatest(upstream: map { $0.setFailureType(to: Failure.self) })
    }
}

extension Publishers {
    /// The values of the latest publisher upstream sent, the one before
    /// cancelled. Finishes when upstream and the latest have.
    public struct SwitchToLatest<P, Upstream>: Publisher
    where P: Publisher, P == Upstream.Output, Upstream: Publisher, P.Failure == Upstream.Failure {
        public typealias Output = P.Output
        public typealias Failure = P.Failure

        public let upstream: Upstream

        public init(upstream: Upstream) {
            self.upstream = upstream
        }

        public func receive<S>(subscriber: S) where S: Subscriber, P.Output == S.Input, Upstream.Failure == S.Failure {
            let relay = Relay("SwitchToLatest", downstream: subscriber)
            let state = SwitchState()
            relay.start()
            upstream.subscribe(ClosureSubscriber<P, P.Failure>(
                onSubscribe: { subscription in
                    relay.setCompanion(subscription)
                    subscription.request(.unlimited)
                },
                onValue: { child in
                    state.lock.withLock { state.childActive = true }
                    relay.attach(child) { completion in
                        if case .failure = completion {
                            relay.finish(completion)
                            return
                        }
                        let done = state.lock.withLock { () -> Bool in
                            state.childActive = false
                            return state.outerFinished
                        }
                        if done { relay.finish(.finished) }
                    }
                    return .none
                },
                onCompletion: { completion in
                    if case .failure = completion {
                        relay.finish(completion)
                        return
                    }
                    let done = state.lock.withLock { () -> Bool in
                        state.outerFinished = true
                        return !state.childActive
                    }
                    if done { relay.finish(.finished) }
                }))
        }
    }
}

final class SwitchState {
    let lock = Lock()
    var childActive = false
    var outerFinished = false
}

// MARK: - prefix(untilOutputFrom:), drop(untilOutputFrom:)

extension Publisher {
    public func prefix<P>(untilOutputFrom publisher: P) -> Publishers.PrefixUntilOutput<Self, P> where P: Publisher {
        Publishers.PrefixUntilOutput(upstream: self, other: publisher)
    }

    public func drop<P>(untilOutputFrom publisher: P) -> Publishers.DropUntilOutput<Self, P>
    where P: Publisher, Self.Failure == P.Failure {
        Publishers.DropUntilOutput(upstream: self, other: publisher)
    }
}

extension Publishers {
    /// Upstream's values until `other` sends one (or fails), then finished.
    public struct PrefixUntilOutput<Upstream, Other>: Publisher where Upstream: Publisher, Other: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let other: Other

        public init(upstream: Upstream, other: Other) {
            self.upstream = upstream
            self.other = other
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            let relay = Relay("PrefixUntilOutput", downstream: subscriber)
            relay.start()
            // The other first: a value it has at once means nothing of upstream's.
            other.subscribe(ClosureSubscriber<Other.Output, Other.Failure>(
                onSubscribe: { subscription in
                    relay.setCompanion(subscription)
                    subscription.request(.max(1))
                },
                onValue: { _ in
                    relay.finish(.finished)
                    return .none
                },
                onCompletion: { _ in }))
            relay.attach(upstream) { relay.finish($0) }
        }
    }

    /// Upstream's values from the first `other` sends on.
    public struct DropUntilOutput<Upstream, Other>: Publisher
    where Upstream: Publisher, Other: Publisher, Upstream.Failure == Other.Failure {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let other: Other

        public init(upstream: Upstream, other: Other) {
            self.upstream = upstream
            self.other = other
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Output == S.Input, Other.Failure == S.Failure {
            let gate = SwitchState()
            var inner: OperatorInner<Upstream.Output, Upstream.Failure, S>?
            let trigger = ClosureSubscriber<Other.Output, Other.Failure>(
                onSubscribe: { $0.request(.max(1)) },
                onValue: { _ in
                    gate.lock.withLock { gate.childActive = true }
                    return .none
                },
                onCompletion: { completion in
                    if case .failure(let error) = completion {
                        inner?.receive(completion: .failure(error))
                        inner?.cancel()
                    }
                })
            let made = OperatorInner<Upstream.Output, Upstream.Failure, S>("DropUntilOutput", downstream: subscriber) { value in
                gate.lock.withLock { gate.childActive } ? .send(value) : .skip
            }
            inner = made
            other.subscribe(trigger)
            upstream.subscribe(TriggerCancelling(made, trigger))
        }
    }
}

extension Publishers.DropUntilOutput: Equatable where Upstream: Equatable, Other: Equatable {
    public static func == (lhs: Publishers.DropUntilOutput<Upstream, Other>, rhs: Publishers.DropUntilOutput<Upstream, Other>) -> Bool {
        lhs.upstream == rhs.upstream && lhs.other == rhs.other
    }
}

/// Passes through to an OperatorInner, cancelling a side subscription when
/// the stream ends (drop(untilOutputFrom:)'s other publisher).
final class TriggerCancelling<Input, Failure: Error, Downstream: Subscriber>: Subscriber, Subscription {
    private let inner: OperatorInner<Input, Failure, Downstream>
    private let trigger: any Cancellable

    init(_ inner: OperatorInner<Input, Failure, Downstream>, _ trigger: any Cancellable) {
        self.inner = inner
        self.trigger = trigger
    }

    func receive(subscription: any Subscription) { inner.receive(subscription: subscription) }
    func receive(_ input: Input) -> Subscribers.Demand { inner.receive(input) }

    func receive(completion: Subscribers.Completion<Failure>) {
        trigger.cancel()
        inner.receive(completion: completion)
    }

    func request(_ demand: Subscribers.Demand) { inner.request(demand) }

    func cancel() {
        trigger.cancel()
        inner.cancel()
    }
}

// MARK: - handleEvents, print

extension Publisher {
    public func handleEvents(receiveSubscription: ((any Subscription) -> Void)? = nil,
                             receiveOutput: ((Self.Output) -> Void)? = nil,
                             receiveCompletion: ((Subscribers.Completion<Self.Failure>) -> Void)? = nil,
                             receiveCancel: (() -> Void)? = nil,
                             receiveRequest: ((Subscribers.Demand) -> Void)? = nil) -> Publishers.HandleEvents<Self> {
        Publishers.HandleEvents(upstream: self, receiveSubscription: receiveSubscription, receiveOutput: receiveOutput,
                                receiveCompletion: receiveCompletion, receiveCancel: receiveCancel,
                                receiveRequest: receiveRequest)
    }

    public func print(_ prefix: String = "", to stream: (any TextOutputStream)? = nil) -> Publishers.Print<Self> {
        Publishers.Print(upstream: self, prefix: prefix, to: stream)
    }
}

extension Publishers {
    public struct HandleEvents<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public var receiveSubscription: ((any Subscription) -> Void)?
        public var receiveOutput: ((Publishers.HandleEvents<Upstream>.Output) -> Void)?
        public var receiveCompletion: ((Subscribers.Completion<Publishers.HandleEvents<Upstream>.Failure>) -> Void)?
        public var receiveCancel: (() -> Void)?
        public var receiveRequest: ((Subscribers.Demand) -> Void)?

        public init(upstream: Upstream, receiveSubscription: ((any Subscription) -> Void)? = nil,
                    receiveOutput: ((Publishers.HandleEvents<Upstream>.Output) -> Void)? = nil,
                    receiveCompletion: ((Subscribers.Completion<Publishers.HandleEvents<Upstream>.Failure>) -> Void)? = nil,
                    receiveCancel: (() -> Void)? = nil, receiveRequest: ((Subscribers.Demand) -> Void)?) {
            self.upstream = upstream
            self.receiveSubscription = receiveSubscription
            self.receiveOutput = receiveOutput
            self.receiveCompletion = receiveCompletion
            self.receiveCancel = receiveCancel
            self.receiveRequest = receiveRequest
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            upstream.subscribe(EventsInner(downstream: subscriber, events: Events(
                subscription: receiveSubscription, output: receiveOutput, completion: receiveCompletion,
                cancel: receiveCancel, request: receiveRequest)))
        }
    }

    /// handleEvents that logs each event, as `<prefix>: receive value: (1)`.
    public struct Print<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let prefix: String
        public let upstream: Upstream
        public let stream: (any TextOutputStream)?

        public init(upstream: Upstream, prefix: String, to stream: (any TextOutputStream)? = nil) {
            self.upstream = upstream
            self.prefix = prefix
            self.stream = stream
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            let log = PrintLog(prefix: prefix, stream: stream)
            upstream.subscribe(EventsInner(downstream: subscriber, events: Events(
                subscription: { log.write("receive subscription: (\($0))") },
                output: { log.write("receive value: (\($0))") },
                completion: { completion in
                    switch completion {
                    case .finished: log.write("receive finished")
                    case .failure(let error): log.write("receive error: (\(error))")
                    }
                },
                cancel: { log.write("receive cancel") },
                request: { log.write("request \($0 == .unlimited ? "unlimited" : "max: (\($0.max ?? 0))")") })))
        }
    }
}

final class PrintLog {
    private let prefix: String
    private var stream: (any TextOutputStream)?
    private let lock = Lock()

    init(prefix: String, stream: (any TextOutputStream)?) {
        self.prefix = prefix
        self.stream = stream
    }

    func write(_ text: String) {
        let line = (prefix.isEmpty ? "" : prefix + ": ") + text
        lock.withLock {
            if stream != nil {
                stream!.write(line + "\n")
            } else {
                Swift.print(line)
            }
        }
    }
}

struct Events<Output, Failure: Error> {
    var subscription: ((any Subscription) -> Void)?
    var output: ((Output) -> Void)?
    var completion: ((Subscribers.Completion<Failure>) -> Void)?
    var cancel: (() -> Void)?
    var request: ((Subscribers.Demand) -> Void)?
}

/// Passes everything through, calling the closures as it goes.
final class EventsInner<Downstream: Subscriber>: Subscriber, Subscription, CustomStringConvertible {
    typealias Input = Downstream.Input
    typealias Failure = Downstream.Failure

    let description = "HandleEvents"
    private let lock = Lock()
    private var status = SubscriptionStatus.awaiting
    private let downstream: Downstream
    private let events: Events<Input, Failure>

    init(downstream: Downstream, events: Events<Input, Failure>) {
        self.downstream = downstream
        self.events = events
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
        events.subscription?(subscription)
        downstream.receive(subscription: self)
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        events.output?(input)
        let more = downstream.receive(input)
        if more > 0 { events.request?(more) }
        return more
    }

    func receive(completion: Subscribers.Completion<Failure>) {
        lock.withLock { status = .terminal }
        events.completion?(completion)
        downstream.receive(completion: completion)
    }

    func request(_ demand: Subscribers.Demand) {
        events.request?(demand)
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
        events.cancel?()
        upstream?.cancel()
    }
}
