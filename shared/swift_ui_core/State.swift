// State management.
//
// SwiftUI reconstructs view values on every render pass, so `@State` needs
// out-of-band storage keyed by the view's structural identity. Before a
// view's `body` is evaluated, the runtime walks the view value with `Mirror`
// and connects every dynamic property to a persistent location owned by
// `StateStorage` (keyed by tree path + property label). The connection
// mutates a class box *referenced* by the property wrapper struct, which is
// how the freshly-copied view value ends up seeing persistent state.

/// Internal protocol adopted by property wrappers that need to be wired to
/// persistent storage (and/or the environment) before `body` runs.
protocol _DynamicProperty {
    func _connect(storage: StateStorage, key: String, env: EnvironmentValues)
    /// Whether the view depends on state the core cannot see change per view
    /// (an observed object, app storage, focus): such a view, and the views
    /// around it, rebuild every frame instead of being reused.
    var _blocksSubtreeReuse: Bool { get }
}

extension _DynamicProperty {
    var _blocksSubtreeReuse: Bool { false }
}

final class StateStorage {
    var locations: [String: AnyObject] = [:]
}

/// Whether `new` is `old` again: Equatable values by `==`; anything else
/// is a change.
func _sameStateValue<Value>(_ old: Value, _ new: Value) -> Bool {
    // (A type with no Equatable conformance at all is answered without the
    // runtime's scan: ConformanceIndex.swift.)
    guard _mayConform(Value.self, .equatable), let old = old as? any Equatable else { return false }
    return _equalsSame(old, new)
}

private func _equalsSame<T: Equatable>(_ lhs: T, _ rhs: Any) -> Bool {
    guard let rhs = rhs as? T else { return false }
    return lhs == rhs
}

final class _StateLocation<Value> {
    var value: Value
    /// "<view path>#<property>": where a write marks the view's subtree
    /// changed for reuse.
    var key: String = ""

    init(_ value: Value) {
        self.value = value
    }
}

/// Mutable backing referenced from the `State` struct; the struct itself is
/// immutable, but the class instance it points to can be re-wired.
final class _StateBacking<Value> {
    var location: _StateLocation<Value>?
    /// The value to start from, or (a LazyState's) the closure that makes
    /// it, called once, when it is first wanted.
    private var initial: Initial

    enum Initial {
        case value(Value)
        case thunk(() -> Value)
    }

    init(_ initialValue: Value) {
        initial = .value(initialValue)
    }

    init(thunk: @escaping () -> Value) {
        initial = .thunk(thunk)
    }

    var initialValue: Value {
        get {
            switch initial {
            case .value(let value):
                return value
            case .thunk(let make):
                let value = make()
                initial = .value(value)
                return value
            }
        }
        set { initial = .value(newValue) }
    }
}

@propertyWrapper
public struct State<Value>: _DynamicProperty {
    let backing: _StateBacking<Value>

    public init(wrappedValue: Value) {
        backing = _StateBacking(wrappedValue)
    }

    public init(initialValue: Value) {
        self.init(wrappedValue: initialValue)
    }

    init(backing: _StateBacking<Value>) {
        self.backing = backing
    }

    public var wrappedValue: Value {
        get {
            // Which views read it, for a change to rebuild those (through
            // a binding too: its getter comes here).
            if let location = backing.location { _noteStateRead(location.key) }
            return backing.location?.value ?? backing.initialValue
        }
        nonmutating set {
            if let location = backing.location {
                // The same value again changes nothing, as in SwiftUI: no
                // frame for it (a chat setting `inView = true` for each row
                // shown cost a whole build each).
                let same = _sameStateValue(location.value, newValue)
                location.value = newValue
                guard !same else { return }
                Runtime.shared.stateDidChange(key: location.key)
                Runtime.shared.requestFrame()
            } else {
                backing.initialValue = newValue
            }
        }
    }

    public var projectedValue: Binding<Value> {
        var binding = Binding(
            get: { self.wrappedValue },
            set: { self.wrappedValue = $0 }
        )
        // The state it projects, the same every frame: a subtree holding the
        // binding (a row given `$opened` in the environment) can be reused.
        binding._identity = backing.location.map { ObjectIdentifier($0) as AnyHashable }
        binding._stateKey = backing.location?.key
        return binding
    }

