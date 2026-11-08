/// Apple's shape: a scene is made of scenes (`body`), down to the
/// primitive ones the runtime shows (`WindowGroup`), whose `Body` is `Never`.
@MainActor @preconcurrency
public protocol Scene {
    associatedtype Body: Scene
    var body: Body { get }
}

extension Never: Scene {}

extension Scene {
    /// A window's size when it first opens, as Apple's: Isomer's hosts size
    /// their windows themselves (the desktop hosts to their own default, the
    /// rest to the screen or the page), so the scene is unchanged.
    public nonisolated func defaultSize(_ size: CGSize) -> some Scene { self }

    public nonisolated func defaultSize(width: CGFloat, height: CGFloat) -> some Scene { self }
}

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
    /// Entry point for `@main`. Installs the app, then hands the process to
    /// its host (`iso_process_host_run`): the hosts that own their process
    /// (Linux's and Windows' windows, the terminal, headless, the compiled
    /// Metal cell's UIApplicationMain) run their loops there and don't
    /// return; the web's and Android's, driven from outside (`iso_start` on
    /// wasm, `nativeStart` over JNI), return at once.
    public static func main() {
        Runtime.shared.installApp(Self())
        #if !ISOMER_EMBEDDED_CORE
        _isoProcessHostRun()
        #endif
    }
}

/// What the process's host does once `App.main` has installed the app. Each
/// host defines it, under this name with Swift's calling convention
/// (`@_silgen_name`, on both sides: a C definition would be called with
/// Swift's convention and trap on wasm), and a binary links exactly one: its
/// host, or //shared/no_process_host where nothing hosts the app (the core's
/// tests). The core picks no host itself, so it is built the same for all.
/// The cores built beside Apple's SwiftUI (IsomerCore, IsomerGPUTreeView:
/// `ISOMER_EMBEDDED_CORE`) own no process and call none: one of them shares a
/// binary with a compiled feature's core, whose definition is the binary's.
@_silgen_name("iso_process_host_run")
package func _isoProcessHostRun()

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
