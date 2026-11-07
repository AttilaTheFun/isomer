// Cancellable and AnyCancellable: what a subscription hands back, and the
// token an app keeps (in a Set, usually) for as long as it wants values.

public protocol Cancellable {
    func cancel()
}

/// Cancels when cancelled or when released, whichever comes first, and only
/// once. Equal by identity, so a Set keeps each one.
final public class AnyCancellable: Cancellable, Hashable {
    private let lock = Lock()
    private var cancelAction: (() -> Void)?

    public init(_ cancel: @escaping () -> Void) {
        cancelAction = cancel
    }

    public init<C>(_ canceller: C) where C: Cancellable {
        cancelAction = canceller.cancel
    }

    deinit {
        cancelAction?()
    }

    final public func cancel() {
        let action = lock.withLock { () -> (() -> Void)? in
            defer { cancelAction = nil }
            return cancelAction
        }
        action?()
    }

    final public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public static func == (lhs: AnyCancellable, rhs: AnyCancellable) -> Bool {
        lhs === rhs
    }
}

extension AnyCancellable {
    final public func store<C>(in collection: inout C) where C: RangeReplaceableCollection, C.Element == AnyCancellable {
        collection.append(self)
    }

    final public func store(in set: inout Set<AnyCancellable>) {
        set.insert(self)
    }
}

extension Cancellable {
    public func store<C>(in collection: inout C) where C: RangeReplaceableCollection, C.Element == AnyCancellable {
        AnyCancellable(self).store(in: &collection)
    }

    public func store(in set: inout Set<AnyCancellable>) {
        AnyCancellable(self).store(in: &set)
    }
}
