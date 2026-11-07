// A publisher's values as an AsyncSequence (`for await value in
// publisher.values`): each next() asks the publisher for one value and
// waits for it. Cancelling the task cancels the subscription.

extension Publisher where Self.Failure == Never {
    public var values: AsyncPublisher<Self> {
        AsyncPublisher(self)
    }
}

extension Publisher {
    public var values: AsyncThrowingPublisher<Self> {
        AsyncThrowingPublisher(self)
    }
}

public struct AsyncPublisher<P>: AsyncSequence where P: Publisher, P.Failure == Never {
    public typealias Element = P.Output
    public typealias AsyncIterator = AsyncPublisher<P>.Iterator

    public struct Iterator: AsyncIteratorProtocol {
        public typealias Element = P.Output

        let inner: AsyncInner<P.Output, Never>

        public mutating func next() async -> P.Output? {
            // Never fails: only a value or the end.
            try! await inner.next()
        }
    }

    private let publisher: P

    public init(_ publisher: P) {
        self.publisher = publisher
    }

    public func makeAsyncIterator() -> AsyncPublisher<P>.Iterator {
        let inner = AsyncInner<P.Output, Never>()
        publisher.subscribe(inner)
        return Iterator(inner: inner)
    }
}

public struct AsyncThrowingPublisher<P>: AsyncSequence where P: Publisher {
    public typealias Element = P.Output
    public typealias AsyncIterator = AsyncThrowingPublisher<P>.Iterator

    public struct Iterator: AsyncIteratorProtocol {
        public typealias Element = P.Output

        let inner: AsyncInner<P.Output, P.Failure>

        public mutating func next() async throws -> P.Output? {
            try await inner.next()
        }
    }

    private let publisher: P

    public init(_ publisher: P) {
        self.publisher = publisher
    }

    public func makeAsyncIterator() -> AsyncThrowingPublisher<P>.Iterator {
        let inner = AsyncInner<P.Output, P.Failure>()
        publisher.subscribe(inner)
        return Iterator(inner: inner)
    }
}

/// The subscriber behind an iterator: one request per next(), the value
/// handed to the waiting continuation. A failure is thrown once, then the
/// sequence ends.
final class AsyncInner<Input, Failure: Error>: Subscriber, Cancellable, @unchecked Sendable {
    private let lock = Lock()
    private var subscription: (any Subscription)?
    private var waiting: CheckedContinuation<Input?, any Error>?
    /// Asked for before the subscription came.
    private var owedRequest = false
    private var completion: Subscribers.Completion<Failure>?
    private var cancelled = false

    func receive(subscription: any Subscription) {
        lock.lock()
        guard self.subscription == nil, !cancelled, completion == nil else {
            lock.unlock()
            subscription.cancel()
            return
        }
        self.subscription = subscription
        let owed = owedRequest
        owedRequest = false
        lock.unlock()
        if owed { subscription.request(.max(1)) }
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        let continuation = lock.withLock { () -> CheckedContinuation<Input?, any Error>? in
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume(returning: input)
        return .none
    }

    func receive(completion: Subscribers.Completion<Failure>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Input?, any Error>? in
            subscription = nil
            guard let waiting else {
                self.completion = completion
                return nil
            }
            // Thrown now, then nothing more.
            self.completion = .finished
            self.waiting = nil
            return waiting
        }
        guard let continuation else { return }
        switch completion {
        case .finished: continuation.resume(returning: nil)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    func next() async throws -> Input? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Input?, any Error>) in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                if let completion {
                    self.completion = .finished
                    lock.unlock()
                    switch completion {
                    case .finished: continuation.resume(returning: nil)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                    return
                }
                waiting = continuation
                let subscription = self.subscription
                if subscription == nil { owedRequest = true }
                lock.unlock()
                subscription?.request(.max(1))
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let (subscription, continuation) = lock.withLock { () -> ((any Subscription)?, CheckedContinuation<Input?, any Error>?) in
            cancelled = true
            defer {
                self.subscription = nil
                waiting = nil
            }
            return (self.subscription, waiting)
        }
        subscription?.cancel()
        continuation?.resume(returning: nil)
    }
}
