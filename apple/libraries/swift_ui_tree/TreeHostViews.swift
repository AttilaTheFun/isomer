// Host views of the Isomer module drawn as Apple's own: the same views the
// Isomer module gives an app built against Apple's SwiftUI
// (apple/libraries/swift_ui), so a story is drawn alike either way.

import AVKit
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

/// `VideoPlayer(url:)` (host view "video", its URL the node's value): as
/// the Isomer module's on Apple (apple/libraries/swift_ui/IsomerBridge.swift):
/// AVKit's player on iOS, AppKit's AVPlayerView on the Mac (AVKit's SwiftUI
/// player aborts on macOS 27), black without a URL.
struct TreeVideoPlayer: View {
    let url: URL?

    var body: some View {
        if let url {
            #if os(macOS)
            TreeMacPlayerView(url: url)
            #else
            AVKit.VideoPlayer(player: AVPlayer(url: url))
            #endif
        } else {
            Color.black
        }
    }
}

#if os(macOS)
/// AppKit's player view, with its inline controls.
private struct TreeMacPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
    }
}
#endif
