// browser_check: a web site's pages loaded in headless Chrome, each waited for
// and pictured, for tests that run where the site was built (a Linux
// container in CI, a Mac by hand). It serves the site on a loopback port of
// its own, starts Chrome with a profile of its own and drives it over the
// DevTools protocol on a pipe (--remote-debugging-pipe: no port, nothing
// listening but the site), and stops both however it ends.
//
//   browser_check --site <dir> [--chrome <path>] [--width 1280] [--height 800]
//                 [--until "<js>"] [--timeout 60] [--settle 2]
//                 [--flag=<chrome flag>]… [--allow-errors] [--hold]
//                 --page "<path and query>=<out.png>" [--page …]
//
// Each page is loaded in turn and waited for until `--until` (a JavaScript
// expression) is true, then `--settle` seconds more, then pictured (PNG). A
// page that never gets there, or that throws, fails the run (exit 1), as
// does an error on the console unless `--allow-errors`. The console and the
// exceptions are printed either way. CHROME in the environment names Chrome
// when `--chrome` doesn't. `--hold` keeps the last page open after its
// picture, its console still printed, until the process is told to stop
// (SIGTERM or SIGINT): a headful app a test drives, launched this way. While
// it holds, `--requests <dir>` takes a picture for each `<n>.request` file
// that appears there (the file holds the picture's path; the request is
// removed once the picture is written): a test's `picture`.
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

struct Options {
    var site = ""
    var chrome = ProcessInfo.processInfo.environment["CHROME"] ?? ""
    var width = 1280
    var height = 800
    var until = "document.readyState === 'complete'"
    var timeout = 60.0
    var settle = 2.0
    var flags: [String] = []
    var allowErrors = false
    var hold = false
    var requests = ""
    var pages: [(path: String, out: String)] = []

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var rest = arguments[...]
        func value(_ name: String) -> String {
            guard let next = rest.popFirst() else { fail("\(name) needs a value") }
            return next
        }
        while let argument = rest.popFirst() {
            if argument.hasPrefix("--flag=") {
                options.flags.append(String(argument.dropFirst("--flag=".count)))
                continue
            }
            switch argument {
            case "--site": options.site = value(argument)
            case "--chrome": options.chrome = value(argument)
            case "--width": options.width = Int(value(argument)) ?? options.width
            case "--height": options.height = Int(value(argument)) ?? options.height
            case "--until": options.until = value(argument)
            case "--timeout": options.timeout = Double(value(argument)) ?? options.timeout
            case "--settle": options.settle = Double(value(argument)) ?? options.settle
            case "--allow-errors": options.allowErrors = true
            case "--hold": options.hold = true
            case "--requests": options.requests = value(argument)
            case "--page":
                let page = value(argument)
                guard let equals = page.lastIndex(of: "=") else { fail("--page wants <path>=<out.png>: \(page)") }
                options.pages.append((String(page[..<equals]), String(page[page.index(after: equals)...])))
            default: fail("unknown argument \(argument)")
            }
        }
        if options.site.isEmpty || options.pages.isEmpty { fail("usage: browser_check --site <dir> --page <path>=<out.png>…") }
        if options.chrome.isEmpty { fail("no Chrome: --chrome <path> or CHROME") }
        return options
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("browser_check: \(message)\n".utf8))
    exit(2)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("browser_check: \(message)\n".utf8))
}

// MARK: The site, served on a loopback port

/// A static file server on 127.0.0.1, a thread a connection, one request a
/// connection (Connection: close), nothing cached.
final class SiteServer: @unchecked Sendable {
    let root: URL
    let port: UInt16
    private let socketFD: Int32

