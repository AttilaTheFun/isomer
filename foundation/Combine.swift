// What Apple's Foundation gives Combine code: `ObservableObject` and
// `Published` named from Foundation (typealiases of Combine's, as Apple's
// Foundation declares them, so a model needs only `import Foundation`), and
// NotificationCenter's publisher. Combine is Isomer's (frameworks/combine),
// beneath Foundation; Foundation doesn't re-export it, as Apple's doesn't.

import Combine

public typealias Published = Combine.Published
public typealias ObservableObject = Combine.ObservableObject

extension NotificationCenter {
    /// The notifications of one name (and, given one, object) posted to a
    /// center, as a publisher: each subscriber gets those posted while it
    /// is subscribed and has demand for them (others are dropped, as
    /// Apple's are).
    public struct Publisher: Combine.Publisher {
        public typealias Output = Notification
        public typealias Failure = Never

        public let center: NotificationCenter
        public let name: Notification.Name
        public let object: AnyObject?

        public init(center: NotificationCenter, name: Notification.Name, object: AnyObject? = nil) {
            self.center = center
            self.name = name
            self.object = object
        }

        public func receive<S>(subscriber: S) where S: Subscriber, S.Failure == Never, S.Input == Notification {
            subscriber.receive(subscription: _NotificationSubscription(center: center, name: name, object: object, subscriber: subscriber))
        }
    }

    public func publisher(for name: Notification.Name, object: AnyObject? = nil) -> NotificationCenter.Publisher {
        Publisher(center: self, name: name, object: object)
    }
}

extension NotificationCenter.Publisher: Equatable {
    public static func == (lhs: NotificationCenter.Publisher, rhs: NotificationCenter.Publisher) -> Bool {
        lhs.center === rhs.center && lhs.name == rhs.name && lhs.object === rhs.object
    }
}

/// One subscriber's observer on the center: added at subscription, removed
/// when cancelled.
private final class _NotificationSubscription<S: Subscriber>: Subscription, @unchecked Sendable
where S.Input == Notification, S.Failure == Never {
    private let lock = NSLock()
    private var subscriber: S?
    private var demand: Subscribers.Demand = .none
    private var observer: (any NSObjectProtocol)?
    private let center: NotificationCenter

    init(center: NotificationCenter, name: Notification.Name, object: AnyObject?, subscriber: S) {
        self.center = center
        self.subscriber = subscriber
        observer = center.addObserver(forName: name, object: object, queue: nil) { [weak self] notification in
            self?.deliver(notification)
        }
    }

    private func deliver(_ notification: Notification) {
        lock.lock()
        guard let subscriber, demand > 0 else { lock.unlock(); return }
        demand -= 1
        lock.unlock()
        let more = subscriber.receive(notification)
        lock.lock()
        demand += more
        lock.unlock()
    }

    func request(_ demand: Subscribers.Demand) {
        lock.lock()
        self.demand += demand
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let observer = self.observer
        self.observer = nil
        subscriber = nil
        lock.unlock()
        if let observer { center.removeObserver(observer) }
    }
}
