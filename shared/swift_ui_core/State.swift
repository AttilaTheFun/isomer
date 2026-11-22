// State management.
//
// SwiftUI reconstructs view values on every render pass, so `@State` needs
// out-of-band storage keyed by the view's structural identity. A `State`
// holds its initial value inline and, once connected, a reference to its
// location: the class `StateStorage` keeps for it (keyed by tree path +
// property label), which every copy of the view and every binding to it
// share. Before a view's `body` is evaluated, the runtime finds each dynamic
// property in the view by its type's layout (DynamicPropertyLayout.swift)
// and writes the property's location into its own copy of the view, as
// SwiftUI's graph installs a view's properties; `body`, and the closures it
// makes, run on that copy. Making a view's value allocates nothing for its
// states: a location is made once, when its view is first connected, and
// lasts as long as the view does ("A view's state lasts as long as the
// view", below).

/// Internal protocol adopted by property wrappers that need to be wired to
/// persistent storage (and/or the environment) before `body` runs.
protocol _DynamicProperty {
    /// Connects the property where it lies in the view's own copy: a state
    /// writes its location into itself. (The wrappers that still keep a box
    /// of their own fill the box, and leave themselves as they are.)
    mutating func _connect(storage: StateStorage, key: String, env: EnvironmentValues)
    /// Whether the view depends on state the core cannot see change per view
    /// (an observed object, app storage, focus): such a view, and the views
    /// around it, rebuild every frame instead of being reused.
    var _blocksSubtreeReuse: Bool { get }
}

extension _DynamicProperty {
    var _blocksSubtreeReuse: Bool { false }
}

final class StateStorage {
    var locations = _StateLocations()
    /// The type of the view whose properties are kept at each path: another
    /// type there is another view, whose state starts afresh (SwiftUI's
    /// identity is the type and the place). Every view that keeps state here
    /// (an owner) has an entry, which goes with its state when the view
    /// leaves the tree (`Runtime.dropStateOfViewsGone`).
    var types: [String: ObjectIdentifier] = [:]
    /// The owners as a tree: each one's nearest owner above it (the
    /// composite whose build it was first built in) and the owners just
    /// below each. A view built again alone (InPlace.swift) finds here the
    /// owners that were inside it, without looking at every owner's path.
    var parents: [String: String] = [:]
    var children: [String: Set<String>] = [:]
    /// Owners first given state outside any frame's build (drawn chrome,
    /// built as the renderer draws; a menu's content built as it opens): no
    /// build says whether they are still there, so their state is kept, as
    /// every view's was before.
    var unmanaged: Set<String> = []
    /// The place that kept each owner while it was not built (an unselected
    /// tab, a list's row off screen), asked first next time: walking up an
    /// owner's path to find it makes a string for each step.
    var keptBy: [String: String] = [:]
}

/// The kept properties by key ("<view path>#<property>"), and the keys of
/// each owner (the view path before the key's last "#"), so a view's state
/// can go without a look at every key.
struct _StateLocations {
    private var objects: [String: AnyObject] = [:]
    private var keysByOwner: [String: [String]] = [:]

    subscript(key: String) -> AnyObject? {
        get { objects[key] }
        set {
            guard let newValue else {
                guard objects.removeValue(forKey: key) != nil else { return }
                let owner = _stateOwner(key)
                keysByOwner[owner]?.removeAll { $0 == key }
                if keysByOwner[owner]?.isEmpty == true { keysByOwner[owner] = nil }
                return
            }
            // (Each key's owner worked out once, as it is first kept.)
            if objects.updateValue(newValue, forKey: key) == nil { keysByOwner[_stateOwner(key), default: []].append(key) }
        }
    }

    var count: Int { objects.count }

    /// Forgets every property `owner` keeps; returns their keys.
    @discardableResult
    mutating func removeAll(ownedBy owner: String) -> [String] {
        guard let keys = keysByOwner.removeValue(forKey: owner) else { return [] }
        for key in keys { objects[key] = nil }
        return keys
    }
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

/// A state's value while its view lives: kept in `StateStorage` under the
/// state's key, referenced by every connected copy of the view and by every
/// binding projected from it (Apple's location). The one object a state
/// costs, made once per view and property.
final class _StateLocation<Value> {
    var value: Value
    /// "<view path>#<property>": where a write marks the view's subtree
    /// changed for reuse.
    var key: String = ""

