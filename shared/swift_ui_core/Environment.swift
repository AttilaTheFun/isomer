// @Environment (and @Environment(Model.self) for an @Observable, ObservationSupport.swift).
//
// Both read from the `EnvironmentValues` flowing down the view tree. Define a
// custom value by conforming a key to `EnvironmentKey` and extending
// `EnvironmentValues`:
//
//     private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.light }
//     extension EnvironmentValues { var theme: Theme {
//         get { self[ThemeKey.self] } set { self[ThemeKey.self] = newValue } } }
//
//     @Environment(\.theme) var theme        // read
//     SomeView().environment(\.theme, .dark)  // set for the subtree

@propertyWrapper
public struct Environment<Value>: _DynamicProperty {
    final class Box {
        var value: Value?
    }

    /// What it reads from the environment: a value by its key path, or a
    /// model by its type (`@Environment(Model.self)`, ObservationSupport).
    let read: (EnvironmentValues) -> Value
    let box = Box()

    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {
        read = { $0[keyPath: keyPath] }
    }

    init(reading read: @escaping (EnvironmentValues) -> Value) {
        self.read = read
    }

    public var wrappedValue: Value {
        box.value ?? read(EnvironmentValues())
    }

    func _connect(storage: StateStorage, key: String, env: EnvironmentValues) {
        box.value = read(env)
    }
}

extension View {
    /// Sets an environment value for this view's subtree.
    nonisolated public func environment<Value>(
        _ keyPath: WritableKeyPath<EnvironmentValues, Value>,
        _ value: Value
    ) -> some View {
        _EnvironmentModifier(child: self, descend: "env") { env in
            env[keyPath: keyPath] = value
        }
    }
}
