// The hot-reload server: a standalone macOS process (run in its own shell)
// that watches the demo source, recompiles the wasm on every edit, and serves
// the bytes over localhost HTTP with a version counter. Apps connect with a
// HotReloadClient (set ISO_HOT_RELOAD_SERVER) and reload when the version
// bumps — so one server drives the macOS host, the iOS Simulator, an Android
// emulator/device, and real iOS devices ALL AT ONCE, none of which need to run
// a compiler themselves. Edit HotDemo.swift once and every connected app
// re-renders side by side.
//
//   bazel run //examples/apple/example_partial_wasm_macos_application:hot_reload_server
//
// Endpoints:
//   GET /version -> current build number (text)
//   GET /wasm    -> current reactor bytes (application/wasm)
//   GET /clients -> one line per client that has polled recently (text)
//
// Multi-client: builds run on a dedicated serial queue and connections on a
// concurrent queue, so a multi-second rebuild never blocks a polling client
// (which would otherwise trip its request timeout). The bytes served are an
// immutable snapshot taken under a lock, so any number of clients can download
// concurrently — including while the next build is in flight.
//
// Reaching the host from a device: the iOS Simulator and macOS use
// http://localhost:<port>; an Android emulator uses http://10.0.2.2:<port>
// (its alias for the host loopback); a physical device uses the Mac's LAN IP.

import Foundation
import Network

@main
struct HotReloadServer {
    static func main() {
        guard let workspace = ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"] else {
            FileHandle.standardError.write(Data("Run with `bazel run` (BUILD_WORKSPACE_DIRECTORY unset)\n".utf8))
            exit(1)
        }
        let port = UInt16(ProcessInfo.processInfo.environment["ISO_HOT_RELOAD_PORT"] ?? "") ?? 8787
        let server = Server(workspace: workspace, port: port)
        server.run()
        dispatchMain()
    }
}

/// Thread-safe holder for the current build.
final class Build {
    private let lock = NSLock()
    private var _version = 0
    private var _bytes = Data()

    var version: Int { lock.withLock { _version } }
    var bytes: Data { lock.withLock { _bytes } }

    func update(_ data: Data) {
        lock.withLock { _version += 1; _bytes = data }
    }
}

/// Tracks which clients have polled recently, so the demo can show iOS + Android
/// + macOS all connected to one server at a glance. Keyed by remote host; a
/// client drops off the list after it stops polling for a few seconds.
final class Clients {
    private let lock = NSLock()
    private var lastSeen: [String: Date] = [:]
    private let ttl: TimeInterval = 3

    /// Record a poll from `host`; returns true if this host is newly connected.
    @discardableResult
    func seen(_ host: String) -> Bool {
        lock.withLock {
            let isNew = lastSeen[host] == nil || Date().timeIntervalSince(lastSeen[host]!) > ttl
            lastSeen[host] = Date()
            return isNew
        }
    }

    /// Hosts seen within the TTL, sorted for stable output.
    var active: [String] {
        lock.withLock {
            let cutoff = Date().addingTimeInterval(-ttl)
            return lastSeen.filter { $0.value >= cutoff }.keys.sorted()
        }
    }
}

final class Server {
    private let workspace: String
    private let port: UInt16
    private let build = Build()
    private let clients = Clients()
    // Serving: concurrent, so many clients download at once and none blocks
    // another. Building: a dedicated serial queue, so a multi-second `bazel
    // build` never stalls the listener or an in-flight download.
    private let serveQueue = DispatchQueue(label: "hot-reload.serve", attributes: .concurrent)
    private let buildQueue = DispatchQueue(label: "hot-reload.build")

    // Relative to the EXAMPLES workspace (BUILD_WORKSPACE_DIRECTORY when this
    // is `bazel run` from examples/ — the workspace the demo apps live in).
    private let pkg = "wasm/hot_demo_feature"
    private var wasmPath: String { workspace + "/bazel-bin/" + pkg + "/hot_demo.wasm" }
    private var sourceDir: String { workspace + "/" + pkg }
    private var lastStamp: TimeInterval = 0

    init(workspace: String, port: UInt16) {
        self.workspace = workspace
        self.port = port
    }