    init(_ value: Value) {
        self.value = value
    }

    /// The value, read by the view whose build is running: which views read
    /// it, for a change to rebuild those (through a binding too).
    var current: Value {
        _noteStateRead(key)
        return value
    }

    /// Writes the value. The same value again changes nothing, as in
    /// SwiftUI: no frame for it (a chat setting `inView = true` for each row
    /// shown cost a whole build each).
    func write(_ newValue: Value) {
        let same = _sameStateValue(value, newValue)
        value = newValue
        guard !same else { return }
        Runtime.shared.stateDidChange(key: key)
        Runtime.shared.requestFrame()
    }

    /// The location kept under `key`, made the first time (and only then
    /// is `initialValue` asked for: a private state's initial value is made
    /// once, however often its view's value is).
    static func connect(_ storage: StateStorage, key: String, initialValue: () -> Value) -> _StateLocation<Value> {
        if let location = storage.locations[key] as? _StateLocation<Value> { return location }
        let location = _StateLocation(initialValue())
        location.key = key
        storage.locations[key] = location
        let runtime = Runtime.shared
        runtime.stateKeys.insert(key)
        runtime.stateLocationsMade &+= 1
        return location
    }
}

@propertyWrapper
public struct State<Value>: _DynamicProperty {
    /// The value it starts from, held inline as Apple's `State` holds it:
    /// read until the view is connected, and its location's first value.
    var _value: Value
    /// Where the value is kept while the view lives: written into the
    /// view's own copy before its body runs (nil in a view's value as made).
    var _location: _StateLocation<Value>?

    public init(wrappedValue value: Value) {
        _value = value
    }

    public init(initialValue value: Value) {
        _value = value
    }

    public var wrappedValue: Value {
        get {
            if let location = _location { return location.current }
            return _value
        }
        nonmutating set {
            // A state not connected yet (read in a view's initializer, say)
            // keeps no write, as SwiftUI's doesn't: there is no place for
            // it until the view is in the tree.
            _location?.write(newValue)
        }
    }

    public var projectedValue: Binding<Value> {
        // A binding to the location itself, the same every frame: a subtree
        // holding it (a row given `$opened` in the environment) can be
        // reused. Not connected: the value it starts from, which nothing
        // keeps.
        guard let location = _location else { return .constant(_value) }
        return Binding(_location: location)
    }

    mutating func _connect(storage: StateStorage, key: String, env: EnvironmentValues) {
        let initial = _value
        _location = _StateLocation.connect(storage, key: key) { initial }
    }
}

// MARK: - The @State macro's storage

/// The storage SwiftUI's `@State` macro gives a private state with an
/// initial value (`__name`): the closure that makes the value, called once,
/// when the view is first connected, not each time the view's value is made;
/// then, as a `State`, the location.
@_documentation(visibility: internal)
public struct LazyState<Value>: _DynamicProperty {
    /// The initial value, or the closure that makes it (Apple's
    /// `LazyState.Storage`).
    enum Storage {
        case thunk(() -> Value)
        case value(Value)
    }

    var _storage: Storage
    var _location: _StateLocation<Value>?

    public init(initialValue thunk: @escaping () -> Value) {
        _storage = .thunk(thunk)
    }

    public init(_initialValue: Value) {
        _storage = .value(_initialValue)
    }

    /// The initial value, made now when it is a closure's.
    static func _make(_ storage: Storage) -> Value {
        switch storage {
        case .thunk(let make): return make()
        case .value(let value): return value
        }
    }

    public var wrappedValue: Value {
        get {
            if let location = _location { return location.current }
            // Not connected: the initial value, which nothing keeps.
            return LazyState._make(_storage)
        }
        nonmutating set { _location?.write(newValue) }
    }

    public var projectedValue: Binding<Value> {
        guard let location = _location else { return .constant(LazyState._make(_storage)) }
        return Binding(_location: location)
    }

