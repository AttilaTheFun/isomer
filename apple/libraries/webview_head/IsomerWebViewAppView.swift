// A whole Isomer app in web-view mode (docs/modes.md), as a view: its Swift
// runs as wasm in a web view this view keeps out of sight (the app's web
// site, bundled), and Apple's tree renderer draws it over the session
// protocol (IsomerRemoteView).
//
//   WindowGroup {
//       IsomerWebViewAppView(site: Bundle.main.url(forResource: "app_site", withExtension: nil)!)
//   }
//
// The web view sits behind what the app draws, 1×1 point and nearly
// transparent, in the app's window: WebKit runs a page's timers and
// animation frames at full rate only while it counts the view visible (on
// iOS, in a window whose scene is in the foreground; on the Mac, also on
// screen and not covered), and throttles or suspends it otherwise.

import IsomerRemoteHead
import SwiftUI
import WebKit

public struct IsomerWebViewAppView: View {
    @State private var host: IsomerWebViewHost
    private let environment: [String: String]

    /// `site` is the app's web site in the bundle (an isomer_web_app's
    /// `<name>_site` as a resource folder); `environment` its launch hooks
    /// (ISO_ only), as a native host's process environment.
    public init(site: URL, environment: [String: String] = [:]) {
        _host = State(initialValue: IsomerWebViewHost(site: site))
        self.environment = environment
    }

    /// An app's own host (its web view configured, or shared).
    public init(host: IsomerWebViewHost, environment: [String: String] = [:]) {
        _host = State(initialValue: host)
        self.environment = environment
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            IsomerPageHolder(webView: host.webView)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            IsomerRemoteView(connection: host.connection, environment: environment)
        }
    }
}

/// The web view in the view hierarchy, as it is: the host owns it.
#if os(iOS)
private struct IsomerPageHolder: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#elseif os(macOS)
private struct IsomerPageHolder: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
