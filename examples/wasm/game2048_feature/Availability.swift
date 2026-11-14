import SwiftUI

/// Chrome that arrived in iOS 17 / macOS 14. This app targets iOS 16, so the
/// two modifiers below are asked for only where they exist — the same shape a
/// native app at this deployment target would take. On the platforms Isomer
/// implements itself there is no such floor, and `#available` says so.
extension View {
    @ViewBuilder func inlineNavigationTitle() -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
            toolbarTitleDisplayMode(.inline)
        } else {
            self
        }
    }

    @ViewBuilder func restingAtBottom() -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
            defaultScrollAnchor(.bottom)
        } else {
            self
        }
    }
}
