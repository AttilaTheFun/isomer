// Notifications by name, as Apple's Foundation posts and observes them:
// `Notification`, `NSNotification` (for its `Name`), and NotificationCenter's
// `post` and block-based `addObserver(forName:object:queue:using:)`, over the
// registrar swift-foundation's NotificationCenter keeps for its messages (the
// SPI swift-corelibs-foundation builds the same API on). An observer with no
// queue runs on the poster's thread, before `post` returns; one with a queue
// runs as that queue's operation (OperationQueue.swift: the main queue's on
// the main actor). No selector-based observers: there's no runtime to send
// a selector through.

@_spi(SwiftCorelibsFoundation) import FoundationEssentials

/// What a notification carries: its name, the object that posted it, and
/// what it adds.
public struct Notification: Equatable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, @unchecked Sendable {
    public typealias Name = NSNotification.Name

    public var name: Name
    public var object: Any?
    public var userInfo: [AnyHashable: Any]?

    public init(name: Name, object: Any? = nil, userInfo: [AnyHashable: Any]? = nil) {
        self.name = name
        self.object = object
        self.userInfo = userInfo
    }

    /// The same name and the same object (by identity; equal values when
    /// the objects aren't classes), as Apple's compares them.
    public static func == (lhs: Notification, rhs: Notification) -> Bool {
        guard lhs.name == rhs.name else { return false }
        switch (lhs.object, rhs.object) {
        case (nil, nil): return true
        case let (left?, right?):
            if type(of: left) is AnyClass, type(of: right) is AnyClass { return (left as AnyObject) === (right as AnyObject) }
            if let left = left as? AnyHashable, let right = right as? AnyHashable { return left == right }
            return false
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(name) }

    public var description: String {
        "name = \(name.rawValue), object = \(object.map { String(describing: $0) } ?? "nil"), userInfo = \(userInfo.map { String(describing: $0) } ?? "nil")"
    }

    public var debugDescription: String { description }
}

/// Apple's reference type for a notification; Swift code meets it for its
/// `Name`.
open class NSNotification: NSObject, @unchecked Sendable {
    /// A notification's name: a string, typed.
    public struct Name: RawRepresentable, Hashable, Equatable, Sendable {
        public var rawValue: String

        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init(rawValue: String) { self.rawValue = rawValue }
    }

    open var name: Name
    open var object: Any?
    open var userInfo: [AnyHashable: Any]?

    public init(name: Name, object: Any?, userInfo: [AnyHashable: Any]? = nil) {
        self.name = name
        self.object = object
        self.userInfo = userInfo
    }
}

/// What `addObserver(forName:object:queue:using:)` hands back: given to
/// `removeObserver(_:)`, it ends the observation.
private final class NotificationObserver: NSObject, @unchecked Sendable {
    let token: NotificationCenter._NotificationObserverToken
    weak var center: NotificationCenter?
    let name: String?
    let object: ObjectIdentifier?

    init(token: NotificationCenter._NotificationObserverToken, center: NotificationCenter, name: String?, object: ObjectIdentifier?) {
        self.token = token
        self.center = center
        self.name = name
        self.object = object
    }
}

extension NotificationCenter {
    public func post(_ notification: Notification) {
        _post(notification.name.rawValue, subject: notification.object, message: notification)
    }

    public func post(name aName: NSNotification.Name, object anObject: Any?) {
        post(Notification(name: aName, object: anObject))
    }

    public func post(name aName: NSNotification.Name, object anObject: Any?, userInfo aUserInfo: [AnyHashable: Any]? = nil) {
        post(Notification(name: aName, object: anObject, userInfo: aUserInfo))
    }

    /// `block` called with each notification of `name` (every name when
    /// nil) from `obj` (any object when nil): on the poster's thread when
    /// `queue` is nil, as an operation of `queue` otherwise. Observing lasts
    /// until the returned object is given to `removeObserver(_:)`.
    public func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
                            using block: @escaping @Sendable (Notification) -> Void) -> any NSObjectProtocol {
        let token = _addObserver(name?.rawValue, object: obj) { (notification: Notification) in
            if let queue {
                queue.addOperation { block(notification) }
            } else {
                block(notification)
            }
        }
        return NotificationObserver(token: token, center: self, name: name?.rawValue, object: obj.map { ObjectIdentifier($0 as AnyObject) })
    }

    /// An observation `addObserver(forName:object:queue:using:)` began, ended.
    public func removeObserver(_ observer: Any) {
        guard let observer = observer as? NotificationObserver, observer.center === self else { return }
        _removeObserver(observer.token)
    }

    /// The observation ended if it is of `aName` (or any, when nil) and
    /// `anObject` (or any).
    public func removeObserver(_ observer: Any, name aName: NSNotification.Name?, object anObject: Any?) {
        guard let observer = observer as? NotificationObserver, observer.center === self else { return }
        if let aName, observer.name != aName.rawValue { return }
        if let anObject, observer.object != ObjectIdentifier(anObject as AnyObject) { return }
        _removeObserver(observer.token)
    }

    /// The notifications of `name` (from `object`, when given) as they're
    /// posted, from the time this is called, for as long as it's iterated.
    public func notifications(named name: Notification.Name, object: (any AnyObject & Sendable)? = nil) -> Notifications {
        Notifications(center: self, name: name, object: object)
    }

    /// An asynchronous sequence of notifications: what `notifications(named:
    /// object:)` gives.
    public final class Notifications: AsyncSequence, @unchecked Sendable {
        public typealias Element = Notification
        public typealias AsyncIterator = Iterator

        private let stream: AsyncStream<Notification>
        private let observer: any NSObjectProtocol
        private weak var center: NotificationCenter?

        init(center: NotificationCenter, name: Notification.Name, object: (any AnyObject & Sendable)?) {
            let (stream, continuation) = AsyncStream<Notification>.makeStream()
            self.stream = stream
            self.center = center
            observer = center.addObserver(forName: name, object: object, queue: nil) { continuation.yield($0) }
        }

        deinit { center?.removeObserver(observer) }

        public struct Iterator: AsyncIteratorProtocol {
            public typealias Element = Notification
            var base: AsyncStream<Notification>.Iterator

            public mutating func next() async -> Notification? { await base.next() }
        }

        public func makeAsyncIterator() -> Iterator { Iterator(base: stream.makeAsyncIterator()) }
    }
}
