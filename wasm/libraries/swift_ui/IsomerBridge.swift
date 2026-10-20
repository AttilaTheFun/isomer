// Native bridging API for the web platform, carried over the swift_ffi
// WebHost interface (see WebBridge.swift). This module is the worked example
// of the bridging pattern documented in the README.

import SwiftUI

public enum Bridge {
    public static var platformName: String { "Web (WebAssembly)" }
    public static var rendererName: String { _boundRendererName }

    public static func log(_ message: String) {
        _WebBridgeCalls.log(message)
    }

    public static func epochMilliseconds() -> Int64 {
        _WebBridgeCalls.epochMilliseconds()
    }

    public static func openURL(_ url: String) {
        _WebBridgeCalls.openURL(url)
    }
}
