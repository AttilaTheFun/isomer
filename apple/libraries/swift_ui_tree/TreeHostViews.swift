// Host views of the Isomer module drawn as Apple's own: the same views the
// Isomer module gives an app built against Apple's SwiftUI
// (apple/libraries/swift_ui), so a story is drawn alike either way.

import SwiftUI
import WebKit

/// `WebView(url:)` (host view "webview", its URL the node's value): a
/// WKWebView, as AppleWebView.swift's.
#if os(iOS) || os(tvOS) || os(visionOS)
struct TreeWebView: UIViewRepresentable {
    let url: URL?
    func makeUIView(context: Context) -> WKWebView { WKWebView() }
    func updateUIView(_ webView: WKWebView, context: Context) {
        guard let url, webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}
#elseif os(macOS)
struct TreeWebView: NSViewRepresentable {
    let url: URL?
    func makeNSView(context: Context) -> WKWebView { WKWebView() }
    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let url, webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}
#endif
