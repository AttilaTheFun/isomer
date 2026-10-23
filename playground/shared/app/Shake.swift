// `.onShake { }`: runs the action on a shake gesture, through the platform's
// DeviceMotionService (UIKit motion events on iOS, the accelerometer on the
// web, a keyboard stand-in on desktops). Listeners stack: the most recently
// appeared one (the run cover over the chat) gets the shake.

import PlatformServices
import SwiftUI

extension View {
    public func onShake(perform action: @escaping () -> Void) -> some View {
        _ShakeListener(content: self, action: action)
    }
}

struct _ShakeListener<Content: View>: View {
    let content: Content
    let action: () -> Void
    @State private var token = ShakeHub.nextToken()

    var body: some View {
        content
            .onAppear { ShakeHub.shared.add(token, action) }
            .onDisappear { ShakeHub.shared.remove(token) }
    }
}

/// One `nextShake` loop per process, fanned out to the topmost listener.
/// Main-thread only (views call it from their appearance callbacks).
final class ShakeHub {
    nonisolated(unsafe) static let shared = ShakeHub()
    nonisolated(unsafe) private static var counter = 0
    private var listeners: [(token: Int, action: () -> Void)] = []
    private var listening = false

    static func nextToken() -> Int {
        counter += 1
        return counter
    }

    func add(_ token: Int, _ action: @escaping () -> Void) {
        remove(token)
        listeners.append((token, action))
        start()
    }

    func remove(_ token: Int) {
        listeners.removeAll { $0.token == token }
    }

    private func start() {
        guard !listening, let motion = PlatformDependencies.deviceMotion else { return }
        listening = true
        Task { @MainActor in
            while !listeners.isEmpty {
                do { try await motion.nextShake() } catch { break }
                listeners.last?.action()
            }
            listening = false
        }
    }
}
