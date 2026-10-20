import SwiftUI

extension View {
    /// A horizontal swipe gesture (row swipe-to-action). Reports the running and
    /// final horizontal translation. Vertical drags are yielded to an enclosing
    /// scroll view so the list still scrolls. The Apple Isomer module has the
    /// same overload (apple/libraries/swift_ui/IsomerBridge.swift).
    nonisolated public func swipeGesture(
        onChanged: @escaping (CGFloat) -> Void,
        onEnded: @escaping (CGFloat) -> Void
    ) -> some View {
        var g = DragGesture(minimumDistance: 6)
        g.isHorizontalSwipe = true
        return gesture(
            g.onChanged { onChanged($0.translation.width) }
             .onEnded { onEnded($0.translation.width) }
        )
    }
}
