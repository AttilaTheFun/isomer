// The host's registry of native views a wasm (or compiled) feature can bridge
// in by id. The app registers its native SwiftUI views ONCE, at launch, with
// the non-dynamic core runtime; a feature places `BridgedView("id", …)` and
// `IsomerTreeView` resolves the id here to render the real native view.
//
//     BridgedViewRegistry.shared.register("swatch") { params, _, _ in
//         AnyView(ColorSwatch(hex: params["hex"] ?? "#000"))
//     }
//
// The same native `FooView` symbol is thus usable both compiled (directly) and
// from a wasm feature (by id) — the bundle only needs the id + a params/value
// contract, never FooView's code, so bridged views ship with the app and are
// never dynamically delivered.

import SwiftUI

public final class BridgedViewRegistry {
    public static let shared = BridgedViewRegistry()

    /// Builds a native view from the feature's params + value; `send` reports
    /// edits back to the feature (bound to the placing node's edit channel).
    public typealias Factory = (
        _ parameters: [String: String],
        _ value: String,
        _ send: @escaping (String) -> Void
    ) -> AnyView

    private var factories: [String: Factory] = [:]

    private init() {}

    /// Register a native view under `id`. Call at app launch, before any
    /// feature that uses it renders.
    public func register(_ id: String, _ factory: @escaping Factory) {
        factories[id] = factory
    }

    func view(
        for id: String, parameters: [String: String], value: String,
        send: @escaping (String) -> Void
    ) -> AnyView? {
        factories[id].map { $0(parameters, value, send) }
    }
}
