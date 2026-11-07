// The two subscribers an app makes most: sink (closures) and assign (a key
// path of an object). Each asks for unlimited values, and lets go of its
// closures or object once completed or cancelled.

extension Publisher {
    public func sink(receiveCompletion: @escaping (Subscribers.Completion<Self.Failure>) -> Void,
                     receiveValue: @escaping (Self.Output) -> Void) -> AnyCancellable {
        let sink = Subscribers.Sink<Output, Failure>(receiveCompletion: receiveCompletion, receiveValue: receiveValue)
        subscribe(sink)
        return AnyCancellable(sink)
    }
}

extension Publisher where Self.Failure == Never {
    public func sink(receiveValue: @escaping (Self.Output) -> Void) -> AnyCancellable {
        sink(receiveCompletion: { _ in }, receiveValue: receiveValue)
    }

    public func assign<Root>(to keyPath: ReferenceWritableKeyPath<Root, Self.Output>, on object: Root) -> AnyCancellable {
        let assign = Subscribers.Assign(object: object, keyPath: keyPath)
        subscribe(assign)
        return AnyCancellable(assign)
    }
}

/// Where a subscriber stands with its upstream.
enum SubscriptionStatus {
    case awaiting
    case subscribed(any Subscription)
    case terminal
}

extension Subscribers {
    final public class Sink<Input, Failure>: Subscriber, Cancellable, CustomStringConvertible, CustomReflectable,
        CustomPlaygroundDisplayConvertible where Failure: Error {
        private let lock = Lock()
        private var status = SubscriptionStatus.awaiting
        private var valueHandler: ((Input) -> Void)?
        private var completionHandler: ((Subscribers.Completion<Failure>) -> Void)?

        final public var receiveValue: (Input) -> Void {
            lock.withLock { valueHandler } ?? { _ in }
        }

        final public var receiveCompletion: (Subscribers.Completion<Failure>) -> Void {
            lock.withLock { completionHandler } ?? { _ in }
        }

        final public var description: String { "Sink" }

        final public var customMirror: Mirror {
            Mirror(self, children: [])
        }

        final public var playgroundDescription: Any { description }

        public init(receiveCompletion: @escaping (Subscribers.Completion<Failure>) -> Void,
                    receiveValue: @escaping (Input) -> Void) {
            valueHandler = receiveValue
            completionHandler = receiveCompletion
        }

        final public func receive(subscription: any Subscription) {
            lock.lock()
            guard case .awaiting = status else {
                lock.unlock()
                subscription.cancel()
                return
            }
            status = .subscribed(subscription)
            lock.unlock()
            subscription.request(.unlimited)
        }

        final public func receive(_ value: Input) -> Subscribers.Demand {
            let handler = lock.withLock { valueHandler }
            handler?(value)
            return .none
        }

        final public func receive(completion: Subscribers.Completion<Failure>) {
            let handler = lock.withLock { () -> ((Subscribers.Completion<Failure>) -> Void)? in
                defer {
                    status = .terminal
                    completionHandler = nil
                }
                return completionHandler
            }
            handler?(completion)
            // The closures go only after the last call, which may hold the
            // sink's own token.
            lock.withLock { valueHandler = nil }
        }

        final public func cancel() {
            let subscription = lock.withLock { () -> (any Subscription)? in
                defer {
                    status = .terminal
                    valueHandler = nil
                    completionHandler = nil
                }
                if case .subscribed(let subscription) = status { return subscription }
                return nil
            }
            subscription?.cancel()
        }
    }

    final public class Assign<Root, Input>: Subscriber, Cancellable, CustomStringConvertible, CustomReflectable,
        CustomPlaygroundDisplayConvertible {
        public typealias Failure = Never

        private let lock = Lock()
        private var status = SubscriptionStatus.awaiting
        private var target: Root?

        final public var object: Root? {
            lock.withLock { target }
        }

        final public let keyPath: ReferenceWritableKeyPath<Root, Input>

        final public var description: String { "Assign \(Root.self)." }

        final public var customMirror: Mirror {
            Mirror(self, children: ["object": object as Any, "keyPath": keyPath])
        }

        final public var playgroundDescription: Any { description }

        public init(object: Root, keyPath: ReferenceWritableKeyPath<Root, Input>) {
            target = object
            self.keyPath = keyPath
        }

        final public func receive(subscription: any Subscription) {
            lock.lock()
            guard case .awaiting = status else {
                lock.unlock()
                subscription.cancel()
                return
            }
            status = .subscribed(subscription)
            lock.unlock()
            subscription.request(.unlimited)
        }

        final public func receive(_ value: Input) -> Subscribers.Demand {
            if let object = lock.withLock({ target }) {
                object[keyPath: keyPath] = value
            }
            return .none
        }

        final public func receive(completion: Subscribers.Completion<Never>) {
            lock.withLock {
                status = .terminal
                target = nil
            }
        }

        final public func cancel() {
            let subscription = lock.withLock { () -> (any Subscription)? in
                defer {
                    status = .terminal
                    target = nil
                }
                if case .subscribed(let subscription) = status { return subscription }
                return nil
            }
            subscription?.cancel()
        }
    }
}
