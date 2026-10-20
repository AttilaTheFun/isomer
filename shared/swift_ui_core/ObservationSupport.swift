// `@Observable` models (the Observation module), as SwiftUI takes them.
//
// A view's body is evaluated, and what it returns built, inside
// `withObservationTracking`: a later change to any property read there
// (a `ForEach`'s rows and a `Button`'s label included, which build after the
// body returns) marks that view changed — it, and the views around it,
// rebuild next frame, as a `@State` write does — and asks for a frame.
// A view that holds a model reads nothing of it until its body does, so
// holding one is no reason to rebuild: two views holding the same instance
// compare equal for reuse (Reuse.swift).
//
// Each tracking fires once and is gone (Observation's rule); a view rebuilt
// before anything it read changed leaves its earlier tracking in place,
// which, when it fires, marks the same view again.
//
// A view's tracking is its own: Observation adds what a tracking nested in
// another read to the one around it, so a property read by one view deep
// in the tree marked every view above it changed too (and a partial frame,
// InPlace.swift, built from the topmost). Where the runtime's tracking
// scope can be reached (the Swift runtime linked statically: wasm,
// Android), the scope around a view is set aside while the view builds.
// Elsewhere the views above are marked as before, which is correct, only
// coarser.
//
// `@Environment(Model.self)` / `.environment(model)` pass a model down the
// tree by its type, and `@Bindable` makes bindings to its properties.
//
// In a feature compiled against Isomer's frameworks on an Apple platform
// (ISOMER_COMPILED_FEATURE) Observation is Isomer's, available on every OS
// the app supports: nothing here is marked iOS 17 there.

#if canImport(Observation)
import Observation
#endif

#if canImport(Observation) && (os(WASI) || os(Android) || ISOMER_COMPILED_FEATURE)
// The Observation runtime's tracking scope (its ThreadLocal.cpp, or Isomer's
// ThreadLocal.swift in a compiled feature), as its own Swift reads it.
@_silgen_name("_swift_observation_tls_get")
private func _observationScope() -> UnsafeMutableRawPointer?
@_silgen_name("_swift_observation_tls_set")
private func _setObservationScope(_ scope: UnsafeMutableRawPointer?)
#endif

/// Evaluates `build` (a view's body and the build of what it returned)
/// tracking the observable properties it reads, for the view at `path`.
@MainActor
func _trackingObservation<T>(at path: String, _ build: () -> T) -> T {
    #if ISOMER_COMPILED_FEATURE
    // Isomer's Observation (a compiled feature): on every OS the app runs on.
    let enclosing = _observationScope()
    _setObservationScope(nil)
    defer { _setObservationScope(enclosing) }
    return withObservationTracking(build, onChange: { _observedPropertyWillChange(at: path) })
    #else
    #if canImport(Observation)
    if #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *) {
        #if os(WASI) || os(Android)
        // Not the enclosing view's tracking: what this view reads marks it.
        let enclosing = _observationScope()
        _setObservationScope(nil)
        defer { _setObservationScope(enclosing) }
        #endif
        return withObservationTracking(build, onChange: { _observedPropertyWillChange(at: path) })
    }
    #endif
    return build()
    #endif
}

/// A property a view's body read is about to change: the view rebuilds next
/// frame. (A model changed off the main thread reaches the runtime as a
/// `@Published` one does.)
private func _observedPropertyWillChange(at path: String) {
    let runtime = Runtime.shared
    // A view that is gone: nothing to build again.
    guard runtime.viewMayBeLive(Substring(path)) else { return }
    runtime.stateDidChange(key: path + "#observed")
    runtime.requestFrame()
}

#if canImport(Observation)

/// Whether `a` and `b` are the same instance of an `@Observable` class: a
/// view's input that is one compares by identity, its properties being
/// tracked where they are read.
func _sameObservableInstance(_ a: Any, _ b: Any) -> Bool? {
    #if !ISOMER_COMPILED_FEATURE
    guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *) else { return nil }
    #endif
    guard type(of: a) is AnyClass, a is any Observable, type(of: b) is AnyClass else { return nil }
    return (a as AnyObject) === (b as AnyObject)
}

#if !ISOMER_COMPILED_FEATURE
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
#endif
extension Environment where Value: AnyObject & Observable {
    /// `@Environment(Model.self)`: the model of that type an ancestor put in
    /// the environment with `.environment(_:)`; there must be one.
    public init(_ objectType: Value.Type) {
        self.init(reading: { env in
            guard let object = env.objects[ObjectIdentifier(Value.self)] as? Value else {
                fatalError("No Observable object of type \(Value.self) found. A View.environment(_:) for \(Value.self) may be missing as an ancestor of this view.")
            }
            return object
        })
    }
}

#if !ISOMER_COMPILED_FEATURE
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
#endif
extension Environment {
    /// `@Environment(Model.self) var model: Model?`: the model of that type
    /// in the environment, if an ancestor put one there.
    public init<T: AnyObject & Observable>(_ objectType: T.Type) where Value == T? {
        self.init(reading: { env in env.objects[ObjectIdentifier(T.self)] as? T })
    }
}

#if !ISOMER_COMPILED_FEATURE
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
#endif
extension View {
    /// Puts `object` in the environment of this view's subtree, where
    /// `@Environment(T.self)` finds it (nil takes it out).
    nonisolated public func environment<T: AnyObject & Observable>(_ object: T?) -> some View {
        _EnvironmentModifier(child: self, descend: "envobservable") { env in
            env.objects[ObjectIdentifier(T.self)] = object
        }
    }
}

/// `@Bindable`: bindings to an `@Observable` model's properties
/// (`$model.title`), for controls that take a `Binding`.
#if !ISOMER_COMPILED_FEATURE
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
#endif
@dynamicMemberLookup
@propertyWrapper
public struct Bindable<Value> {
    public var wrappedValue: Value

    public init(wrappedValue: Value) where Value: AnyObject & Observable {
        self.wrappedValue = wrappedValue
    }

    public init(_ wrappedValue: Value) where Value: AnyObject & Observable {
        self.wrappedValue = wrappedValue
    }

    public init(projectedValue: Bindable<Value>) {
        self = projectedValue
    }

    public var projectedValue: Bindable<Value> { self }

    public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<Value, Subject>) -> Binding<Subject>
    where Value: AnyObject {
        let object = wrappedValue
        return Binding(get: { object[keyPath: keyPath] }, set: { object[keyPath: keyPath] = $0 })
    }
}

#endif
