import SwiftUI

// Bridging a native view registered on the host into a feature's view tree.
//
// A feature (compiled or wasm-delivered) places `BridgedView("FooView", …)`
// declaratively; the host's tree consumer looks `FooView` up in its bridged-
// view registry and renders the real native view, passing `parameters` and a
// value/edit channel. This lets a dynamically-delivered wasm feature reuse the
// app's own native views (a real MapKit map, a design-system component, a
// camera preview) that can't — or shouldn't — live in the bundle.
//
// It is an ordinary `PlatformViewRepresentable` whose `kind` is `"bridge:<id>"`,
// so it rides the existing host-view mechanism: the native SwiftUIRenderer
// (IsomerTreeView) resolves it against `BridgedViewRegistry`; other hosts
// (and the self-drawing GPU path) fall back to the representable placeholder.
// Bridged views ship with the app and are registered with the non-dynamic core
// runtime — they are never part of a feature bundle.

public struct BridgedView {
    public let id: String
    public let parameters: [String: String]
    private let valueString: String
    private let onChange: (String) -> Void

    public init(
        _ id: String,
        parameters: [String: String] = [:],
        value: String = "",
        onChange: @escaping (String) -> Void = { _ in }
    ) {
        self.id = id
        self.parameters = parameters
        self.valueString = value
        self.onChange = onChange
    }

    public var kind: String { "bridge:\(id)" }
    public var value: String { valueString }
    public func onValueChanged(_ value: String) { onChange(value) }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension BridgedView: PlatformViewRepresentable {}
