// The MockRenderer + stub services host, in a Foundation-free file so the
// core's CG stand-ins (CGSize/CGRect) resolve unambiguously (see
// tests/snapshot/RecordingHost.swift for the same split).

import SwiftUI  // IsomerCore, aliased (BUILD.bazel)
import IsomerSwiftUI

/// Records every tree the runtime hands over — the test double any consumer
/// could write against the public `TreeRenderer` API.
final class MockRenderer: TreeRenderer {
    private(set) var renderCount = 0
    private(set) var lastTree: RenderNode?

    func render(tree: RenderNode) {
        renderCount += 1
        lastTree = tree
    }
}

/// A do-nothing services host: enough for build + serialize (no layout).
final class StubHost: HostBridge {
    func measureText(_ text: String, fontSize: Double, weight: Int, wrapWidth: Double?) -> CGSize {
        CGSize(width: fontSize * 0.6 * Double(text.count), height: fontSize * 1.3)
    }
    func imageInfo(_ source: String, isRemote: Bool) -> ImageStatus { .ready(CGSize(width: 1, height: 1)) }
    func beginFrame(width: Double, height: Double) {}
    func fillRect(_ rect: CGRect, cornerRadius: Double, color: HostColor) {}
    func strokeRect(_ rect: CGRect, cornerRadius: Double, lineWidth: Double, color: HostColor) {}
    func fillGradient(_ rect: CGRect, cornerRadius: Double, gradientJSON: String) {}
    func drawShadow(_ rect: CGRect, cornerRadius: Double, color: HostColor, radius: Double, x: Double, y: Double) {}
    func drawText(_ text: String, in rect: CGRect, fontSize: Double, weight: Int, color: HostColor) {}
    func drawImage(_ source: String, isRemote: Bool, in dest: CGRect, clip: CGRect, cornerRadius: Double, opacity: Double) {}
    func pushClip(_ rect: CGRect, cornerRadius: Double) {}
    func popClip() {}
    func syncHostViews(_ viewsJSON: String) {}
    func endFrame() {}
    func beginTextInput(_ text: String, in rect: CGRect, fontSize: Double) {}
    func endTextInput() {}
    func scheduleRender() {}
    func log(_ message: String) {
        // What a frame built in place got wrong (InPlace.swift).
        if message.hasPrefix("[partial]") { print(message) }
    }
    func openURL(_ url: String) { hostOpenedURLs.append(url) }
    func now() -> Double { stubHostNow }
}

/// The StubHost's clock, in seconds (for animations).
nonisolated(unsafe) var stubHostNow = 0.0

/// The URLs the runtime asked a StubHost to open outside the app.
nonisolated(unsafe) var hostOpenedURLs: [String] = []

