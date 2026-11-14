// An app in web-view mode (docs/modes.md): its Swift runs as wasm in a page
// (an isomer_web_app site's webview.html, runtime/session_host.js), by
// WebKit's JIT, in a web view this app owns and keeps out of sight; the app
// draws it with Apple's tree renderer (IsomerRemoteView) over the session
// protocol, as a remote head draws an app on a server. This is the
// session's transport: the page's message channel instead of a socket.
//
// - Client messages go to the page with `callAsyncJavaScript`
//   (`isomerSession.receive(message)`, the bytes as base64), one at a time:
//   IsomerRemoteSession waits for each before the next.
// - Server messages come from the page through the `isomer` message handler
//   (base64 too); `{ ready: true }` says the page can take the session's
//   start, `{ error }` that the app ended it.
// - The site is served from the app's bundle under a scheme of its own
//   (`isomer-app://app/…`, IsomerSiteSchemeHandler): a stable origin, so the
//   page's IndexedDB (the app's files on the web) lasts across launches.
//
// The app never waits on the page on its main thread: every call to the page
// is asynchronous, and the page answers in its own time (the page measures
// and lays out text itself, so a frame never waits on the app).

import Foundation
import IsomerServing
import WebKit

/// The web view an app in web-view mode runs in, and the session's channel
/// to it. One session at a time: each `connect` loads the page afresh (a new
/// guest, whose first frame is its whole tree).
@MainActor
public final class IsomerWebViewHost: NSObject {
    /// The page's view: kept in the app's window, behind what the app draws
    /// (IsomerWebViewAppView), so WebKit counts it visible and doesn't
    /// throttle its timers and animation frames.
    public let webView: WKWebView
    /// The session over this web view.
    public nonisolated var connection: IsomerWebViewConnection { IsomerWebViewConnection(host: self) }

    private let page: URL
    /// The open session's messages from the page, handed on in the order
    /// they came.
    private var inbound: IsomerInbound<[UInt8]>.Continuation?
    /// The open session waiting for the page to be ready.
    private var ready: CheckedContinuation<Void, any Error>?

    /// `site` is the web app's site in the bundle (an isomer_web_app's
    /// `<name>_site`, a resource folder); the page is its `webview.html`,
    /// told the app's identity (Bundle.main's values).
    public init(site: URL, bundle: Bundle = .main) {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(IsomerSiteSchemeHandler(root: site), forURLScheme: IsomerSiteSchemeHandler.scheme)
        // Its storage kept, as a page's on its origin: the app's files.
        configuration.websiteDataStore = .default()
        var components = URLComponents()
        components.scheme = IsomerSiteSchemeHandler.scheme
        components.host = "app"
        components.path = "/webview.html"
        let info = bundle.infoDictionary ?? [:]
        components.queryItems = [
            ("bundleIdentifier", bundle.bundleIdentifier),
            ("bundleName", info["CFBundleName"] as? String),
            ("bundleVersion", info["CFBundleShortVersionString"] as? String),
            ("bundleBuild", info["CFBundleVersion"] as? String),
        ].compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        page = components.url!
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        super.init()
        configuration.userContentController.add(IsomerMessageRelay(self), name: "isomer")
        webView.navigationDelegate = self
        #if os(iOS)
        webView.isUserInteractionEnabled = false
        #endif
        #if DEBUG
        // Safari's Web Inspector, in a build to debug.
        if #available(iOS 16.4, macOS 13.3, *) { webView.isInspectable = true }
        #endif
    }

    /// Opens a session: the page loaded afresh and ready for its start.
    func open() async throws -> IsomerCall<[UInt8], [UInt8]> {
        end(throwing: IsomerCallError(.unavailable, "another session began"))
        let (messages, continuation) = IsomerInbound<[UInt8]>.makeStream()
        inbound = continuation
        webView.load(URLRequest(url: page))
        try await withCheckedThrowingContinuation { ready = $0 }
        return IsomerCall(
            outbound: IsomerOutbound { [weak self] bytes in try await self?.send(bytes) },
            inbound: messages,
            finish: { [weak self] in await self?.close() }
        )
    }

    private func send(_ bytes: [UInt8]) async throws {
        guard inbound != nil else { throw IsomerCallError(.unavailable, "the session has ended") }
        _ = try await webView.callAsyncJavaScript(
            "isomerSession.receive(message)",
            arguments: ["message": Data(bytes).base64EncodedString()],
            contentWorld: .page)
    }

    /// The head finished its half: the session is over, and so is the guest.
    private func close() {
        end(throwing: nil)
        webView.loadHTMLString("", baseURL: nil)
    }

    private func end(throwing error: (any Error)?) {
        ready?.resume(throwing: error ?? IsomerCallError(.unavailable, "the session ended before it began"))
        ready = nil
        if let error { inbound?.finish(throwing: error) } else { inbound?.finish() }
        inbound = nil
    }

    fileprivate func received(_ body: Any) {
        if let text = body as? String {
            guard let data = Data(base64Encoded: text) else { return }
            inbound?.yield([UInt8](data))
        } else if let message = body as? [String: Any] {
            if message["ready"] != nil {
                ready?.resume()
                ready = nil
            } else if let error = message["error"] as? String {
                end(throwing: IsomerCallError(.internal, "the app ended the session: \(error)"))
            }
        }
    }
}

extension IsomerWebViewHost: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    /// WebKit's page process went (its memory taken back, or a crash): the
    /// guest with it.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        end(throwing: IsomerCallError(.unavailable, "the web view's process ended"))
    }

    private func failed(_ error: any Error) {
        // A load replaced by the next session's, or by the closing blank page.
        if (error as NSError).code == NSURLErrorCancelled { return }
        end(throwing: IsomerCallError(.unavailable, "the page didn't load: \(error.localizedDescription)"))
    }
}

/// The session's transport for IsomerRemoteSession and IsomerRemoteView: a
/// head's `Session.Connect` over the web view's page. The other calls
/// (driving, attaching) are a server's, not a page's.
public struct IsomerWebViewConnection: IsomerConnection {
    let host: IsomerWebViewHost

    public func open(_ method: IsomerMethod, context: IsomerCallContext) async throws -> IsomerCall<[UInt8], [UInt8]> {
        guard method == .connect else {
            throw IsomerCallError(.unimplemented, "a web view's page serves a head's session only, not \(method.rawValue)")
        }
        return try await host.open()
    }
}

/// WebKit keeps its message handler strongly: this holds the host weakly.
private final class IsomerMessageRelay: NSObject, WKScriptMessageHandler {
    weak var host: IsomerWebViewHost?

    init(_ host: IsomerWebViewHost) {
        self.host = host
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { host?.received(body) }
    }
}