    mutating func _connect(storage: StateStorage, key: String, env: EnvironmentValues) {
        let initial = _storage
        _location = _StateLocation.connect(storage, key: key) { LazyState._make(initial) }
    }
}

// Its location is read and written on the main actor only, as a State's
// is: unchecked, as State itself makes no promise of its own.
extension LazyState: @unchecked Sendable where Value: Sendable {}

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
    /// Where the value is read and written: a state's location itself
    /// (`$state`: no closures made for it), or the closures an app (or a
    /// binding derived from another) gave.
    let _source: _BindingSource<Value>
    /// Set when the binding projects an `@AppStorage`: hosts can persist
    /// host-side state (e.g. a sidebar arrangement) under the same key.
    var _storageKey: String?
    /// The identity and state key a binding made from closures was given
    /// (`_identity`, `_stateKey`).
    private var givenIdentity: AnyHashable?
    private var givenStateKey: String?

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        _source = .closures(get: get, set: set)
    }

    /// A binding to a state's location (its `projectedValue`).
    init(_location location: _StateLocation<Value>) {
        _source = .location(location)
    }

    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { _ in })
    }

    /// What the binding projects (a `@State`'s location, and the key path
    /// to a part of it), when known: bindings with the same identity read
    /// and write the same value, so they compare equal for subtree reuse.
    var _identity: AnyHashable? {
        get {
            if case .location(let location) = _source { return AnyHashable(ObjectIdentifier(location)) }
            return givenIdentity
        }
        set { givenIdentity = newValue }
    }

    /// The key of the state it projects ("<view path>#<property>"), when
    /// known: a view that reads the value depends on that state, and is
    /// rebuilt when it changes (`_bindingDependencies`).
    var _stateKey: String? {
        get {
            if case .location(let location) = _source { return location.key }
            return givenStateKey
        }
        set { givenStateKey = newValue }
    }

    /// The value, read as the state's own reader does (not counted as a
    /// read of this binding: a binding derived from it counts its own).
    func _read() -> Value {
        switch _source {
        case .location(let location): return location.current
        case .closures(let get, _): return get()
        }
    }

    func _write(_ newValue: Value) {
        switch _source {
        case .location(let location): location.write(newValue)
        case .closures(_, let set): set(newValue)
        }
    }

    public var wrappedValue: Value {
        get {
            // A build that reads the value depends on it: not reused when
            // only the binding (not its value) is compared.
            switch _source {
            case .location(let location):
                _bindingReadKeys.append(location.key)
                return location.current
            case .closures(let get, _):
                if givenIdentity != nil { _bindingReadKeys.append(givenStateKey ?? "") }
                return get()
            }
        }
        nonmutating set { _write(newValue) }
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
        let base = self
        var binding = Binding<Subject>(
            get: { base._read()[keyPath: keyPath] },
            set: { newValue in
                var value = base._read()
                value[keyPath: keyPath] = newValue
                base._write(value)
            }
        )
        binding._identity = _identity.map { _BindingPart(base: $0, keyPath: keyPath) }
        binding._stateKey = _stateKey
        return binding
    }
}

/// Where a binding's value is.
enum _BindingSource<Value> {
    /// A state's location, read and written directly.
    case location(_StateLocation<Value>)
    /// Closures that read and write it.
    case closures(get: () -> Value, set: (Value) -> Void)
}

/// Connects the dynamic properties of a view, an app or a scene (`value`,
/// its own copy) to persistent storage and the current environment: each
/// state's location written into it, where its type's layout says the
/// property lies (DynamicPropertyLayout.swift).
func _connectDynamicProperties<T>(
    of value: inout T, path: String, storage: StateStorage, env: EnvironmentValues
) {
    Runtime.shared.noteStateOwner(path, type: ObjectIdentifier(T.self), storage: storage)
    if _connectByLayout(of: &value, path: path, storage: storage, env: env) { return }
    // Mirror for a type whose fields are not inline (not a struct: SwiftUI's
    // views are structs). Each property is connected in a copy, which has
    // no place to go back to: the wrappers that keep a box of their own
    // fill it, but a state has no location there.
    connectDynamicProperties(ofValue: value, prefix: path + "#", storage: storage, env: env)
}

/// The body of `view`, evaluated on its own copy with its properties
/// connected (`_connectDynamicProperties`), as SwiftUI evaluates a view's
/// body once its graph has installed the view's properties: the body, and
/// the closures it makes (a Button's action), see the view's state. The
/// view's value as given is left as it was (the reuse checks compare it
/// with the next frame's, made without locations too).
@MainActor
func _connectedBody(of view: any View, ctx: BuildContext) -> any View {
    _connectedBody(opening: view, path: ctx.path, storage: ctx.storage, env: ctx.env)
}