    func _connect(storage: StateStorage, key: String, env: EnvironmentValues) {
        if let location = storage.locations[key] as? _StateLocation<Value> {
            backing.location = location
        } else {
            let location = _StateLocation(backing.initialValue)
            location.key = key
            storage.locations[key] = location
            backing.location = location
            Runtime.shared.stateKeys.insert(key)
        }
    }
}

// MARK: - The @State macro's storage

/// The storage SwiftUI's `@State` macro gives a private state with an
/// initial value (`__name`): the value is made from its closure once, when
/// the view is first installed, not each time the view's value is made.
/// Otherwise a `State`: the same location, read and written the same way.
@_documentation(visibility: internal)
public struct LazyState<Value>: _DynamicProperty {
    let state: State<Value>

    public init(initialValue thunk: @escaping () -> Value) {
        state = State(backing: _StateBacking(thunk: thunk))
    }

    public init(_initialValue: Value) {
        state = State(initialValue: _initialValue)
    }

    public var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }

    public var projectedValue: Binding<Value> { state.projectedValue }

    func _connect(storage: StateStorage, key: String, env: EnvironmentValues) {
        state._connect(storage: storage, key: key, env: env)
    }
}

extension LazyState: Sendable where Value: Sendable {}

extension LazyState where Value: ExpressibleByNilLiteral {
    public init() {
        self.init(initialValue: { nil })
    }
}

extension State {
    /// The storage of a private `@State` with an initial value, made from
    /// the closure that makes the value (the macro's `__name`).
    public static func _makeStorage(_ makeInitialValue: @escaping () -> Value) -> LazyState<Value> {
        LazyState(initialValue: makeInitialValue)
    }

    @_disfavoredOverload
    public static func _makeStorage(_ makeInitialValue: @escaping () -> Value) -> State<Value> {
        State<Value>(wrappedValue: makeInitialValue())
    }

    /// The same storage from a value already made (an initializer's).
    public static func _makeStorage(initialValue: Value) -> LazyState<Value> {
        LazyState(_initialValue: initialValue)
    }

    @_disfavoredOverload
    public static func _makeStorage(initialValue: Value) -> State<Value> {
        State<Value>(initialValue: initialValue)
    }

    public static func _makeStorageFrozen(_ makeInitialValue: @escaping () -> Value) -> LazyState<Value> {
        LazyState(initialValue: makeInitialValue)
    }

    @_disfavoredOverload
    public static func _makeStorageFrozen(_ makeInitialValue: @escaping () -> Value) -> State<Value> {
        State<Value>(initialValue: makeInitialValue())
    }

    public static func _makeStorageFrozen(initialValue: Value) -> LazyState<Value> {
        LazyState(_initialValue: initialValue)
    }

    @_disfavoredOverload
    public static func _makeStorageFrozen(initialValue: Value) -> State<Value> {
        State<Value>(initialValue: initialValue)
    }
}

/// The macro's `_name` before it is set: nil of the State the closure would
/// make (the closure only names the type).
@_transparent
public func _stateNil<T>(of _: () -> T) -> T? { nil }

/// A state's value read: by the view whose build is running (InPlace.swift's
/// readers), or, in a GeometryReader's content built while the tree is
/// encoded, by no view the core can name (its owner rebuilds instead).
func _noteStateRead(_ key: String) {
    let runtime = Runtime.shared
    if !runtime.stateReadStack.isEmpty {
        runtime.stateReadStack[runtime.stateReadStack.count - 1].append(key)
    } else if runtime.geometryBuildDepth > 0 {
        runtime.keysReadOutsideBuild.insert(key)
    }
}

