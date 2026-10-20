import Foundation
import SwiftUI

// A web view: an `<iframe>` on the web and a native `android.webkit.WebView`
// on Android, bridged through the same host-view mechanism as Picker/Menu. On
// Apple the shim provides a `WKWebView`-backed implementation with the same
// `WebView(url:)` API.

public struct WebView: PlatformViewRepresentable {
    let urlString: String

    public init(url: URL?) {
        self.urlString = url?.absoluteString ?? ""
    }

    public init(urlString: String) {
        self.urlString = urlString
    }

    public var kind: String { "webview" }
    /// The URL travels in `value` (serialized into the host-view spec).
    public var value: String { urlString }
    public func onValueChanged(_ value: String) {}
}
