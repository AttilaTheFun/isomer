// App-level lifecycle surface: ScenePhase (host activity/page visibility
// mapped to SwiftUI's phases), .onOpenURL (intents / links delivered to the
// running app), and the generic platform-command channel that carries
// window titles and platform-specific modifiers to the host.

/// Mirror of SwiftUI's `ScenePhase`, driven by the platform host:
/// Android maps onResume/onPause/onStop, web maps page visibility.
import Foundation

public enum ScenePhase: Comparable, Hashable, Sendable {
    case background
    case inactive
    case active
}

extension EnvironmentValues {
    /// The current scene phase, readable as `@Environment(\.scenePhase)`.
    /// Combine with `.onChange(of:)` to react to foreground/background moves.
    public var scenePhase: ScenePhase {
        get { self[ScenePhaseKey.self] }
        set { self[ScenePhaseKey.self] = newValue }
    }
}

struct ScenePhaseKey: EnvironmentKey {
    static let defaultValue: ScenePhase = .active
}

extension View {
    /// Registers a handler for URLs delivered to the running app (an Android
    /// `VIEW` intent, the page's launch URL / a `iso:openurl` event on web).
    /// Mirrors SwiftUI's `onOpenURL`.
    nonisolated public func onOpenURL(perform action: @escaping (URL) -> Void) -> some View {
        _ModifiedView(child: self, descend: "openurl", pure: true) { inner, _ in
            Runtime.shared.registerFrameEffect { Runtime.shared.openURLHandlers.append(action) }
            return inner
        }
    }
}

extension Runtime {
    /// Host entry point: the scene moved between foreground/background.
    /// Updates the environment and re-renders so `.onChange(of: scenePhase)`
    /// observers fire.
    public func setScenePhase(_ phase: ScenePhase) {
        guard phase != scenePhase else { return }
        scenePhase = phase
        setNeedsRender()
    }

    /// Host entry point: a URL was delivered to the running app. Buffered
    /// until a frame has registered `.onOpenURL` handlers, then dispatched.
    public func openURL(external urlString: String) {
        pendingExternalURLs.append(urlString)
        setNeedsRender()
    }

    /// Reports the `WindowGroup` title to the host when it changes
    /// (document.title on web, the task label on Android, window title on
    /// desktop hosts).
    func syncWindowTitle() {
        // A `.webDocumentTitle` (or other explicit windowTitle command) wins
        // over the WindowGroup default, so only fill the key when unset.
        guard !windowTitle.isEmpty, sentPlatformCommands["windowTitle"] == nil else { return }
        sendPlatformCommand("windowTitle", windowTitle)
    }

    /// Called at the end of each frame: deliver buffered external URLs once
    /// handlers exist (handlers re-register during every build).
    func dispatchExternalURLs() {
        guard !pendingExternalURLs.isEmpty, !openURLHandlers.isEmpty else { return }
        let urls = pendingExternalURLs
        let handlers = openURLHandlers
        pendingExternalURLs = []
        deferredActions.append {
            for urlString in urls {
                guard let url = URL(string: urlString) else { continue }
                for handler in handlers {
                    handler(url)
                }
            }
        }
    }
}
