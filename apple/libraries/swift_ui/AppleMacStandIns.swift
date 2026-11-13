// The Isomer module on the Mac: stand-ins for SwiftUI API that Apple's
// SwiftUI has on iOS and not on the Mac, so one source builds for both
// without `#if os(iOS)` (and Isomer's SwiftUI has them on every platform).
// The text-input ones (keyboardType, textInputAutocapitalization) are in
// SwiftUIShim.swift.
// Each does on the Mac what the Mac's SwiftUI would: nothing, or the Mac's
// nearest. Where Apple's own is there, Apple's is the one taken (these are
// only reached where Apple's is unavailable).

#if os(macOS)
import SwiftUI

/// A navigation bar's parts: on the Mac, its title's display mode, which
/// the Mac's windows have no bar to show.
public enum NavigationBarItem {
    /// How a navigation bar shows its title.
    public enum TitleDisplayMode: Sendable {
        case automatic
        case inline
        case large
    }
}

extension View {
    /// How the navigation bar shows the title: the Mac shows the window's
    /// title as it does, so nothing changes.
    nonisolated public func navigationBarTitleDisplayMode(_ displayMode: NavigationBarItem.TitleDisplayMode) -> some View {
        self
    }
}

extension ListStyle where Self == InsetListStyle {
    /// iOS's inset grouped list: the Mac's inset list.
    public static var insetGrouped: InsetListStyle { .inset }
}
#endif
