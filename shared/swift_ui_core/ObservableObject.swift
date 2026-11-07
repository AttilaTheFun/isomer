// `ObservableObject` models (Combine's), as SwiftUI takes them:
// `@StateObject` (a view's own, made once), `@ObservedObject` (one passed in),
// `@EnvironmentObject` with `.environmentObject(_:)`, and `.onReceive(_:)`.
//
// A view holding one subscribes to its `objectWillChange` when its
// properties are connected, before its body runs (State.swift): a send
// marks the view's property key changed, as a `@State` write does, so the
// view (and what reads it) rebuilds next frame. The subscription lives in
// the view's state storage, by the property's key, and moves to another
// object when the view is given one; it ends when the view is gone.
//
// Off Apple platforms Combine is Isomer's (frameworks/combine); on a Mac
// (the core's host tests) and in a compiled feature, Apple's.

#if canImport(Combine)
import Combine

/// A view's subscription to an object's `objectWillChange`, kept in its
/// state storage under the property's key.
final class _ObjectObservation {
    /// "<view path>#<property>": the key a send marks changed.
    var key = ""
    private(set) var object: AnyObject?
    private var cancellable: AnyCancellable?

    /// Observes `object` (the same one again: nothing to do).
    func observe<Object: ObservableObject>(_ object: Object, key: String) {
        self.key = key
        if let current = self.object, current === object, cancellable != nil { return }
        self.object = object
        cancellable = object.objectWillChange.sink { _ in _observedObjectWillChange(key) }
    }

    func stop() {
        cancellable = nil
        object = nil
    }
}

/// An object a view observes is about to change: the view rebuilds next
/// frame. (Sent on another thread, it reaches the runtime as an
/// `@Observable`'s change does: ObservationSupport.swift.)
private func _observedObjectWillChange(_ key: String) {
    let runtime = Runtime.shared
    // A view that is gone: nothing to build again.
    guard let hash = key.firstIndex(of: "#"), runtime.viewMayBeLive(key[..<hash]) else { return }
    runtime.stateDidChange(key: key)
    runtime.requestFrame()
}

/// The observation for the property at `key`, made the first time.
private func _observation(in storage: StateStorage, key: String) -> _ObjectObservation {
    if let existing = storage.locations[key] as? _ObjectObservation { return existing }
    let made = _ObjectObservation()
    storage.locations[key] = made
    return made
}

// MARK: - ObservedObject

/// `@ObservedObject var model: Model`: an object passed to the view, which
/// rebuilds when it sends `objectWillChange`. `$model.title` is a binding
/// to one of its properties.
@MainActor @preconcurrency
@propertyWrapper
public struct ObservedObject<ObjectType>: _DynamicProperty where ObjectType: ObservableObject {
    @MainActor @preconcurrency
    @dynamicMemberLookup
    public struct Wrapper {
        let root: ObjectType

        public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, Subject>) -> Binding<Subject> {
            let root = self.root
            return Binding(get: { root[keyPath: keyPath] }, set: { root[keyPath: keyPath] = $0 })
        }
    }

    public var wrappedValue: ObjectType

    public init(initialValue: ObjectType) {
        self.init(wrappedValue: initialValue)
    }

    public init(wrappedValue: ObjectType) {
        self.wrappedValue = wrappedValue
    }

    public var projectedValue: ObservedObject<ObjectType>.Wrapper {
        Wrapper(root: wrappedValue)
    }

    nonisolated func _connect(storage: StateStorage, key: String, env: EnvironmentValues) {
        MainActor.assumeIsolated {
            _observation(in: storage, key: key).observe(wrappedValue, key: key)
        }
    }
}

// MARK: - StateObject

/// The object a `@StateObject` made, with its observation: made once, the
/// first time the view is connected, and kept while the view lives.
final class _StateObjectBox<ObjectType: ObservableObject> {
    let object: ObjectType
    let observation = _ObjectObservation()

    init(_ object: ObjectType) {
        self.object = object
    }
}

/// The struct's reference to its storage, connected before the body runs
/// (the struct is made again with each build of its view).
final class _StateObjectBacking<ObjectType: ObservableObject> {
    var box: _StateObjectBox<ObjectType>?
}

/// `@StateObject var model = Model()`: an object the view owns, made the
/// first time the view appears (the expression is not evaluated again) and
/// kept while it lives; the view rebuilds when it sends `objectWillChange`.
@MainActor @preconcurrency
@propertyWrapper
public struct StateObject<ObjectType>: _DynamicProperty where ObjectType: ObservableObject {
    let thunk: () -> ObjectType
    let backing = _StateObjectBacking<ObjectType>()

    nonisolated public init(wrappedValue thunk: @autoclosure @escaping () -> ObjectType) {
        self.thunk = thunk
    }

    public var wrappedValue: ObjectType {
        if let box = backing.box { return box.object }
        // Read before the view was connected (its initializer, say): an
        // object of its own, which the stored one replaces at connection.
        let object = thunk()
        backing.box = _StateObjectBox(object)
        return object
    }

    public var projectedValue: ObservedObject<ObjectType>.Wrapper {
        ObservedObject.Wrapper(root: wrappedValue)
    }

    nonisolated func _connect(storage: StateStorage, key: String, env: EnvironmentValues) {
        MainActor.assumeIsolated {
            let box: _StateObjectBox<ObjectType>
            if let existing = storage.locations[key] as? _StateObjectBox<ObjectType> {
                box = existing
            } else {
                box = _StateObjectBox(thunk())
                storage.locations[key] = box
            }
            backing.box = box
            box.observation.observe(box.object, key: key)
        }
    }
}

