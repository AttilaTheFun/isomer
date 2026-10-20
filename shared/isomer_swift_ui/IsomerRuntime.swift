// How a host drives Isomer's SwiftUI: start it with the host's services
// (`HostBridge`), bind how its frames reach the host, and hand it the user's
// input and the platform's events. Isomer's SwiftUI connects itself when an
// app's `@main` (or a hosted view) installs it; a host reads the connection
// from `IsomerRuntime.connection` after that. Isomer's own platform hosts
// (the web's, Android's, the desktop hosts') drive the runtime the same way
// from inside it.

/// Where a pointer is in its gesture.
public enum PointerPhase: Int, Sendable {
    case down = 0
    case up = 1
    case moved = 2
}

/// The scene's state, as the platform reports it.
public enum HostScenePhase: Sendable {
    case background
    case inactive
    case active
}

/// Isomer's SwiftUI, as a host drives it.
@MainActor
public protocol RuntimeConnection: AnyObject {
    /// Starts rendering into the host: the first frame follows.
    func start(host: any HostBridge, width: Double, height: Double)
    /// Frames reach the host as encoded render trees: `tree.fbs`'s patches
    /// (IsomerSwiftUI's `IsoFlat_Patch`), each against the previous tree, the
    /// first a whole tree. For a host that builds the screen from its own
    /// components (the web's React, Android's Compose, Apple's SwiftUI).
    /// Bind before `start`.
    func bindTreeRenderer(send: @escaping ([UInt8]) -> Void)
    func resize(width: Double, height: Double)
    /// Builds and sends a frame (a host calls it when it asked for one with
    /// `HostBridge.scheduleRender`).
    func renderFrame()
    func pointer(_ phase: PointerPhase, x: Double, y: Double)
    func wheel(x: Double, y: Double, deltaX: Double, deltaY: Double)
    /// A host view's or a tree node's event, by the id the tree gave it.
    func hostViewEvent(id: String, value: String)
    /// A key press, for `.onKeyPress`: whether a handler took it.
    func keyPress(id: String, value: String) -> Bool
    func textChanged(_ text: String)
    func textSubmitted()
    func textInputEnded()
    func setSystemColorScheme(dark: Bool)
    func setDisplayScale(_ scale: Double)
    func scenePhaseChanged(to phase: HostScenePhase)
    /// A URL delivered to the app (`.onOpenURL`).
    func openURL(_ url: String)
    /// The platform's back gesture: whether the app took it (a navigation
    /// pop, a sheet dismissed).
    func handleBackButton() -> Bool
    func shutdown()
}

/// The runtime a host drives.
@MainActor
public enum IsomerRuntime {
    /// Isomer's SwiftUI, once an app or a hosted view installed it.
    public static var connection: (any RuntimeConnection)?
}
