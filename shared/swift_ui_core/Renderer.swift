// Pluggable renderers (see docs/renderer_layers.md).
//
// A renderer is responsible for taking a render tree and figuring out how
// to visualize it. The runtime resolves the SwiftUI view hierarchy into ONE
// canonical `RenderNode` tree (chrome as semantic host-view nodes) and hands
// it to the bound renderer whenever it may have changed; how the tree
// becomes pixels is entirely the renderer's business — the core neither
// knows nor asks what kind of renderer is bound. The concrete renderers
// (ReactRenderer, JetpackComposeRenderer, SwiftUIRenderer, SwiftGPURenderer,
// …) live OUTSIDE the core, in shared/renderers/, and are constructed and
// bound by each platform's bridge.
//
// Renderers build on two core facilities:
//   * `Runtime.installTreeHandlers(_:)` + `fireTreeAppearances(_:)` — the
//     event plumbing for renderers that hand the tree to a component system
//     across an FFI boundary (the wire format lives with the renderers:
//     shared/renderers/tree.fbs + TreeEncoder.swift).
//   * `Runtime.drawTree(root:)` — the layout + draw walk (with drawn-chrome
//     expansion), for renderers that draw every pixel themselves.

/// How a renderer is integrated into its host.
internal import IsomerSwiftUI

package enum IntegrationMode: Sendable, CustomStringConvertible {
    /// Hosted inside an existing native view hierarchy — a SwiftUI view, a
    /// Compose `@Composable`, a React component. The host places the produced
    /// native components anywhere.
    case embedded
    /// Owns a whole window / canvas (the main app struct / a full surface).
    case app

    public var description: String { self == .embedded ? "embedded" : "app" }
}

/// Visualizes render trees. Implement this to render with your own
/// component library (UIKit, CoreAnimation, ...) and bind it with
/// `Renderer.bind(_:)` before `Runtime.start`.
package protocol TreeRenderer: AnyObject {
    /// Visualize the current resolved (pre-layout) tree. Called while a
    /// frame is rendered, which is on the main actor.
    @MainActor func render(tree: RenderNode)

    /// The integration modes this renderer supports. Component-system renderers
    /// (SwiftUI/Compose/React) build native components a host can embed OR
    /// present fullscreen — both. The self-drawing SwiftGPU renderer owns the
    /// entire surface, so it is **app-only**. Enforced in `Runtime.start`.
    var supportedModes: Set<IntegrationMode> { get }

    /// Whether navigation containers serialize SEMANTICALLY (`navstack` /
    /// `navsplit` host-view nodes — title, depth, toolbar items, search,
    /// content as children) for the renderer to map onto its platform's own
    /// navigation idiom: real SwiftUI containers on Apple, a top bar +
    /// columns on the web, Material chrome under Compose. Self-drawing
    /// renderers return false and receive the pre-expanded drawn chrome
    /// instead — they have no platform components to map to. This is an
    /// intrinsic property of the renderer, not host configuration.
    var semanticNavigation: Bool { get }
}

package extension TreeRenderer {
    /// Component-system renderers support both modes; only the self-drawing
    /// renderer overrides this.
    var supportedModes: Set<IntegrationMode> { [.embedded, .app] }

    /// Component systems map semantic navigation to their platform's idiom;
    /// only the self-drawing renderers override this.
    var semanticNavigation: Bool { true }
}

/// The initial binding: renders nothing and logs once, so a missing
/// platform bind is loud in the console rather than a crash.
final class NullRenderer: TreeRenderer {
    private var warned = false

    func render(tree: RenderNode) {
        if !warned {
            warned = true
            Runtime.shared.host?.log(
                "Isomer: no renderer bound — call Renderer.bind(_:) before Runtime.start")
        }
    }
}

package enum Renderer {
    /// The bound renderer. Platforms construct a concrete renderer
    /// (shared/renderers/) and bind it before `Runtime.start`.
    public nonisolated(unsafe) private(set) static var current: any TreeRenderer = NullRenderer()

    /// True when the bound renderer draws SwiftMap tile scenes for the
    /// SwiftUI `Map` view (the SwiftGPU renderer with SwiftMap linked — see
    /// HostBridge.drawHostView). Set by the platform bridge before start;
    /// when false, `Map` shows its informative placeholder.
    public nonisolated(unsafe) static var hostRendersMaps = false

    /// Derived from the bound renderer (`TreeRenderer.semanticNavigation`):
    /// true when navigation serializes as semantic `navstack`/`navsplit`
    /// nodes for the renderer to map natively; false when the guest expands
    /// its own drawn chrome (self-drawing renderers).
    public nonisolated(unsafe) private(set) static var hostRendersNavigation = true

    /// How the bound renderer is integrated. Defaults to `.app` (a full
    /// window/canvas); the embedded-adoption path (`Runtime.installRootView`)
    /// sets `.embedded`. `Runtime.start` rejects a renderer that doesn't
    /// support the active mode (e.g. the self-drawing SwiftGPU renderer embedded
    /// in someone else's view hierarchy).
    public nonisolated(unsafe) static var integrationMode: IntegrationMode = .app

    public static func bind(_ renderer: any TreeRenderer) {
        current = renderer
        hostRendersNavigation = navigationOverride ?? renderer.semanticNavigation
    }

    /// A host's declared navigation kind (set before `bind` runs at start).
    private nonisolated(unsafe) static var navigationOverride: Bool?

    /// A serializing renderer (a wasm reactor's `SwiftUIRenderer`) forwards
    /// trees to a HOST renderer it cannot see; the host declares its kind
    /// through the reactor's configure channel (`iso_hot_configure
    /// navigation=drawn|semantic`) so a self-drawing host receives
    /// pre-expanded drawn chrome instead of `navstack` host views.
    public static func setHostRendersNavigation(_ semantic: Bool) {
        navigationOverride = semantic
        hostRendersNavigation = semantic
    }
}
