// A portable hot-reload server for the desktop (Linux / Windows) wasm cells —
// the cross-platform peer of the macOS `HotReloadServer` (which uses Apple's
// Network.framework). This one is plain Foundation + BSD sockets, so ONE server
// process can drive a Linux wasm app and a Windows wasm app at the same time:
// each polls `GET /version` and re-fetches `GET /wasm` when the build counter
// bumps. The server watches the reactor's source dir, rebuilds the wasm on every
// edit, and serves the immutable byte snapshot to any number of clients at once.
//
//   bazel run //shared/hot_reload:hot_reload_server
//
// Config (env):
//   ISO_HOT_RELOAD_PORT    listen port (default 8787)
//   ISO_HOT_RELOAD_TARGET  bazel wasm target (default the full example reactor)
//   ISO_HOT_RELOAD_WATCH   source dir to watch, workspace-relative
//
// Endpoints: GET /version -> build counter (text); GET /wasm -> reactor bytes
// (application/wasm); GET /clients -> recently-polled clients (text).
//
// Multi-client: each accepted connection is served on a concurrent queue off an
// immutable byte snapshot taken under a lock, while builds run on a dedicated
// serial queue — so a multi-second rebuild never blocks a polling client.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

// MARK: - Socket portability

#if canImport(WinSDK)
private typealias SocketHandle = SOCKET
private let kInvalidSocket = INVALID_SOCKET
private func closeSocket(_ s: SocketHandle) { closesocket(s) }
#else
private typealias SocketHandle = Int32
private let kInvalidSocket: SocketHandle = -1
private func closeSocket(_ s: SocketHandle) { close(s) }
#endif

@main
struct HotReloadServerMain {
    static func main() {
        guard let workspace = ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"] else {
            FileHandle.standardError.write(Data("Run with `bazel run` (BUILD_WORKSPACE_DIRECTORY unset)\n".utf8))
            exit(1)
        }
        let env = ProcessInfo.processInfo.environment
        let port = UInt16(env["ISO_HOT_RELOAD_PORT"] ?? "") ?? 8787
        let target = env["ISO_HOT_RELOAD_TARGET"] ?? "//examples/wasm/example_full_feature:example_full.wasm"
        let watch = env["ISO_HOT_RELOAD_WATCH"] ?? "examples/shared/example_application"
        let server = Server(workspace: workspace, port: port, target: target, watchDir: watch)
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

/// Tracks which clients polled recently (for the `/clients` demo view).
final class Clients {
    private let lock = NSLock()
    private var lastSeen: [String: Date] = [:]
    private let ttl: TimeInterval = 3

    @discardableResult
    func seen(_ host: String) -> Bool {
        lock.withLock {
            let isNew = lastSeen[host] == nil || Date().timeIntervalSince(lastSeen[host]!) > ttl
            lastSeen[host] = Date()
            return isNew
        }
    }

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
    private let target: String
    private let watchDir: String
    private let build = Build()
    private let clients = Clients()
    private let serveQueue = DispatchQueue(label: "hot-reload.serve", attributes: .concurrent)
    private let buildQueue = DispatchQueue(label: "hot-reload.build")
    private var lastStamp: TimeInterval = 0

    /// Resolves the target `//pkg:name.wasm` to its bazel-bin artifact path.
    private var wasmPath: String {
        let body = target.hasPrefix("//") ? String(target.dropFirst(2)) : target
        let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
        let pkg = parts.first ?? ""
        let name = parts.count > 1 ? parts[1] : pkg
        return workspace + "/bazel-bin/" + pkg + "/" + name
    }
    private var sourceDir: String { workspace + "/" + watchDir }

    init(workspace: String, port: UInt16, target: String, watchDir: String) {
        self.workspace = workspace
        self.port = port
        self.target = target
        self.watchDir = watchDir
    }

    func run() {
        log("Building initial wasm (\(target))…")
        rebuild()
        startHTTP()
        startWatching()
        log("Serving on http://0.0.0.0:\(port) — any number of clients at once.")
        log("  Linux / Windows wasm cell:  ISO_HOT_RELOAD_SERVER=http://localhost:\(port)")
        log("  (a peer on another host uses this machine's LAN IP)")
        log("Watching \(sourceDir) — edit a source file and every connected app re-renders.")
    }

    // MARK: - Build + watch

    private func startWatching() {
        lastStamp = newestModification()
        let timer = DispatchSource.makeTimerSource(queue: buildQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let stamp = self.newestModification()
            guard stamp > self.lastStamp else { return }
            self.lastStamp = stamp
            self.rebuild()
            self.lastStamp = self.newestModification()
        }
        timer.resume()
        watchTimer = timer
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
        process.arguments = ["bazel", "build", target]
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

    // MARK: - HTTP (BSD sockets)

    private func startHTTP() {
        #if canImport(WinSDK)
        var wsaData = WSADATA()
        _ = WSAStartup(0x0202, &wsaData)
        #endif
        let listenSocket = socket(AF_INET, sockStreamType, 0)
        guard listenSocket != kInvalidSocket else {
            log("Failed to create socket"); exit(1)
        }
        var yes: Int32 = 1
        withUnsafePointer(to: &yes) { p in
            _ = setsockopt(listenSocket, SOL_SOCKET, SO_REUSEADDR, p, socklen_t(MemoryLayout<Int32>.size))
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY  // 0 — all interfaces (LAN peers can reach it)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                bind(listenSocket, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { log("Failed to bind port \(port)"); exit(1) }
        guard listen(listenSocket, 64) == 0 else { log("Failed to listen"); exit(1) }

        // Accept loop on its own thread; each connection is served concurrently.
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(listenSocket, nil, nil)
                if client == kInvalidSocket { continue }
                self?.serveQueue.async { self?.handle(client) }
            }
        }
    }

    private func handle(_ client: SocketHandle) {
        defer { closeSocket(client) }
        var request = [UInt8](repeating: 0, count: 4096)
        let received = request.withUnsafeMutableBytes { recv(client, $0.baseAddress, 4096, 0) }
        guard received > 0 else { return }
        let text = String(decoding: request[0..<Int(received)], as: UTF8.self)
        let path = text.split(separator: " ").dropFirst().first.map(String.init) ?? "/"

        if clients.seen("client") {
            log("client connected (\(clients.active.count) attached)")
        }

        switch path {
        case "/version":
            respond(client, "200 OK", "text/plain", Data("\(build.version)".utf8))
        case "/wasm":
            respond(client, "200 OK", "application/wasm", build.bytes)
        case "/clients":
            respond(client, "200 OK", "text/plain", Data(clients.active.joined(separator: "\n").utf8))
        default:
            respond(client, "404 Not Found", "text/plain", Data("not found".utf8))
        }
    }

    private func respond(_ client: SocketHandle, _ status: String, _ contentType: String, _ body: Data) {
        var response = Data("""
            HTTP/1.1 \(status)\r
            Content-Type: \(contentType)\r
            Content-Length: \(body.count)\r
            Access-Control-Allow-Origin: *\r
            Connection: close\r
            \r

            """.utf8)
        response.append(body)
        response.withUnsafeBytes { raw in
            var sent = 0
            let total = raw.count
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while sent < total {
                let n = send(client, base + sent, total - sent, 0)
                if n <= 0 { break }
                sent += Int(n)
            }
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[hot-reload-server] \(message)\n".utf8))
    }
}

// SOCK_STREAM is an enum on Glibc but a raw Int32 on Windows; normalize.
#if canImport(WinSDK)
private let sockStreamType = Int32(SOCK_STREAM)
#else
private let sockStreamType = Int32(SOCK_STREAM.rawValue)
#endif
