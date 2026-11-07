// AnySubscriber and AnyPublisher: a subscriber or publisher behind its
// Input/Output and Failure alone.

@frozen public struct AnySubscriber<Input, Failure>: Subscriber, CustomStringConvertible, CustomReflectable,
    CustomPlaygroundDisplayConvertible where Failure: Error {
    @usableFromInline
    internal let receiveSubscriptionBody: (any Subscription) -> Void
    @usableFromInline
    internal let receiveValueBody: (Input) -> Subscribers.Demand
    @usableFromInline
    internal let receiveCompletionBody: (Subscribers.Completion<Failure>) -> Void
    @usableFromInline
    internal let descriptionBody: () -> String
    @usableFromInline
    internal let mirrorBody: () -> Mirror

    public let combineIdentifier: CombineIdentifier

    public var description: String { descriptionBody() }
    public var customMirror: Mirror { mirrorBody() }
    public var playgroundDescription: Any { description }

    public init<S>(_ s: S) where Input == S.Input, Failure == S.Failure, S: Subscriber {
        if let erased = s as? AnySubscriber<Input, Failure> {
            self = erased
            return
        }
        combineIdentifier = s.combineIdentifier
        receiveSubscriptionBody = s.receive(subscription:)
        receiveValueBody = s.receive(_:)
        receiveCompletionBody = s.receive(completion:)
        if let described = s as? CustomStringConvertible {
            descriptionBody = { described.description }
        } else {
            let name = "\(type(of: s))"
            descriptionBody = { name }
        }
        mirrorBody = {
            (s as? CustomReflectable)?.customMirror ?? Mirror(s, children: [:])
        }
    }

    /// A subscriber feeding a subject.
    public init<S>(_ s: S) where Input == S.Output, Failure == S.Failure, S: Subject {
        combineIdentifier = CombineIdentifier(s)
        receiveSubscriptionBody = { s.send(subscription: $0) }
        receiveValueBody = { s.send($0); return .none }
        receiveCompletionBody = { s.send(completion: $0) }
        let name = "\(type(of: s))"
        descriptionBody = { name }
        mirrorBody = { Mirror(reflecting: s) }
    }

    public init(receiveSubscription: ((any Subscription) -> Void)? = nil,
                receiveValue: ((Input) -> Subscribers.Demand)? = nil,
                receiveCompletion: ((Subscribers.Completion<Failure>) -> Void)? = nil) {
        combineIdentifier = CombineIdentifier()
        receiveSubscriptionBody = receiveSubscription ?? { _ in }
        receiveValueBody = receiveValue ?? { _ in .none }
        receiveCompletionBody = receiveCompletion ?? { _ in }
        descriptionBody = { "Anonymous AnySubscriber" }
        mirrorBody = { Mirror(reflecting: "Anonymous AnySubscriber") }
    }

    @inlinable
    public func receive(subscription: any Subscription) {
        receiveSubscriptionBody(subscription)
    }

    @inlinable
    public func receive(_ value: Input) -> Subscribers.Demand {
        receiveValueBody(value)
    }

    @inlinable
    public func receive(completion: Subscribers.Completion<Failure>) {
        receiveCompletionBody(completion)
    }
}

/// The publisher an AnyPublisher holds, behind its Output and Failure.
@usableFromInline
internal class PublisherBoxBase<Output, Failure: Error> {
    @usableFromInline
    func receive<S>(subscriber: S) where Output == S.Input, Failure == S.Failure, S: Subscriber {
        fatalError("PublisherBoxBase is abstract")
    }

    @usableFromInline
    var description: String { "AnyPublisher" }
}

@usableFromInline
final internal class PublisherBox<Base: Publisher>: PublisherBoxBase<Base.Output, Base.Failure> {
    @usableFromInline
    let base: Base

    @usableFromInline
    init(_ base: Base) {
        self.base = base
    }

    @usableFromInline
    override func receive<S>(subscriber: S) where Base.Output == S.Input, Base.Failure == S.Failure, S: Subscriber {
        base.receive(subscriber: subscriber)
    }
}

@frozen public struct AnyPublisher<Output, Failure>: CustomStringConvertible, CustomPlaygroundDisplayConvertible
where Failure: Error {
    @usableFromInline
    internal let box: PublisherBoxBase<Output, Failure>

    public var description: String { "AnyPublisher" }
    public var playgroundDescription: Any { description }

    @inlinable
    public init<P>(_ publisher: P) where Output == P.Output, Failure == P.Failure, P: Publisher {
        if let erased = publisher as? AnyPublisher<Output, Failure> {
            box = erased.box
        } else {
            box = PublisherBox(publisher)
        }
    }
}

extension AnyPublisher: Publisher {
    @inlinable
    public func receive<S>(subscriber: S) where Output == S.Input, Failure == S.Failure, S: Subscriber {
        box.receive(subscriber: subscriber)
    }
}

extension Publisher {
    public func eraseToAnyPublisher() -> AnyPublisher<Self.Output, Self.Failure> {
        AnyPublisher(self)
    }
}
