import SwiftUI

/// The system clipboard's text: what a copy puts there and a paste reads,
/// the same on every platform. Isomer's own: Apple's SwiftUI has none
/// (UIKit's UIPasteboard and AppKit's NSPasteboard are the platforms'), and
/// Isomer's SwiftUI has no UIKit. Here it goes through the host: the
/// browser's clipboard, Android's ClipboardManager, the desktop's. (On Apple
/// platforms, apple/libraries/swift_ui/AppleClipboard.swift.)
@MainActor
public enum Clipboard {
    /// The clipboard's text, if it holds any; setting it copies.
    public static var string: String? {
        get { Runtime.shared.host?.hostValue("pasteboard") }
        set {
            // Straight to the host, not deduplicated like the platform
            // commands: copying the same words twice is two copies.
            Runtime.shared.host?.platformCommand("copy", newValue ?? "")
        }
    }
}
