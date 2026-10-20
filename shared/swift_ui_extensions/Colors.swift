import SwiftUI

extension Color {
    /// A scheme-adaptive color from two concrete colors: resolves to `light`
    /// under the light scheme and `dark` under the dark scheme — the building
    /// block for app-defined semantic palettes (brand colors that adapt like
    /// `.primary`). The Apple Isomer module has the same API backed by a
    /// native dynamic provider (apple/libraries/swift_ui/IsomerBridge.swift),
    /// so shared app code adapts everywhere:
    ///
    ///     extension Color {
    ///         static let cardBackground = Color.dynamic(
    ///             light: Color(red: 0.98, green: 0.97, blue: 0.95),
    ///             dark: Color(red: 0.13, green: 0.12, blue: 0.11))
    ///     }
    ///
    /// If an argument is itself adaptive, its matching variant is used.
    public static func dynamic(light: Color, dark: Color) -> Color {
        _dynamic(light: light, dark: dark)
    }
}
