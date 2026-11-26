// The Isomer module's `.onShake` on Apple's platforms: iOS's shake gesture,
// which UIKit delivers as a motion event up the responder chain to the key
// window. The window passes it on as a notification each `.onShake` view
// listens for. A Mac has nothing to shake: there the modifier does nothing.
// (Off Apple: shared/swift_ui_extensions/Shake.swift.)

import Foundation
import SwiftUI

#if os(iOS)
import UIKit

extension Notification.Name {
    /// Posted by the key window when the device is shaken.
    static let isomerDeviceShaken = Notification.Name("IsomerDeviceShaken")
}

extension UIWindow {
    // Every window's: the app's windows are UIKit's or SwiftUI's own, not a
    // subclass of ours. Passed on to super, so the system's own handling
    // (shake to undo) stays.
    override open func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .isomerDeviceShaken, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
#endif

public extension View {
    /// Runs `action` when the device is shaken while this view is shown (an
    /// iPhone or iPad's shake gesture); on a Mac, never.
    func onShake(perform action: @escaping () -> Void) -> some View {
        modifier(ShakeModifier(action: action))
    }
}

private struct ShakeModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.onReceive(NotificationCenter.default.publisher(for: .isomerDeviceShaken)) { _ in action() }
        #else
        content
        #endif
    }
}
