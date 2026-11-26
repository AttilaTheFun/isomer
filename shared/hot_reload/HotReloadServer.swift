// A hot-reload server for any wasm feature or reactor, on macOS and Linux
// (and Windows' sockets, not yet exercised): plain Foundation + BSD sockets,
// so ONE server process can drive an iPhone simulator, an Android emulator,
// a Linux wasm app and a Windows one at the same time:
// each polls `GET /version` and re-fetches `GET /wasm` when the build counter
// bumps. The server watches the reactor's source dir, rebuilds the wasm on every
// edit, and serves the immutable byte snapshot to any number of clients at once.
//
//   bazel run @isomer//shared/hot_reload:hot_reload_server -- \
//     --target=//app/feature:feature.wasm --watch=app/feature [--flag=--config=…]
//
// From any workspace that depends on isomer: it builds in the workspace it's
// run from (BUILD_WORKSPACE_DIRECTORY), and finds the output with `bazel
// cquery --output=files`, so the flags given decide its configuration.
// Config (arguments, else env):
//   --port=, ISO_HOT_RELOAD_PORT      listen port (default 8787)
//   --host=, ISO_HOT_RELOAD_HOST      the address it listens on (default
//                                     127.0.0.1: this machine alone, which a
//                                     simulator shares and an Android emulator
//                                     reaches as 10.0.2.2; 0.0.0.0 for a phone
//                                     on the network, which can then fetch the
//                                     module and read /clients)
//   --target=, ISO_HOT_RELOAD_TARGET  the wasm target (default the full example reactor)
//   --watch=, ISO_HOT_RELOAD_WATCH    source dir to watch, workspace-relative
//   --flag= (repeated), ISO_HOT_RELOAD_FLAGS (space-separated)  build flags
//
// Endpoints: GET /version -> build counter (text); GET /wasm -> reactor bytes
// (application/wasm); GET /clients -> recently-polled clients (text).
//
// Multi-client: each accepted connection is served on a concurrent queue off an
// immutable byte snapshot taken under a lock, while builds run on a dedicated
// serial queue — so a multi-second rebuild never blocks a polling client.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
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
        // Arguments first (`--target=`, `--watch=`, `--port=`, `--host=`,
        // `--flag=` each a further build flag), then the environment, then the
        // example's.
        var arguments: [String: String] = [:]
        var flags = (env["ISO_HOT_RELOAD_FLAGS"] ?? "").split(separator: " ").map(String.init)
        for argument in CommandLine.arguments.dropFirst() {
            guard argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") else { continue }
            let key = String(argument[argument.index(argument.startIndex, offsetBy: 2)..<equals])
            let value = String(argument[argument.index(after: equals)...])
            if key == "flag" { flags.append(value) } else { arguments[key] = value }
        }
        let port = UInt16(arguments["port"] ?? env["ISO_HOT_RELOAD_PORT"] ?? "") ?? 8787
        let host = arguments["host"] ?? env["ISO_HOT_RELOAD_HOST"] ?? "127.0.0.1"
        let target = arguments["target"] ?? env["ISO_HOT_RELOAD_TARGET"] ?? "//examples/wasm/example_full_feature:example_full.wasm"
        let watch = arguments["watch"] ?? env["ISO_HOT_RELOAD_WATCH"] ?? "examples/shared/example_application"
        let server = Server(workspace: workspace, host: host, port: port, target: target, watchDir: watch, flags: flags)
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
    private let host: String
    private let port: UInt16
    private let target: String
    private let watchDir: String
    private let build = Build()
    private let clients = Clients()
    private let serveQueue = DispatchQueue(label: "hot-reload.serve", attributes: .concurrent)
    private let buildQueue = DispatchQueue(label: "hot-reload.build")
    private var lastStamp: TimeInterval = 0

    /// Build flags given after the target (a `--config`, a platform).
    private let flags: [String]

    /// The target's .wasm, as Bazel names it for these flags (`cquery
    /// --output=files`): not `bazel-bin`'s, which follows whatever
    /// configuration was built last.
    private var wasmPath: String? {
        let (ok, output) = runBazel(["cquery", "--output=files", target] + flags)
        guard ok else { return nil }
        guard let file = output.split(separator: "\n").map(String.init).last(where: { $0.hasSuffix(".wasm") }) else { return nil }
        return file.hasPrefix("/") ? file : workspace + "/" + file
    }
    private var sourceDir: String { workspace + "/" + watchDir }

    init(workspace: String, host: String, port: UInt16, target: String, watchDir: String, flags: [String] = []) {
        self.flags = flags
        self.workspace = workspace
        self.host = host
        self.port = port
        self.target = target
        self.watchDir = watchDir
    }

    func run() {
        log("Building initial wasm (\(target))…")
        rebuild()
        startHTTP()
        startWatching()
        log("Serving on http://\(host):\(port) — any number of clients at once.")
        log("  Linux / Windows wasm cell:  ISO_HOT_RELOAD_SERVER=http://localhost:\(port)")
        log("  (an Android emulator: http://10.0.2.2:\(port); a phone on the network needs --host=0.0.0.0 and this machine's LAN IP)")
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
        guard let path = wasmPath else {
            log("Build ok but bazel cquery named no .wasm for \(target)")
            return
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
            log("Build ok but could not read \(path)")
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

    private func runBazel(_ arguments: [String]? = nil) -> (ok: Bool, log: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bazel"] + (arguments ?? ["build", target] + flags)
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
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        // The address asked for (`--host=`): loopback by default, so a
        // machine on a shared network doesn't hand its module to anyone on it.
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            log("Not an IPv4 address to listen on: \(host)")
            exit(2)
        }
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                bind(listenSocket, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { log("Failed to bind \(host):\(port)"); exit(1) }
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

// SOCK_STREAM is an enum on Glibc but a raw Int32 on Darwin and Windows;
// normalize.
#if canImport(Glibc)
private let sockStreamType = Int32(SOCK_STREAM.rawValue)
#else
private let sockStreamType = Int32(SOCK_STREAM)
#endif
