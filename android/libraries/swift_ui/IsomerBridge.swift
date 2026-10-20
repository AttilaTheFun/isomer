// Native bridging API for Android — same surface as the Apple and wasm
// implementations. Logging goes to logcat, the clock to POSIX time, and
// openURL is forwarded up to Kotlin through the swift_ffi AndroidHost.

import SwiftUI

public enum Bridge {
    public static var platformName: String { "Android" }
    public static var rendererName: String { _boundRendererName }

    public static func log(_ message: String) {
        _ = message.withCString { cMessage in
            "IsomerBridge".withCString { cTag in
                __android_log_write(Int32(ANDROID_LOG_INFO.rawValue), cTag, cMessage)
            }
        }
    }

    public static func epochMilliseconds() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
    }

    public static func openURL(_ url: String) {
        _AndroidBridgeCalls.openURL(url)
    }
}
