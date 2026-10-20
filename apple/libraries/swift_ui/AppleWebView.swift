// Apple's half of `SwiftUIExtensions`'s `WebView`: a native WKWebView so
// app code writes `WebView(url:)` on every platform.

import SwiftUI
import WebKit

#if os(iOS) || os(tvOS) || os(visionOS)
public struct WebView: UIViewRepresentable {
    let url: URL?
    public init(url: URL?) { self.url = url }
    public func makeUIView(context: Context) -> WKWebView { WKWebView() }
    public func updateUIView(_ webView: WKWebView, context: Context) {
        guard let url, webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}
#elseif os(macOS)
public struct WebView: NSViewRepresentable {
    let url: URL?
    public init(url: URL?) { self.url = url }
    public func makeNSView(context: Context) -> WKWebView { WKWebView() }
    public func updateNSView(_ webView: WKWebView, context: Context) {
        guard let url, webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}
#endif
