import SwiftUI

// Platform identification.
//
// For platform-specific *views/types*, use compile-time `#if os(...)` in the
// view body — only the matching branch is compiled, so each branch may use
// APIs that exist only on that platform:
//
//     var body: some View {
//         #if os(iOS) || os(macOS)
//         MyAppleView()
//         #elseif os(Android)
//         MyAndroidView()
//         #elseif os(WASI)
//         MyWasmView()
//         #else
//         EmptyView()
//         #endif
//     }
//
// `Platform.current` below is a runtime convenience for when every branch
// compiles everywhere (e.g. choosing a value or layout, not a type).

public enum Platform: Equatable, Sendable {
    case iOS
    case macOS
    case android
    case wasm
    case linux
    case windows
    case unknown

    public static var current: Platform {
        #if os(WASI)
        return .wasm
        #elseif os(Android)
        return .android
        #elseif os(Linux)
        return .linux
        #elseif os(Windows)
        return .windows
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

    /// Opens a URL with the platform (the browser's tab, the system's
    /// handler), as `@Environment(\.openURL)` does inside a view.
    @MainActor
    public static func openURL(_ url: String) {
        Runtime.shared.openURL(external: url)
    }
}
