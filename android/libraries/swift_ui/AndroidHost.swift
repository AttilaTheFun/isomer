// Android host bridge: the shared `HostBridge` implemented over the swift_ffi
// `AndroidHost` that Kotlin passed to `nativeStart` (see AndroidBridge.swift).
// Drawing is serialized into one byte array per frame (returned by the
// `nativeRender` export; see DrawListDecoder.kt for the format); everything
// else calls up through the generated JNI foreign proxy with real values.

internal import IsomerSwiftUI

final class AndroidHostState {
    static let shared = AndroidHostState()

    var renderScheduled = false
}

func androidLog(_ message: String) {
    _ = message.withCString { cMessage in
        "Isomer".withCString { cTag in
            __android_log_write(Int32(ANDROID_LOG_INFO.rawValue), cTag, cMessage)
        }
    }
}

// MARK: - HostBridge implementation

struct AndroidHostBridge: HostBridge {
    var state: AndroidHostState { .shared }
    var host: any AndroidHost { androidHost! }

    // Drawing is SwiftGPURenderer's job — it wraps this bridge, draws every
    // pixel through swift_gpu's GLES backend, and only calls the services half
    // below. The HostBridge drawing methods default to no-ops in the core, so
    // this bridge no longer implements them.

    func rasterize(_ spec: String) -> [UInt8] {
        androidHost?.rasterize(spec: spec) ?? []
    }

    func registerImage(_ source: String, bytes: [UInt8]) {
        androidHost?.registerImage(source: source, bytes: bytes)
    }

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

    func beginTextInput(_ text: String, in rect: CGRect, fontSize: Double) {
        host.beginTextInput(
            text: text, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height,
            fontSize: fontSize)
    }

    func endTextInput() {
        host.endTextInput()
    }

    func scheduleRender() {
        state.renderScheduled = true
    }

    func now() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }

    /// Seconds since 1970 (the skim Foundation's `Date()`).
    func wallClock() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }

    func log(_ message: String) {
        androidLog(message)
    }

    func openURL(_ url: String) {
        host.openURL(url: url)
    }

    func platformCommand(_ key: String, _ value: String) {
        host.platformCommand(key: key, value: value)
    }
}
