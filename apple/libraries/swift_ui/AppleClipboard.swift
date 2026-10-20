// The Isomer module's `Clipboard` on Apple platforms: the system
// pasteboard's text (UIKit's on iOS, AppKit's on the Mac). Elsewhere,
// shared/swift_ui_extensions/Clipboard.swift.

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The system clipboard's text: what a copy puts there and a paste reads,
/// the same on every platform.
@MainActor
public enum Clipboard {
    /// The clipboard's text, if it holds any; setting it copies.
    public static var string: String? {
        get {
            #if canImport(UIKit)
            UIPasteboard.general.string
            #elseif canImport(AppKit)
            NSPasteboard.general.string(forType: .string)
            #else
            nil
            #endif
        }
        set {
            #if canImport(UIKit)
            UIPasteboard.general.string = newValue
            #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
            #endif
        }
    }
}
