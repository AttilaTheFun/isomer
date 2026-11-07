// Publisher, and Publishers: the namespace of the operators' publishers.

public protocol Publisher<Output, Failure> {
    associatedtype Output
    associatedtype Failure: Error
    func receive<S>(subscriber: S) where S: Subscriber, Self.Failure == S.Failure, Self.Output == S.Input
}

public enum Publishers {}

extension Publisher {
    /// What code calls to attach a subscriber (a publisher implements
    /// `receive(subscriber:)`).
    @inline(never)
    public func subscribe<S>(_ subscriber: S) where S: Subscriber, Self.Failure == S.Failure, Self.Output == S.Input {
        receive(subscriber: subscriber)
    }

    /// Feeds a subject: it requests unlimited values through
    /// `send(subscription:)`, and the returned token cancels the feed.
    public func subscribe<S>(_ subject: S) -> AnyCancellable where S: Subject, Self.Failure == S.Failure, Self.Output == S.Output {
        let feed = SubjectFeed(subject)
        subscribe(feed)
        return AnyCancellable(feed)
    }
}

/// A subscriber passing what it receives to a subject.
final class SubjectFeed<Downstream: Subject>: Subscriber, Cancellable {
    typealias Input = Downstream.Output
    typealias Failure = Downstream.Failure

    private let lock = Lock()
    private var subject: Downstream?
    private var subscription: (any Subscription)?

    init(_ subject: Downstream) {
        self.subject = subject
    }

    func receive(subscription: any Subscription) {
        lock.lock()
        guard self.subscription == nil, let subject else {
            lock.unlock()
            subscription.cancel()
            return
        }
        self.subscription = subscription
        lock.unlock()
        subject.send(subscription: subscription)
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        guard let subject = lock.withLock({ self.subject }) else { return .none }
        subject.send(input)
        return .none
    }

    func receive(completion: Subscribers.Completion<Failure>) {
        let subject = lock.withLock { () -> Downstream? in
            defer { self.subject = nil; subscription = nil }
            return self.subject
        }
        subject?.send(completion: completion)
    }

    func cancel() {
        let subscription = lock.withLock { () -> (any Subscription)? in
            defer { self.subscription = nil; subject = nil }
            return self.subscription
        }
        subscription?.cancel()
    }
}