@MainActor
private func _connectedBody<V: View>(opening view: V, path: String, storage: StateStorage, env: EnvironmentValues) -> any View {
    // (The copy is on the stack, the view's type known here: written in an
    // existential, a view larger than its inline buffer would be copied to
    // a box of its own.)
    var connected = view
    _connectDynamicProperties(of: &connected, path: path, storage: storage, env: env)
    return connected.body
}

/// A value's dynamic properties, and those of a `ViewModifier` it holds (a
/// modifier's own `@State` belongs to the view it modifies).
private func connectDynamicProperties(ofValue value: Any, prefix: String, storage: StateStorage, env: EnvironmentValues) {
    let mirror = Mirror(reflecting: value)
    var index = 0
    for child in mirror.children {
        let label = child.label ?? String(index)
        if var property = child.value as? _DynamicProperty {
            if property._blocksSubtreeReuse { Runtime.shared.markBuildVolatile() }
            property._connect(storage: storage, key: prefix + label, env: env)
        } else if child.value is any ViewModifier {
            connectDynamicProperties(ofValue: child.value, prefix: prefix + label + ".", storage: storage, env: env)
        }
        index += 1
    }
}

// MARK: - A view's state lasts as long as the view

// SwiftUI keeps a view's state while the view is in the hierarchy and lets
// it go with the view: a view an `if` swaps out, one given a new `.id`, a
// ForEach's item removed or a sheet closed comes back with its initial
// values. Here state is kept by the view's place (`StateStorage`), and it
// used to go only when another type of view took the place; now it goes
// when nothing is at the place any more:
//   - each build records the owners it reaches (`liveStateOwners`): every
//     view whose state it connects, and, for a subtree handed back unbuilt,
//     the owners its cache entry recorded as it was built
//     (`_BuildCacheEntry.owners`; those of the entries inside it are found
//     through `inner`, as `touchBuildCache` keeps them);
//   - a container that keeps views it doesn't build says so each frame
//     (`keepState(under:)`, `keepStateOfRows(of:)`: a TabView's unselected
//     tabs, a stack's levels below its top, a List's rows off screen, a
//     geometry reader's content, built as it is laid out), as a
//     registration a reused container makes again;
//   - after a whole build, an owner neither reached nor under a kept place
//     loses its state (`dropStateOfViewsGone`); after a view built again
//     alone, so do the owners that were inside it and are no longer
//     (`dropStateGone(inside:)`), found through the owners' tree.
// Its animations go with it (`Animator.forgetAnimations(of:)`), so a view
// shown again starts from its initial state, and its `.onAppear` starts
// what it starts. The root's state stays; so does state first kept outside
// a frame's build (`StateStorage.unmanaged`).

extension Runtime {
    /// The view at `path` keeps state in `storage` (its properties are being
    /// connected, or it is a navigation stack keeping its path): recorded as
    /// a view this build reaches and, the first time, where it sits among
    /// the owners.
    func noteStateOwner(_ path: String, type: ObjectIdentifier, storage: StateStorage) {
        let previous = storage.types[path]
        if previous != type {
            if previous != nil {
                // Another type of view at this place (a story switched in
                // place, a branch's other view): the old one's state goes,
                // so a property of the same name and type isn't the old
                // view's.
                storage.locations.removeAll(ownedBy: path)
            } else if recordingStateOwners || geometryBuildDepth > 0 {
                // Below the composite being built (its own build has pushed
                // it already: the one before it).
                let stack = compositePathStack
                if let above = stack.last == path ? stack.dropLast().last : stack.last, storage.parents[path] == nil {
                    storage.parents[path] = above
                    storage.children[above, default: []].insert(path)
                }
            } else {
                storage.unmanaged.insert(path)
            }
            storage.types[path] = type
        }
        guard recordingStateOwners, storage === self.storage else { return }
        liveStateOwners.insert(path)
        if !stateOwnerStack.isEmpty { stateOwnerStack[stateOwnerStack.count - 1].append(path) }
    }

