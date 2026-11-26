import SwiftUI

extension View {
    /// Runs `action` when the device is shaken while this view is shown: a
    /// phone's motion sensor (Android's accelerometer, as the host watches
    /// it while a view asks), iOS's shake gesture. Where there is nothing to
    /// shake (a Mac, the web, a desktop), it never runs. Isomer's own: Apple's
    /// SwiftUI has none (on Apple's platforms,
    /// apple/libraries/swift_ui/AppleShake.swift).
    nonisolated public func onShake(perform action: @escaping () -> Void) -> some View {
        _onShake(perform: action)
    }
}
