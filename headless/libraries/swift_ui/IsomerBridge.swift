// Native bridging API for the headless host: nothing to bridge to, so the
// platform's calls are answered here (the log to standard error, URLs
// recorded for the driver).

import Foundation

public enum Bridge {
    public static var platformName: String { "Headless" }
    public static var rendererName: String { "None" }

    public static func log(_ message: String) {
        FileHandle.standardError.write(Data(("[iso] " + message + "\n").utf8))
    }

    public static func epochMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    public static func openURL(_ url: String) {
        FileHandle.standardError.write(Data(("[iso] openURL " + url + "\n").utf8))
    }
}
