// A web app's site, from the app's bundle, at `isomer-app://app/…`: the
// origin of an app in web-view mode (IsomerWebViewHost). A scheme of the
// app's own rather than file: URLs, which a page can't import modules or
// fetch its wasm from; and a stable origin, so what the page keeps (the
// app's files, in IndexedDB) is there at the next launch.
//
// Each file goes with the type a browser needs of it: JavaScript for a
// module, application/wasm for WebAssembly's streaming compile. The query
// (the site's `?v=` stamps) is ignored; nothing outside the site is served.

import Foundation
import WebKit

@MainActor
final class IsomerSiteSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "isomer-app"

    private let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        // Mapped, not read: the reactor is tens of megabytes.
        guard file.path.hasPrefix(root.path + "/"),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe)
        else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
            task.didReceive(response)
            task.didReceive(Data())
            task.didFinish()
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": Self.type(of: file.pathExtension),
            "Content-Length": String(data.count),
            // The bundle's files change only with the app.
            "Cache-Control": "no-cache",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        // Each file is answered whole in `start`: nothing left to stop.
    }

    static func type(of pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "wasm": "application/wasm"
        case "json": "application/json"
        case "css": "text/css; charset=utf-8"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "txt": "text/plain; charset=utf-8"
        default: "application/octet-stream"
        }
    }
}