@dynamicMemberLookup
@propertyWrapper
public struct Binding<Value> {
    let getter: () -> Value
    let setter: (Value) -> Void
    /// Set when the binding projects an `@AppStorage`: hosts can persist
    /// host-side state (e.g. a sidebar arrangement) under the same key.
    var _storageKey: String?
    /// What the binding projects (a `@State`'s storage, and the key path to
    /// a part of it), when known: bindings with the same identity read and
    /// write the same value, so they compare equal for subtree reuse.
    var _identity: AnyHashable?
    /// The key of the state it projects ("<view path>#<property>"), when
    /// known: a view that reads the value depends on that state, and is
    /// rebuilt when it changes (`_bindingDependencies`).
    var _stateKey: String?

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        getter = get
        setter = set
    }

    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { _ in })
    }

    public var wrappedValue: Value {
        get {
            // A build that reads the value depends on it: not reused when
            // only the binding (not its value) is compared.
            if _identity != nil { _bindingReadKeys.append(_stateKey ?? "") }
            return getter()
        }
        nonmutating set { setter(newValue) }
    }

    public var projectedValue: Binding<Value> { self }

    /// What lets a closure take a binding as `$item` (`ForEach($items) {
    /// $item in … }`): the parameter is the binding, `item` its value.
    public init(projectedValue: Binding<Value>) {
        self = projectedValue
    }

    /// Derive a binding to one property of the value (`$camera.zoom`),
    /// matching the real Binding's dynamic member lookup.
    public subscript<Subject>(dynamicMember keyPath: WritableKeyPath<Value, Subject>) -> Binding<Subject> {
        var binding = Binding<Subject>(
            get: { getter()[keyPath: keyPath] },
            set: { newValue in
                var value = getter()
                value[keyPath: keyPath] = newValue
                setter(value)
            }
        )
        binding._identity = _identity.map { _BindingPart(base: $0, keyPath: keyPath) }
        binding._stateKey = _stateKey
        return binding
    }
}

/// Connects every `@State`-like property of `view` to persistent storage and
/// the current environment.
func connectDynamicProperties(
    of view: any View, path: String, storage: StateStorage, env: EnvironmentValues
) {
    // In place, by the type's layout (DynamicPropertyLayout.swift); Mirror
    // for a type whose fields are not inline.
    if _connectByLayout(of: view, path: path, storage: storage, env: env) { return }
    connectDynamicProperties(ofValue: view, prefix: path + "#", storage: storage, env: env)
}

/// A value's dynamic properties, and those of a `ViewModifier` it holds (a
/// modifier's own `@State` belongs to the view it modifies).
private func connectDynamicProperties(ofValue value: Any, prefix: String, storage: StateStorage, env: EnvironmentValues) {
    let mirror = Mirror(reflecting: value)
    var index = 0
    for child in mirror.children {
        let label = child.label ?? String(index)
        if let property = child.value as? _DynamicProperty {
            if property._blocksSubtreeReuse { Runtime.shared.markBuildVolatile() }
            property._connect(storage: storage, key: prefix + label, env: env)
        } else if child.value is any ViewModifier {
            connectDynamicProperties(ofValue: child.value, prefix: prefix + label + ".", storage: storage, env: env)
        }
        index += 1
    }
}

// MARK: - AppStorage

/// `@AppStorage("key") var value = default`: a value kept in `UserDefaults`
/// (the standard suite, or the `store` given), shared by every view that
/// names the key, as Apple's. A write builds the views again; Isomer's
/// `UserDefaults` keeps the suite in the app's Library/Preferences, which
/// persists on every platform.
@propertyWrapper
public struct AppStorage<Value>: _DynamicProperty {
    let key: String
    let defaultValue: Value
    let store: UserDefaults?
    let read: (UserDefaults, String) -> Value?
    let write: (UserDefaults, String, Value) -> Void

    init(
        _ key: String, store: UserDefaults?, defaultValue: Value,
        read: @escaping (UserDefaults, String) -> Value?, write: @escaping (UserDefaults, String, Value) -> Void
    ) {
        self.key = key
        self.store = store
        self.defaultValue = defaultValue
        self.read = read
        self.write = write
    }