    /// The views at and under each of `paths` keep their state this frame
    /// though they are not built: a TabView's unselected tabs, a stack's
    /// levels below its top, a geometry reader's content (built as it is
    /// laid out, after the frame's build). Made again when a view around the
    /// container is reused.
    @MainActor
    func keepState(under paths: [String]) {
        registerFrameEffect(local: true) { Runtime.shared.keptStatePrefixes.formUnion(paths) }
    }

    /// The rows of the List at `list` keep their state while they are off
    /// the rows it builds: its rows now, built or not (`listRowPaths`). A
    /// row taken out of the list is no longer one of them.
    @MainActor
    func keepStateOfRows(of list: String) {
        registerFrameEffect(local: true) { Runtime.shared.keptStateLists.insert(list) }
    }

    /// Whether `owner`, which this frame's build did not reach, is at or
    /// under a place kept this frame.
    func stateIsKept(_ owner: String) -> Bool {
        guard !keptStatePrefixes.isEmpty || !keptStateLists.isEmpty else { return false }
        // The place that kept it last time, most often the place now.
        if let place = storage.keptBy[owner], isKeptPlace(place) { return true }
        var path = Substring(owner)
        while true {
            let place = String(path)
            if isKeptPlace(place) {
                storage.keptBy[owner] = place
                return true
            }
            guard let slash = path.lastIndex(of: "/") else { break }
            path = path[..<slash]
        }
        storage.keptBy[owner] = nil
        return false
    }

    private func isKeptPlace(_ path: String) -> Bool {
        if keptStatePrefixes.contains(path) { return true }
        // A row of a list that keeps its rows: one of its rows now.
        guard !keptStateLists.isEmpty, let row = listRowIndex[path], keptStateLists.contains(row.list),
              let rows = listRowPaths[row.list], row.index < rows.count, rows[row.index] == path
        else { return false }
        return true
    }

    /// After a whole build: the state of every view it did not reach, and
    /// that no container keeps, goes. A whole build reaches every view in
    /// the tree: each one built connects its state, and each subtree reused
    /// hands over the owners recorded as it was built.
    func dropStateOfViewsGone() {
        var gone: [String] = []
        for owner in storage.types.keys
        where !liveStateOwners.contains(owner) && owner != "root" && !storage.unmanaged.contains(owner) && !stateIsKept(owner) {
            gone.append(owner)
        }
        dropState(of: gone)
    }

    /// After the view at `site` was built again alone: the views that were
    /// inside it and that its build no longer reached go, unless a
    /// container in it keeps them. Only its own subtree of owners is looked
    /// at, and only below the owners it reached: below one that is kept or
    /// gone, every owner is too.
    func dropStateGone(inside site: String) {
        guard let below = storage.children[site] else { return }
        var gone: [String] = []
        func collect(_ owner: String) {
            gone.append(owner)
            for inner in storage.children[owner] ?? [] { collect(inner) }
        }
        func visit(_ owners: Set<String>) {
            for owner in owners {
                if liveStateOwners.contains(owner) {
                    if let deeper = storage.children[owner] { visit(deeper) }
                } else if !storage.unmanaged.contains(owner), !stateIsKept(owner) {
                    collect(owner)
                }
            }
        }
        visit(below)
        dropState(of: gone)
    }

    /// Forgets the state of views gone, and what is kept about them: their
    /// subtrees kept for reuse (which would bring them back as they were),
    /// the states they read and were read by, their animations.
    private func dropState(of gone: [String]) {
        guard !gone.isEmpty else { return }
        for owner in gone {
            storage.types[owner] = nil
            for key in storage.locations.removeAll(ownedBy: owner) { stateReaders[key] = nil }
            if let above = storage.parents.removeValue(forKey: owner) {
                storage.children[above]?.remove(owner)
                if storage.children[above]?.isEmpty == true { storage.children[above] = nil }
            }
            storage.children[owner] = nil
            storage.keptBy[owner] = nil
            buildCache[owner] = nil
            noteStateReads(path: owner, [])
            volatileOwners.remove(owner)
            animator.forgetAnimations(of: owner)
        }
        // (Its rebuild site stays until its node is freed and the sites are
        // pruned, `endReuseFrame`: a write to the gone view's state by a
        // closure still holding it finds the site's node gone and builds
        // nothing, where one with no site would build the view above.)
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