    init(root: URL) {
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

    func start() {
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

func writeAll(_ fd: Int32, _ data: Data) {
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
final class Chrome: @unchecked Sendable {
    private var pid: pid_t = 0
    private let toChrome: Int32
    private let fromChrome: Int32
    private let lock = NSCondition()
    private var answers: [Int: [String: Any]] = [:]
    private var nextID = 0
    private(set) var events: [[String: Any]] = []
    private var closed = false

    let logPath: String

    init(path: String, profile: String, width: Int, height: Int, flags: [String]) {
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
    func send(_ method: String, _ params: [String: Any] = [:], session: String? = nil, timeout: Double = 30) -> [String: Any]? {
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
    func takeEvents() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        let taken = events
        events = []
        return taken
    }

    func stop() {
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

// MARK: The run

// A write to a Chrome that went away fails rather than ends the run.
signal(SIGPIPE, SIG_IGN)

/// --hold's end: set by SIGTERM or SIGINT.
enum Held {
    nonisolated(unsafe) static var stopping: sig_atomic_t = 0
}
signal(SIGTERM) { _ in Held.stopping = 1 }
signal(SIGINT) { _ in Held.stopping = 1 }
let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
let server = SiteServer(root: URL(fileURLWithPath: options.site))
server.start()
let profile = FileManager.default.temporaryDirectory.appendingPathComponent("browser-check-\(getpid())").path
try? FileManager.default.createDirectory(atPath: profile, withIntermediateDirectories: true)
let chrome = Chrome(path: options.chrome, profile: profile, width: options.width, height: options.height, flags: options.flags)
var failures: [String] = []

func finish() -> Never {
    chrome.stop()
    try? FileManager.default.removeItem(atPath: profile)
    if failures.isEmpty {
        try? FileManager.default.removeItem(atPath: chrome.logPath)
        print("browser_check: \(options.pages.count) page(s) loaded and pictured")
        exit(0)
    }
    for failure in failures { log("FAILED: \(failure)") }
    if let output = try? String(contentsOfFile: chrome.logPath, encoding: .utf8) {
        log("Chrome's last output:\n" + output.split(separator: "\n").suffix(30).joined(separator: "\n"))
    }
    try? FileManager.default.removeItem(atPath: chrome.logPath)
    exit(1)
}

guard let target = chrome.send("Target.createTarget", ["url": "about:blank"], timeout: 60)?["targetId"] as? String,
      let session = chrome.send("Target.attachToTarget", ["targetId": target, "flatten": true])?["sessionId"] as? String
else {
    failures.append("Chrome never answered (\(options.chrome))")
    finish()
}
chrome.send("Page.enable", session: session)
chrome.send("Runtime.enable", session: session)
chrome.send("Emulation.setDeviceMetricsOverride",
            ["width": options.width, "height": options.height, "deviceScaleFactor": 1, "mobile": false], session: session)
chrome.send("Emulation.setEmulatedMedia", ["features": [["name": "prefers-color-scheme", "value": "light"]]], session: session)

/// The page's console and exceptions since the last call, printed; the
/// errors among them returned.
func drainConsole(_ name: String) -> [String] {
    var errors: [String] = []
    for event in chrome.takeEvents() {
        guard let method = event["method"] as? String, let params = event["params"] as? [String: Any] else { continue }
        if method == "Runtime.consoleAPICalled" {
            let type = params["type"] as? String ?? "log"
            let text = (params["args"] as? [[String: Any]] ?? []).map { "\($0["value"] ?? $0["description"] ?? "")" }.joined(separator: " ")
            print("[\(name)] [\(type)] \(text)")
            if type == "error" { errors.append("console error: \(text)") }
        } else if method == "Runtime.exceptionThrown" {
            let details = params["exceptionDetails"] as? [String: Any] ?? [:]
            let exception = (details["exception"] as? [String: Any])?["description"] ?? details["text"] ?? "?"
            print("[\(name)] [exception] \(exception)")
            errors.append("exception: \(exception)")
        }
    }
    return errors
}

for page in options.pages {
    let url = "http://127.0.0.1:\(server.port)/" + page.path.drop(while: { $0 == "/" })
    let name = URL(fileURLWithPath: page.out).deletingPathExtension().lastPathComponent
    log("\(name): \(url)")
    _ = chrome.send("Page.navigate", ["url": url], session: session)
    let deadline = Date().addingTimeInterval(options.timeout)
    var ready = false
    while Date() < deadline {
        let result = chrome.send("Runtime.evaluate", ["expression": "Boolean(\(options.until))", "returnByValue": true], session: session)
        if ((result?["result"] as? [String: Any])?["value"] as? Bool) == true {
            ready = true
            break
        }
        usleep(250_000)
    }
    if !ready { failures.append("\(name): not ready in \(Int(options.timeout)) s (\(options.until))") }
    usleep(useconds_t(options.settle * 1_000_000))
    if let data = (chrome.send("Page.captureScreenshot", ["format": "png"], session: session)?["data"] as? String)
        .flatMap({ Data(base64Encoded: $0) }) {
        let out = URL(fileURLWithPath: page.out)
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: out) } catch { failures.append("\(name): \(error)") }
    } else {
        failures.append("\(name): no picture")
    }
    let errors = drainConsole(name)
    let counted = errors.filter { options.allowErrors ? $0.hasPrefix("exception") : true }
    failures += counted.map { "\(name): \($0)" }
}
if options.hold, let last = options.pages.last {
    let name = URL(fileURLWithPath: last.out).deletingPathExtension().lastPathComponent
    log("\(name): held open until stopped")
    while Held.stopping == 0 {
        usleep(200_000)
        // A test's pictures, as asked.
        if !options.requests.isEmpty,
           let names = try? FileManager.default.contentsOfDirectory(atPath: options.requests) {
            for request in names.sorted() where request.hasSuffix(".request") {
                let path = options.requests + "/" + request
                guard let target = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                if let data = (chrome.send("Page.captureScreenshot", ["format": "png"], session: session)?["data"] as? String)
                    .flatMap({ Data(base64Encoded: $0) }) {
                    try? data.write(to: URL(fileURLWithPath: target.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        let errors = drainConsole(name)
        failures += errors.filter { options.allowErrors ? $0.hasPrefix("exception") : true }.map { "\(name): \($0)" }
    }
}
finish()