// MARK: - EnvironmentObject

/// The struct's reference to the object it found in the environment.
final class _EnvironmentObjectBacking<ObjectType: ObservableObject> {
    var object: ObjectType?
}

/// `@EnvironmentObject var model: Model`: the object of that type an
/// ancestor put in the environment with `.environmentObject(_:)`; the view
/// rebuilds when it sends `objectWillChange`. There must be one.
@MainActor @preconcurrency
@propertyWrapper
public struct EnvironmentObject<ObjectType>: _DynamicProperty where ObjectType: ObservableObject {
    @MainActor @preconcurrency
    @dynamicMemberLookup
    public struct Wrapper {
        let root: ObjectType

        public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, Subject>) -> Binding<Subject> {
            let root = self.root
            return Binding(get: { root[keyPath: keyPath] }, set: { root[keyPath: keyPath] = $0 })
        }
    }

    let backing = _EnvironmentObjectBacking<ObjectType>()

    public init() {}

    public var wrappedValue: ObjectType {
        guard let object = backing.object else {
            fatalError("No ObservableObject of type \(ObjectType.self) found. A View.environmentObject(_:) for \(ObjectType.self) may be missing as an ancestor of this view.")
        }
        return object
    }

    public var projectedValue: EnvironmentObject<ObjectType>.Wrapper {
        Wrapper(root: wrappedValue)
    }

    nonisolated func _connect(storage: StateStorage, key: String, env: EnvironmentValues) {
        MainActor.assumeIsolated {
            let object = env.environmentObjects[ObjectIdentifier(ObjectType.self)] as? ObjectType
            backing.object = object
            let observation = _observation(in: storage, key: key)
            if let object { observation.observe(object, key: key) } else { observation.stop() }
        }
    }
}

extension View {
    /// Puts `object` in the environment of this view's subtree, where
    /// `@EnvironmentObject` finds it by its type.
    nonisolated public func environmentObject<T>(_ object: T) -> some View where T: ObservableObject {
        _EnvironmentModifier(child: self, descend: "envobject") { env in
            env.environmentObjects[ObjectIdentifier(T.self)] = object
        }
    }
}

// MARK: - onReceive

extension View {
    /// Runs `action` with each value `publisher` sends while the view is
    /// shown. The subscription is the view's, by its position: made when it
    /// first appears and kept while it lives (a view built again with
    /// another publisher subscribes to that one).
    nonisolated public func onReceive<P>(_ publisher: P, perform action: @escaping (P.Output) -> Void) -> some View
    where P: Publisher, P.Failure == Never {
        _OnReceiveView(child: self, publisher: publisher, action: action)
    }
}

/// The subscription an `onReceive` keeps, with the latest action (the view
/// is made again with each build; its closure may capture new values).
final class _ReceiveSubscription<Output> {
    var action: (Output) -> Void
    var cancellable: AnyCancellable?
    /// The publisher subscribed to, when it is a class (a subject, the
    /// object's `objectWillChange`): another instance subscribes afresh.
    var source: AnyObject?

    init(action: @escaping (Output) -> Void) {
        self.action = action
    }
}

/// Holds the subscription in the view's state storage, through a
/// `_DynamicProperty` (the storage is reached only when properties are
/// connected, before the body runs).
struct _OnReceiveView<Content: View, P: Publisher>: View where P.Failure == Never {
    let child: Content
    let publisher: P
    let action: (P.Output) -> Void
    let receiver = _OnReceiveProperty<P>()

    var body: some View {
        receiver.update(publisher: publisher, action: action)
        return child
    }
}

/// The `_DynamicProperty` that finds `onReceive`'s subscription in storage.
final class _OnReceiveSlot<P: Publisher> where P.Failure == Never {
    var subscription: _ReceiveSubscription<P.Output>?
}

struct _OnReceiveProperty<P: Publisher>: _DynamicProperty where P.Failure == Never {
    let slot = _OnReceiveSlot<P>()

    func _connect(storage: StateStorage, key: String, env: EnvironmentValues) {
        if let existing = storage.locations[key] as? _ReceiveSubscription<P.Output> {
            slot.subscription = existing
        } else {
            let made = _ReceiveSubscription<P.Output>(action: { _ in })
            storage.locations[key] = made
            slot.subscription = made
        }
    }

    /// Subscribes to `publisher` (once per instance of a class publisher;
    /// once for a value publisher) and keeps `action` the latest.
    func update(publisher: P, action: @escaping (P.Output) -> Void) {
        guard let subscription = slot.subscription else { return }
        subscription.action = action
        let source: AnyObject? = type(of: publisher) is AnyClass ? (publisher as AnyObject) : nil
        if subscription.cancellable != nil {
            if source == nil || subscription.source === source { return }
        }
        subscription.source = source
        subscription.cancellable = publisher.sink { [weak subscription] value in subscription?.action(value) }
    }
}

// MARK: - The property wrappers, known by descriptor (DynamicPropertyLayout.swift)

/// A stand-in object, to name each wrapper's (generic) type.
private final class _DescriptorProbe: ObservableObject {}

let _combineDynamicPropertyTypes: [Any.Type] = [
    ObservedObject<_DescriptorProbe>.self, StateObject<_DescriptorProbe>.self,
    EnvironmentObject<_DescriptorProbe>.self, _OnReceiveProperty<Just<Int>>.self,
]

#else
let _combineDynamicPropertyTypes: [Any.Type] = []
#endif
