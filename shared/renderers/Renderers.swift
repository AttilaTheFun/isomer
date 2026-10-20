// The concrete renderers. Pluggable — they live OUTSIDE the core
// (shared/swift_ui_core knows only the `TreeRenderer` protocol); each
// platform bridge constructs one and installs it with `Renderer.bind(_:)`
// before `Runtime.start`. See docs/renderer_layers.md.

/// Base for component-system renderers: encodes the tree as a FlatBuffer
/// (tree.fbs) and hands it to the platform transport (an FFI call to the
/// host's tree consumer), then fires lifecycle for newly appearing nodes.
package class ComponentSystemRenderer: TreeRenderer {
    private let send: ([UInt8]) -> Void
    // Retained across frames: every frame ships a `Patch` diffed against the
    // previous tree — patches are the ONLY wire format (the first patch after
    // start is a single full-tree op at "n", so cold start is unchanged).
    private let encoder = FlatTreeEncoder()

    public init(send: @escaping ([UInt8]) -> Void) {
        self.send = send
    }

    // Colors resolve against the CURRENT scheme when the tree serializes, but
    // the differ compares unresolved values — so a scheme flip alone looks
    // like "no change". Track the encoded scheme and re-send the full tree
    // when it flips (dark mode repaints everything anyway).
    private var encodedScheme: ColorScheme?

    public func render(tree: RenderNode) {
        if encodedScheme != Runtime.shared.colorScheme {
            encodedScheme = Runtime.shared.colorScheme
            encoder.resetRetainedTree()
        }
        // Handlers/appearances are rebuilt from the WHOLE tree every frame
        // (the flatten pass always walks it), so event routing stays complete
        // even though only a patch is shipped.
        let bytes = encoder.encodePatch(root: tree)
        Runtime.shared.installTreeHandlers(encoder.handlers)
        send(bytes)
        Runtime.shared.fireTreeAppearances(encoder.appearances, disappearances: encoder.disappearances)
    }
}

/// React components on the web.
package final class ReactRenderer: ComponentSystemRenderer {}

/// Jetpack Compose composables on Android.
package final class JetpackComposeRenderer: ComponentSystemRenderer {}

/// The real SwiftUI on Apple platforms — the tree consumer for running the
/// wasm-compiled runtime under an embedded interpreter (see the hot-reload
/// example host).
package final class SwiftUIRenderer: ComponentSystemRenderer {}
