// The platform bridge for a feature compiled against Isomer's frameworks on
// an Apple platform (apple/compiled), as the other platforms' Isomer modules
// have one: what platform and renderer the feature runs on, its log, the
// time, and opening a URL (through the host, as `Platform.openURL` does).

import Foundation

public enum Bridge {
    public static var platformName: String {
        #if os(macOS)
        return "macOS (Isomer's SwiftUI)"
        #else
        return "iOS (Isomer's SwiftUI)"
        #endif
    }

    /// Isomer's tree, drawn by the host's WasmView with Apple's SwiftUI.
    public static var rendererName: String { "SwiftUI tree" }

    public static func log(_ message: String) {
        print("[bridge] \(message)")
    }

    public static func epochMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    public static func openURL(_ url: String) {
        Task { @MainActor in Platform.openURL(url) }
    }
}
