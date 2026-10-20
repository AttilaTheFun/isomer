// WebAssembly host bridge: the shared `HostBridge` implemented over the
// swift_ffi `WebHost` the browser passed to `isoStart` (see WebBridge.swift).
// Values copy at the boundary — strings both ways, structs field-wise — so
// there is no staging-buffer plumbing here.

internal import IsomerSwiftUI

struct WasmHostBridge: HostBridge {
    var host: any WebHost { webHost! }

    func measureText(_ text: String, fontSize: Double, weight: Int, wrapWidth: Double?) -> CGSize {
        let metrics = host.measureText(
            text: text, fontSize: fontSize, weight: Int32(weight), wrapWidth: wrapWidth ?? -1)
        return CGSize(width: metrics.width, height: metrics.height)
    }

    func imageInfo(_ source: String, isRemote: Bool) -> ImageStatus {
        let info = host.imageInfo(source: source, isRemote: isRemote)
        switch info.state {
        case 1:
            return .ready(CGSize(width: info.width, height: info.height))
        case 2:
            return .failed
        default:
            return .loading
        }
    }

    func syncHostViews(_ viewsJSON: String) {
        host.syncHostViews(viewsJSON: viewsJSON)
    }

    func registerImage(_ source: String, bytes: [UInt8]) {
        host.registerImage(source: source, bytes: bytes)
    }

    func beginTextInput(_ text: String, in rect: CGRect, fontSize: Double) {
        host.beginTextInput(
            text: text, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height,
            fontSize: fontSize)
    }

    func endTextInput() {
        host.endTextInput()
    }

    func scheduleRender() {
        host.scheduleRender()
    }

    func setColorScheme(dark: Bool) {
        host.setColorScheme(dark: dark)
    }

    func now() -> Double {
        host.now()
    }

    /// The page's `Date.now()` (the frame clock is `performance.now()`).
    func wallClock() -> Double {
        Double(_WebBridgeCalls.epochMilliseconds()) / 1000
    }

    func rasterize(_ spec: String) -> [UInt8] {
        host.rasterize(spec: spec)
    }

    func log(_ message: String) {
        host.log(message: message)
    }

    func openURL(_ url: String) {
        host.openURL(url: url)
    }

    func platformCommand(_ key: String, _ value: String) {
        host.platformCommand(key: key, value: value)
    }
}
