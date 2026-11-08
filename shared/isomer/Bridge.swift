// The platform's native bridging API (logging, the clock, opening URLs),
// answered by the running host's `PlatformBridge` (IsomerSwiftUI), or, before
// any host has started, by standard error and the system clock.

import Foundation
import IsomerSwiftUI

public enum Bridge {
    public static var platformName: String { PlatformBridges.current?.platformName ?? "Unknown" }
    public static var rendererName: String { PlatformBridges.current?.rendererName ?? "None" }

    public static func log(_ message: String) {
        if let bridge = PlatformBridges.current {
            bridge.log(message)
        } else {
            FileHandle.standardError.write(Data(("[iso] " + message + "\n").utf8))
        }
    }

    public static func epochMilliseconds() -> Int64 {
        PlatformBridges.current?.epochMilliseconds() ?? Int64(Date().timeIntervalSince1970 * 1000)
    }

    public static func openURL(_ url: String) {
        PlatformBridges.current?.openURL(url)
    }
}