    // Apple's initializers, one per kind of value.
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Bool {
        self.init(key, store: store, defaultValue: wrappedValue, read: { $0.object(forKey: $1) as? Bool },
                  write: { $0.set($2, forKey: $1) })
    }

    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Int {
        self.init(key, store: store, defaultValue: wrappedValue, read: { $0.object(forKey: $1) as? Int },
                  write: { $0.set($2, forKey: $1) })
    }

    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Double {
        self.init(key, store: store, defaultValue: wrappedValue, read: { $0.object(forKey: $1) as? Double },
                  write: { $0.set($2, forKey: $1) })
    }

    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == String {
        self.init(key, store: store, defaultValue: wrappedValue, read: { $0.string(forKey: $1) },
                  write: { $0.set($2, forKey: $1) })
    }

    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == URL {
        self.init(key, store: store, defaultValue: wrappedValue, read: { $0.url(forKey: $1) },
                  write: { $0.set($2, forKey: $1) })
    }

    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Data {
        self.init(key, store: store, defaultValue: wrappedValue, read: { $0.data(forKey: $1) },
                  write: { $0.set($2, forKey: $1) })
    }

    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil)
    where Value: RawRepresentable, Value.RawValue == String {
        self.init(key, store: store, defaultValue: wrappedValue,
                  read: { $0.string(forKey: $1).flatMap(Value.init(rawValue:)) },
                  write: { $0.set($2.rawValue, forKey: $1) })
    }

    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil)
    where Value: RawRepresentable, Value.RawValue == Int {
        self.init(key, store: store, defaultValue: wrappedValue,
                  read: { ($0.object(forKey: $1) as? Int).flatMap(Value.init(rawValue:)) },
                  write: { $0.set($2.rawValue, forKey: $1) })
    }

    /// A sidebar arrangement (`.tabViewCustomization($customization)`).
    public init(wrappedValue: Value = TabViewCustomization(), _ key: String, store: UserDefaults? = nil)
    where Value == TabViewCustomization {
        self.init(key, store: store, defaultValue: wrappedValue,
                  read: { $0.string(forKey: $1).flatMap(TabViewCustomization.init(wire:)) },
                  write: { $0.set($2.wire, forKey: $1) })
    }

    var defaults: UserDefaults { store ?? Runtime.shared.appStorageDefaults }

    public var wrappedValue: Value {
        get { read(defaults, key) ?? defaultValue }
        nonmutating set {
            write(defaults, key, newValue)
            Runtime.shared.setNeedsRender()
        }
    }

    public var projectedValue: Binding<Value> {
        var binding = Binding(get: { self.wrappedValue }, set: { self.wrappedValue = $0 })
        binding._storageKey = key
        return binding
    }

    func _connect(storage: StateStorage, key: String, env: EnvironmentValues) {}
}


/// A part of a bound value (`$state.member`), for a binding's identity.
struct _BindingPart: Hashable {
    let base: AnyHashable
    let keyPath: AnyKeyPath
}

/// Reads of identified bindings' values while views build, each the key of
/// the state read ("" when not known); see `beginCompositeBuild`.
nonisolated(unsafe) var _bindingReadKeys: [String] = []

/// The view path a state key belongs to (before its "#").
func _stateOwner(_ key: String) -> String {
    guard let mark = key.lastIndex(of: "#") else { return key }
    return String(key[..<mark])
}

/// What the view at `path` depends on through the bindings it read while
/// building (since `start`): the keys of state owned outside it (a change to
/// state at or below `path` rebuilds the view anyway); nil when a read was
/// of state whose key is not known (the view is then not reused).
func _bindingDependencies(since start: Int, path: String) -> Set<String>? {
    guard start < _bindingReadKeys.count else { return [] }
    var keys: Set<String> = []
    for key in _bindingReadKeys[start...] {
        if key.isEmpty { return nil }
        let owner = _stateOwner(key)
        if owner == path || _byteAfterPrefix(owner, path) == UInt8(ascii: "/") { continue }
        keys.insert(key)
    }
    return keys
}

/// A binding as subtree reuse sees it.
protocol _IdentifiedBinding {
    var _reuseIdentity: AnyHashable? { get }
}

extension Binding: _IdentifiedBinding {
    var _reuseIdentity: AnyHashable? { _identity }
}
