// On Apple platforms the example application uses the real SwiftUI. This
// shim target exists so all platforms share the same dependency shape
// ([platform]/libraries/swift_ui); importing it re-exports the system
// frameworks. Foundation is re-exported too so shared code can use `Date`
// and `URL` without an explicit `import Foundation` (which on the wasm /
// Android reimplementation would clash with the core's own CG types) — on
// those platforms the reimplementation provides matching `Date`/`URL`.

@_exported import Foundation
@_exported import SwiftUI

// Mirrors the reimplementation's `Platform` (shared/swift_ui_core/
// PlatformInfo.swift) so shared code can use `Platform.current` on Apple too.
public enum Platform: Equatable, Sendable {
    case iOS
    case macOS
    case android
    case wasm
    case linux
    case windows
    case unknown

    public static var current: Platform {
        #if os(macOS)
        return .macOS
        #elseif os(iOS) || os(tvOS) || os(visionOS)
        return .iOS
        #else
        return .unknown
        #endif
    }

    public var name: String {
        switch self {
        case .iOS: return "iOS"
        case .macOS: return "macOS"
        case .android: return "Android"
        case .wasm: return "WebAssembly"
        case .linux: return "Linux"
        case .windows: return "Windows"
        case .unknown: return "Unknown"
        }
    }

    /// Opens a URL with the system's handler, as `@Environment(\.openURL)`
    /// does inside a view.
    @MainActor
    public static func openURL(_ url: String) {
        guard let url = URL(string: url) else { return }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

// Platform-specific modifiers from the reimplementation's surface
// (shared/swift_ui_core/PlatformModifiers.swift): no-ops on Apple, where the
// real SwiftUI covers platform behaviors natively. Declared so shared app
// code using them compiles unchanged.
extension SwiftUI.View {
    public func androidStatusBarStyle(dark: Bool) -> some SwiftUI.View { self }

    public func androidKeepScreenOn(_ on: Bool = true) -> some SwiftUI.View { self }

    public func webDocumentTitle(_ title: String) -> some SwiftUI.View { self }

    public func platformCommand(
        _ key: String, _ value: String, on platform: Platform? = nil
    ) -> some SwiftUI.View { self }
}

// Text-input modifiers SwiftUI has on iOS only. On the Mac there is no
// software keyboard for them to configure, so they are no-ops there and
// shared code that sets them compiles for every Apple platform (on the
// other platforms Isomer's SwiftUI has them everywhere).
#if os(macOS)
public enum UIKeyboardType: Sendable {
    case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad, phonePad, namePhonePad
    case emailAddress, decimalPad, twitter, webSearch, asciiCapableNumberPad
}

public struct TextInputAutocapitalization: Sendable {
    public static var never: TextInputAutocapitalization { .init() }
    public static var words: TextInputAutocapitalization { .init() }
    public static var sentences: TextInputAutocapitalization { .init() }
    public static var characters: TextInputAutocapitalization { .init() }
}

extension SwiftUI.View {
    public func keyboardType(_ type: UIKeyboardType) -> some SwiftUI.View { self }

    public func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some SwiftUI.View { self }
}
#endif
