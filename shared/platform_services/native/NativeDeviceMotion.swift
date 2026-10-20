// Device motion for Swift hosts: on iOS, UIKit delivers shake gestures to
// the responder chain and the window is its root, so a `UIWindow` override
// catches every shake without the content needing a first responder; the
// service hands each one to whoever is awaiting `nextShake`. Elsewhere
// (macOS, Linux, Windows) there is no accelerometer: `nextShake` throws, so
// `.onShake` listeners stop instead of waiting forever.

import Foundation

#if canImport(UIKit) && !os(watchOS) && !os(tvOS)
import UIKit

extension Notification.Name {
    /// Posted on every shake gesture (the `UIWindow` override below).
    public static let isomerDeviceDidShake = Notification.Name("isomer.deviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .isomerDeviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}

public final class NativeDeviceMotionService {
    /// One observer for the process (every run's listeners share the window's shakes).
    public static let shared = NativeDeviceMotionService()
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var observer: NSObjectProtocol?

    public init() {
        observer = NotificationCenter.default.addObserver(
            forName: .isomerDeviceDidShake, object: nil, queue: .main
        ) { [weak self] _ in self?.deliver() }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    public func nextShake() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async { self.waiters.append(continuation) }
        }
    }

    /// Resolves every pending `nextShake` (tests and the simulator's
    /// Device ▸ Shake both arrive here through the notification).
    public func deliver() {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

#elseif !os(WASI) && !os(Android)

public final class NativeDeviceMotionService {
    public static let shared = NativeDeviceMotionService()
    public init() {}
    public func nextShake() async throws {
        throw NativeServiceError("device motion is not available on this platform")
    }
    public func deliver() {}
}

#endif
