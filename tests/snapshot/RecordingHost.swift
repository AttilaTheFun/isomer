// A deterministic HostBridge that records the draw list as text, for golden
// snapshot tests. Text metrics are synthetic (no real font) so layout is
// reproducible across machines.

import IsomerCore
import IsomerSwiftUI

final class RecordingHost: HostBridge {
    private(set) var lines: [String] = []

    var output: String { lines.joined(separator: "\n") }

    // MARK: Deterministic metrics

    func measureText(_ text: String, fontSize: Double, weight: Int, wrapWidth: Double?) -> CGSize {
        let charWidth = fontSize * 0.6
        let lineHeight = fontSize * 1.3
        if let wrap = wrapWidth, charWidth * Double(text.count) > wrap, charWidth > 0 {
            let perLine = max(1, Int(wrap / charWidth))
            let lineCount = max(1, (text.count + perLine - 1) / perLine)
            return CGSize(width: wrap, height: Double(lineCount) * lineHeight)
        }
        return CGSize(width: charWidth * Double(text.count), height: lineHeight)
    }

    func imageInfo(_ source: String, isRemote: Bool) -> ImageStatus {
        .ready(CGSize(width: 100, height: 100))
    }

    // MARK: Recorded draw calls

    func beginFrame(width: Double, height: Double) {}

    func fillRect(_ rect: CGRect, cornerRadius: Double, color: HostColor) {
        lines.append("fillRect \(r(rect)) r\(n(cornerRadius)) \(c(color))")
    }

    func strokeRect(_ rect: CGRect, cornerRadius: Double, lineWidth: Double, color: HostColor) {
        lines.append("strokeRect \(r(rect)) r\(n(cornerRadius)) w\(n(lineWidth)) \(c(color))")
    }

    func fillGradient(_ rect: CGRect, cornerRadius: Double, gradientJSON: String) {
        lines.append("gradient \(r(rect)) r\(n(cornerRadius))")
    }

    func drawShadow(_ rect: CGRect, cornerRadius: Double, color: HostColor, radius: Double, x: Double, y: Double) {
        lines.append("shadow \(r(rect)) r\(n(cornerRadius)) blur\(n(radius)) d(\(n(x)),\(n(y))) \(c(color))")
    }

    func drawText(_ text: String, in rect: CGRect, fontSize: Double, weight: Int, color: HostColor) {
        lines.append("text \"\(text)\" \(r(rect)) s\(n(fontSize)) w\(weight) \(c(color))")
    }

    func drawImage(_ source: String, isRemote: Bool, in dest: CGRect, clip: CGRect, cornerRadius: Double, opacity: Double) {
        lines.append("image \(source) dest\(r(dest)) clip\(r(clip)) r\(n(cornerRadius))")
    }

    func pushClip(_ rect: CGRect, cornerRadius: Double) {
        lines.append("pushClip \(r(rect)) r\(n(cornerRadius))")
    }

    func popClip() {
        lines.append("popClip")
    }

    func syncHostViews(_ viewsJSON: String) {
        if viewsJSON != "[]" { lines.append("hostViews \(viewsJSON)") }
    }

    func endFrame() {}
    func beginTextInput(_ text: String, in rect: CGRect, fontSize: Double) {}
    func endTextInput() {}
    func scheduleRender() {}
    func log(_ message: String) {}

    // MARK: Formatting helpers (stable, low-precision)

    private func n(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    private func r(_ rect: CGRect) -> String {
        "(\(n(rect.minX)),\(n(rect.minY)),\(n(rect.width)),\(n(rect.height)))"
    }

    private func c(_ color: HostColor) -> String {
        func hex(_ v: Double) -> String {
            let byte = Int((max(0, min(1, v)) * 255).rounded())
            let s = String(byte, radix: 16)
            return s.count == 1 ? "0" + s : s
        }
        return "#\(hex(color.red))\(hex(color.green))\(hex(color.blue))\(hex(color.opacity))"
    }
}
