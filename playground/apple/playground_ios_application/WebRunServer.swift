// The web-run half: a tiny in-app HTTP server (Network.framework, the same
// listener shape as the hot-reload server) serving the bundled playground
// site — index.html + the react renderer + the generic iso_hot host
// (hot_host.js) — plus /app.wasm, the LATEST user build. "Run in Safari"
// opens SFSafariViewController at this server; the page instantiates the
// reactor with the browser's own WebAssembly engine and mounts it as real
// DOM through the react renderer.

import Foundation
import Network
import SafariServices
import SwiftUI

final class WebRunServer {
    static let shared = WebRunServer()

    private let queue = DispatchQueue(label: "playground.web-server", attributes: .concurrent)
    private let lock = NSLock()
    private var listener: NWListener?
    private var wasmBytes = Data()
    private(set) var port: UInt16 = 0

    private var siteRoot: URL? {
        // rules_apple flattens tree-artifact resources into the bundle root
        // (index.html, hot_host.js, runtime/ land beside Info.plist); a named
        // playground_site folder is accepted too.
        Bundle.main.url(forResource: "playground_site", withExtension: nil)
            ?? Bundle.main.resourceURL
    }

    /// Publishes `wasm` as /app.wasm and ensures the server is listening.
    /// Returns the site URL to open.
    /// The project sandbox served under /sandbox/ (imported assets for the
    /// web run's file service; read-only).
    private var sandboxRoot: URL?

    func publish(wasm: Data, sandbox: URL? = nil) -> URL? {
        lock.withLock { wasmBytes = wasm; sandboxRoot = sandbox }
        start()
        guard port != 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/index.html")
    }

    private func start() {
        // A listener iOS tore down (the app sat in the background, the
        // network path changed) reports failed/cancelled: replace it, or the
        // next "Run on the web" opens a page that never loads.
        if let existing = listener {
            if existing.state == .ready { return }
            existing.cancel()
            self.listener = nil
            port = 0
        }
        guard let listener = try? NWListener(using: .tcp, on: .any) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: self.queue)
            self.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = self?.listener?.port?.rawValue ?? 0
            case .failed, .cancelled:
                NSLog("[playground] web run server listener %@", String(describing: state))
                self?.listener = nil
                self?.port = 0
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        // Synchronously wait briefly for the port so publish() can build the URL.
        for _ in 0..<100 where port == 0 { usleep(10_000) }
    }

    private func handle(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = target == "/" ? "/index.html" : target
            if path == "/app.wasm" {
                let bytes = self.lock.withLock { self.wasmBytes }
                self.respond(connection, type: "application/wasm", body: bytes)
                return
            }
            // The project sandbox (imported assets): /sandbox/<relative path>,
            // and /sandbox-list/<dir> as newline-separated names.
            if path.hasPrefix("/sandbox/") || path.hasPrefix("/sandbox-list/"), !path.contains("..") {
                let listing = path.hasPrefix("/sandbox-list/")
                let relative = String(path.dropFirst(listing ? "/sandbox-list/".count : "/sandbox/".count))
                    .removingPercentEncoding ?? ""
                guard let sandbox = self.lock.withLock({ self.sandboxRoot }) else {
                    self.respond(connection, status: "404 Not Found", type: "text/plain", body: Data("no sandbox".utf8))
                    return
                }
                let target = sandbox.appendingPathComponent(relative)
                if listing {
                    let names = ((try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []).sorted()
                    self.respond(connection, type: "text/plain", body: Data(names.joined(separator: "\n").utf8))
                } else if let body = try? Data(contentsOf: target) {
                    self.respond(connection, type: Self.contentType(for: target.pathExtension), body: body)
                } else {
                    self.respond(connection, status: "404 Not Found", type: "text/plain", body: Data("not found".utf8))
                }
                return
            }
            // Static site files (index.html, hot_host.js, runtime/…) — served
            // from the bundle; reject traversal.
            guard let root = self.siteRoot, !path.contains("..") else {
                self.respond(connection, status: "404 Not Found", type: "text/plain", body: Data("not found".utf8))
                return
            }
            let file = root.appendingPathComponent(String(path.dropFirst()))
            guard let body = try? Data(contentsOf: file) else {
                self.respond(connection, status: "404 Not Found", type: "text/plain", body: Data("not found".utf8))
                return
            }
            self.respond(connection, type: Self.contentType(for: file.pathExtension), body: body)
        }
    }

    private static func contentType(for ext: String) -> String {
        switch ext {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "wasm": return "application/wasm"
        case "css": return "text/css"
        default: return "application/octet-stream"
        }
    }

    private func respond(
        _ connection: NWConnection, status: String = "200 OK",
        type: String, body: Data
    ) {
        var response = Data("""
            HTTP/1.1 \(status)\r
            Content-Type: \(type)\r
            Content-Length: \(body.count)\r
            Cache-Control: no-store\r
            Connection: close\r
            \r

            """.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// SFSafariViewController, presentable from SwiftUI.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    /// Its Done button: the presenting SwiftUI state dismisses the cover.
    var onDone: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onDone() }
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
