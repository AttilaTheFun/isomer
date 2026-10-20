import SwiftUI

// Platform-specific view modifiers: SwiftUI-shaped knobs for behaviors that
// only exist on one platform. Each is a no-op everywhere else, so shared app
// code can use them unconditionally. They ride the host's generic
// `platformCommand(key, value)` channel — adding a knob is a host-side case,
// not an FFI-surface change. (On Apple these come from the shim as no-ops;
// the platform's own SwiftUI covers the real behaviors.)

extension View {
    /// Android: light or dark status-bar icon style for this screen.
    public func androidStatusBarStyle(dark: Bool) -> some View {
        platformCommand("statusBarStyle", dark ? "dark" : "light", on: .android)
    }

    /// Android: keep the screen awake while this view is in the tree.
    public func androidKeepScreenOn(_ on: Bool = true) -> some View {
        platformCommand("keepScreenOn", on ? "1" : "0", on: .android)
    }

    /// Web: sets `document.title` while this view is in the tree (overrides
    /// the `WindowGroup` title).
    public func webDocumentTitle(_ title: String) -> some View {
        platformCommand("windowTitle", title, on: .wasm)
    }

    /// Escape hatch: send an arbitrary key/value to the current platform host
    /// while this view is in the tree (`nil` platform = every host). Hosts
    /// apply the keys they understand and ignore the rest.
    public func platformCommand(
        _ key: String, _ value: String, on platform: Platform? = nil
    ) -> some View {
        _ModifiedView(child: self, descend: "platform.\(key)") { inner, _ in
            if platform == nil || platform == Platform.current {
                Runtime.shared.sendPlatformCommand(key, value)
            }
            return inner
        }
    }
}