    func run() {
        log("Building initial wasm…")
        rebuild()
        startHTTP()
        startWatching()
        log("Serving on http://localhost:\(port) — serves any number of clients at once.")
        log("  iOS Simulator / macOS:  ISO_HOT_RELOAD_SERVER=http://localhost:\(port)")
        log("  Android emulator:       ISO_HOT_RELOAD_SERVER=http://10.0.2.2:\(port)")
        log("  Physical device:        ISO_HOT_RELOAD_SERVER=http://<your-mac-LAN-IP>:\(port)")
        log("Watching \(sourceDir) — edit HotDemo.swift and every connected app re-renders side by side.")
    }

    // MARK: - Build + watch

    private func startWatching() {
        lastStamp = newestModification()
        let t = DispatchSource.makeTimerSource(queue: buildQueue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let stamp = self.newestModification()
            guard stamp > self.lastStamp else { return }
            self.lastStamp = stamp
            self.rebuild()
            self.lastStamp = self.newestModification()
        }
        t.resume()
        watchTimer = t
    }

    private var watchTimer: DispatchSourceTimer?

    private func rebuild() {
        let started = Date()
        let result = runBazel()
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(started))
        guard result.ok else {
            log("Build FAILED (\(elapsed)) — keeping build \(build.version):\n\(result.log)")
            return
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: wasmPath)), !data.isEmpty else {
            log("Build ok but could not read \(wasmPath)")
            return
        }
        build.update(data)
        log("Built \(data.count) bytes in \(elapsed) → serving build \(build.version)")
    }

    private func newestModification() -> TimeInterval {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: sourceDir) else { return 0 }
        var newest: TimeInterval = 0
        for entry in entries where entry.hasSuffix(".swift") {
            if let attrs = try? fm.attributesOfItem(atPath: sourceDir + "/" + entry),
               let date = attrs[.modificationDate] as? Date {
                newest = max(newest, date.timeIntervalSince1970)
            }
        }
        return newest
    }

    private func runBazel() -> (ok: Bool, log: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bazel", "build", "//" + pkg + ":hot_demo.wasm"]
        process.currentDirectoryURL = URL(fileURLWithPath: workspace)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
        } catch {
            return (false, "spawn failed: \(error)")
        }
    }

    // MARK: - HTTP (Network.framework)

    private var listener: NWListener?

    private func startHTTP() {
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: .tcp, on: nwPort)
        else {
            log("Failed to listen on port \(port)")
            exit(1)
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            conn.start(queue: self.serveQueue)
            self.handle(conn)
        }
        listener.start(queue: serveQueue)
        self.listener = listener
    }

    private func handle(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let host = self.remoteHost(of: conn)
            // A poll from a not-recently-seen client → announce it so the demo
            // shows each device attaching to the shared server.
            if self.clients.seen(host) {
                self.log("client connected: \(host)  (\(self.clients.active.count) now attached: \(self.clients.active.joined(separator: ", ")))")
            }
            switch path {
            case "/version":
                self.respond(conn, "200 OK", "text/plain", Data("\(self.build.version)".utf8))
            case "/wasm":
                self.respond(conn, "200 OK", "application/wasm", self.build.bytes)
            case "/clients":
                self.respond(conn, "200 OK", "text/plain", Data(self.clients.active.joined(separator: "\n").utf8))
            default:
                self.respond(conn, "404 Not Found", "text/plain", Data("not found".utf8))
            }
        }
    }

    /// Best-effort remote host for a connection (for demo/logging only).
    private func remoteHost(of conn: NWConnection) -> String {
        switch conn.currentPath?.remoteEndpoint ?? conn.endpoint {
        case let .hostPort(host, _):
            switch host {
            case let .ipv4(addr): return "\(addr)"
            case let .ipv6(addr): return "\(addr)".hasPrefix("::ffff:") ? String("\(addr)".dropFirst(7)) : "\(addr)"
            case let .name(name, _): return name
            @unknown default: return "?"
            }
        default:
            return "?"
        }
    }

    private func respond(_ conn: NWConnection, _ status: String, _ contentType: String, _ body: Data) {
        var response = Data("""
            HTTP/1.1 \(status)\r
            Content-Type: \(contentType)\r
            Content-Length: \(body.count)\r
            Access-Control-Allow-Origin: *\r
            Connection: close\r
            \r

            """.utf8)
        response.append(body)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[hot-reload-server] \(message)\n".utf8))
    }
}
