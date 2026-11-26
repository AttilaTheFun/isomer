import Foundation
import SwiftUI

/// A picture of the app's window as it is on screen, a PNG: what an app
/// attaches to a bug report. Isomer's own (Apple's SwiftUI has none): taken
/// here by the host (Android's PixelCopy of the window); nil where the host
/// can't take one (the web, a desktop, for now). On Apple's platforms,
/// apple/libraries/swift_ui/AppleScreenshot.swift.
public enum IsomerScreenshot {
    /// The window's PNG, or nil when it can't be taken.
    @MainActor
    public static func capture() async -> Data? {
        guard let png = await Runtime.shared.host?.captureScreenshot() else { return nil }
        return Data(png)
    }
}
