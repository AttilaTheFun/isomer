// BrowserDriving: a site served on a loopback port and headless Chrome
// driven over the DevTools protocol on a pipe (--remote-debugging-pipe: no
// port, nothing listening but the site), for the tools that run something in
// a browser where it was built: browser_check (a site's pages, pictured) and
// wasi_run_browser (a WASI command, run in a page's worker).
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What the tool's messages are headed with.
public enum BrowserDriving {
    nonisolated(unsafe) public static var tool = "browser"
}

public func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(BrowserDriving.tool): \(message)\n".utf8))
    exit(2)
}

public func log(_ message: String) {
    FileHandle.standardError.write(Data("\(BrowserDriving.tool): \(message)\n".utf8))
}

// MARK: The site, served on a loopback port

/// A static file server on 127.0.0.1, a thread a connection, one request a
/// connection (Connection: close), nothing cached.
public final class SiteServer: @unchecked Sendable {
    public let root: URL
    public let port: UInt16
    private let socketFD: Int32

    public init(root: URL) {
        self.root = root.standardizedFileURL
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { fail("socket: \(errno)") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else { fail("bind/listen: \(errno)") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        socketFD = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    public func start() {
        let thread = Thread { [self] in
            while true {
                let connection = accept(socketFD, nil, nil)
                if connection < 0 { continue }
                Thread { self.serve(connection) }.start()
            }
        }
        thread.start()
    }

    private static let types: [String: String] = [
        "html": "text/html", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css",
        "json": "application/json", "wasm": "application/wasm", "png": "image/png", "jpg": "image/jpeg",
        "svg": "image/svg+xml", "ttf": "font/ttf", "otf": "font/otf", "woff2": "font/woff2",
        "gz": "application/gzip", "bin": "application/octet-stream", "webmanifest": "application/manifest+json",
    ]

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        var request = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !request.contains(13) || !String(decoding: request, as: UTF8.self).contains("\r\n\r\n") {
            let count = read(connection, &buffer, buffer.count)
            if count <= 0 { return }
            request += buffer[0..<count]
            if request.count > 65536 { return }
        }
        let line = String(decoding: request, as: UTF8.self).split(separator: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else { return respond(connection, 405, "text/plain", Data()) }
        var path = String(parts[1].split(separator: "?", maxSplits: 1).first ?? "/")
        path = path.removingPercentEncoding ?? path
        if path.hasSuffix("/") { path += "index.html" }
        let file = root.appendingPathComponent(String(path.drop(while: { $0 == "/" }))).standardizedFileURL
        guard file.path.hasPrefix(root.path), let data = try? Data(contentsOf: file) else {
            return respond(connection, 404, "text/plain", Data("not found".utf8))
        }
        respond(connection, 200, Self.types[file.pathExtension.lowercased()] ?? "application/octet-stream",
                parts[0] == "HEAD" ? Data() : data, length: data.count)
    }

    private func respond(_ connection: Int32, _ status: Int, _ type: String, _ body: Data, length: Int? = nil) {
        let reason = [200: "OK", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "Status"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(length ?? body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        writeAll(connection, Data(head.utf8))
        writeAll(connection, body)
    }
}

public func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        var offset = 0
        while offset < raw.count {
            let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if written <= 0 { return }
            offset += written
        }
    }
}

// MARK: Chrome, over the DevTools protocol on a pipe

/// Chrome started with --remote-debugging-pipe: it reads commands on its fd 3
/// and writes answers and events on its fd 4, each a JSON object ended by a
/// NUL byte.
public final class Chrome: @unchecked Sendable {
    private var pid: pid_t = 0
    private let toChrome: Int32
    private let fromChrome: Int32
    private let lock = NSCondition()
    private var answers: [Int: [String: Any]] = [:]
    private var nextID = 0
    public private(set) var events: [[String: Any]] = []
    private var closed = false

    public let logPath: String

    public init(path: String, profile: String, width: Int, height: Int, flags: [String]) {
        logPath = profile + ".log"
        var commands: [Int32] = [0, 0]
        var replies: [Int32] = [0, 0]
        guard pipe(&commands) == 0, pipe(&replies) == 0 else { fail("pipe: \(errno)") }
        let arguments = [path, "--headless=new", "--remote-debugging-pipe", "--user-data-dir=\(profile)",
                         "--no-first-run", "--no-default-browser-check", "--hide-scrollbars", "--mute-audio",
                         "--use-mock-keychain", "--password-store=basic", "--force-color-profile=srgb",
                         "--window-size=\(width),\(height)"]
            // As root in a container Chrome's sandbox can't start.
            + (getuid() == 0 ? ["--no-sandbox"] : []) + flags + ["about:blank"]
        #if canImport(Glibc)
        var actions = posix_spawn_file_actions_t()
        #else
        var actions: posix_spawn_file_actions_t? = nil
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, commands[0], 3)
        posix_spawn_file_actions_adddup2(&actions, replies[1], 4)
        // Chrome's own output, kept beside the profile: its last lines are
        // printed when it fails to start or goes away.
        let devNull = open(logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&actions, devNull, 1)
        posix_spawn_file_actions_adddup2(&actions, devNull, 2)
        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let spawned = posix_spawn(&pid, path, &actions, nil, argv, environ)
        posix_spawn_file_actions_destroy(&actions)
        guard spawned == 0 else { fail("couldn't start \(path): \(spawned)") }
        close(commands[0])
        close(replies[1])
        close(devNull)
        toChrome = commands[1]
        fromChrome = replies[0]
        Thread { self.readLoop() }.start()
    }

    private func readLoop() {
        var pending = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(fromChrome, &buffer, buffer.count)
            if count <= 0 { break }
            pending += buffer[0..<count]
            while let end = pending.firstIndex(of: 0) {
                let message = Data(pending[..<end])
                pending.removeSubrange(...end)
                guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else { continue }
                lock.lock()
                if let id = object["id"] as? Int {
                    answers[id] = object
                } else {
                    events.append(object)
                }
                lock.broadcast()
                lock.unlock()
            }
        }
        lock.lock()
        closed = true
        lock.broadcast()
        lock.unlock()
    }

    /// A command, and its result; nil when it timed out or Chrome went away.
    @discardableResult
    public func send(_ method: String, _ params: [String: Any] = [:], session: String? = nil, timeout: Double = 30) -> [String: Any]? {
        lock.lock()
        nextID += 1
        let id = nextID
        lock.unlock()
        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let session { message["sessionId"] = session }
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        data.append(0)
        writeAll(toChrome, data)
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        defer { lock.unlock() }
        while answers[id] == nil, !closed {
            if !lock.wait(until: deadline) { return nil }
        }
        guard let answer = answers.removeValue(forKey: id) else { return nil }
        if let error = answer["error"] as? [String: Any] {
            log("\(method): \(error["message"] ?? error)")
            return nil
        }
        return answer["result"] as? [String: Any] ?? [:]
    }

    /// The events received so far, taken.
    public func takeEvents() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        let taken = events
        events = []
        return taken
    }

    public func stop() {
        close(toChrome)
        if pid > 0 {
            kill(pid, SIGTERM)
            var status: Int32 = 0
            for _ in 0..<50 {
                if waitpid(pid, &status, WNOHANG) == pid { return }
                usleep(100_000)
            }
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
    }
}
