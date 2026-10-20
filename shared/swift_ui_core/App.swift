/// Apple's shape: a scene is made of scenes (`body`), down to the
/// primitive ones the runtime shows (`WindowGroup`), whose `Body` is `Never`.
@MainActor @preconcurrency
public protocol Scene {
    associatedtype Body: Scene
    var body: Body { get }
}

extension Never: Scene {}

/// A scene the runtime shows itself: its root view and its window title
/// (document.title on web, task label on Android, the window title on
/// desktop hosts; "" leaves the host's own).
@MainActor
protocol _PrimitiveScene {
    func makeRootView() -> any View
    var windowTitle: String { get }
}

/// The primitive scene an app's scene comes down to.
@MainActor
func primitiveScene(_ scene: any Scene) -> any _PrimitiveScene {
    if let primitive = scene as? any _PrimitiveScene { return primitive }
    return primitiveScene(scene.body)
}

public struct WindowGroup<Content: View> {
    let title: String
    let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        title = ""
        self.content = content
    }

    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: @escaping () -> Content) {
        let title = String(title)
        self.title = title
        self.content = content
    }

    func makeRootView() -> any View {
        content()
    }

    var windowTitle: String { title }
}

@MainActor @preconcurrency
public protocol App {
    associatedtype Body: Scene

    var body: Body { get }

    init()
}

extension App {
    /// Entry point for `@main`. Installs the app; the platform host calls
    /// back into the runtime (e.g. `iso_start` on wasm, `nativeStart` over
    /// JNI) to begin rendering.
    ///
    /// On Windows the app is a real `.exe` that owns its process, so — unlike
    /// the wasm/Android hosts that are driven externally — the entry point
    /// itself creates the window and runs the message/render loop (which does
    /// not return until the window is closed).
    public static func main() {
        Runtime.shared.installApp(Self())
        #if os(Windows) && ISOMER_WINDOWS_HOST
        // Same gate as Linux below: only the Windows host library (which
        // provides `WindowsApp`) defines the flag; the core alone still
        // builds for a Windows *host* (e.g. the snapshot test's `core_host`).
        WindowsApp.run()
        #elseif os(Linux) && ISOMER_LINUX_HOST
        // Gated on the Linux host library's compile flag so the platform-agnostic
        // core still builds for a Linux *host* on its own (e.g. the snapshot
        // test's `core_host`), where `LinuxApp` (in `linux/libraries/swift_ui`)
        // isn't linked.
        LinuxApp.run()
        #elseif os(iOS) && ISOMER_IOS_METAL_HOST
        // The compiled self-drawing iOS cell (SwiftGPU over Metal): like the
        // desktop hosts above, the app owns its process — `run()` enters
        // UIApplicationMain and never returns. Only that cell's host library
        // (which provides `IOSMetalApp`) defines the flag.
        IOSMetalApp.run()
        #elseif ISOMER_CLI_HOST
        // The terminal host (cli/libraries/swift_ui): the binary owns the
        // terminal until the user quits.
        TerminalApp.run()
        #endif
    }
}

/// Hosts a single isomer view inside an existing host app, the
/// reimplementation's analogue of `UIHostingController` (Apple's
/// `IsomerBridge` wraps the real `UIHostingController`/`NSHostingController`).
/// Construct it with a root view, then mount the platform surface that drives it
/// (the `mountIsomer` canvas on web, a `IsomerView` on Android); the
/// runtime renders that view into the surface's bounds.
package struct IsomerHostingController {
    /// Host a view value directly, mirroring Apple's
    /// `UIHostingController(rootView:)`. The view is rebuilt from this value
    /// each frame; its own `@State` lives in the runtime as usual.
    public init<V: View>(rootView: V) {
        Runtime.shared.installRootView { rootView }
    }

    public init(rootView: @escaping () -> any View) {
        Runtime.shared.installRootView(rootView)
    }

    /// Swap the hosted view (e.g. when host-app state changes).
    public func setRootView(_ make: @escaping () -> any View) {
        Runtime.shared.installRootView(make)
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension WindowGroup: Scene, _PrimitiveScene {
    public typealias Body = Never
    public var body: Never { fatalError("WindowGroup is a primitive scene") }
}
