// Foundation's networking and app files on Android, checked from the app's
// side. URLSession against the probe's server (network_check.py, reached
// through `adb reverse` at localhost:18080): GET with header fields, POST
// with a body, a 404, redirects (302; 303 after a POST; 307 keeping a POST; a
// loop), a timeout, gzip both ways, a large body, a refused port, a name that
// doesn't resolve, async data(for:) and a completion-handler dataTask,
// upload and download; WebSockets: text and binary echo, a subprotocol and a
// header field on the handshake, a fragmented message with a ping inside it,
// a large message, the server's close and the app's, a refused port. And
// FileManager where an iOS app has its directories, what one launch left read
// back by the next (a count in Documents, a file in Application Support, an
// @AppStorage value), and that DispatchQueue.main runs a block where there is
// Dispatch (the compiled delivery). Each check is a line, "ok …" or "FAIL …", shown,
// logged (logcat's IsomerBridge, "[net]", in the compiled delivery) and at
// the end posted to the server, where network_check.py reads them; it
// launches the compiled app twice.
//
// The same source is the wasm delivery's reactor
// (//android/network_probe_wasm_android_application, under WasmView), which
// checks the networking only: Android's WasmView gives a reactor /tmp (a
// folder of the temporary directory) but no home yet.

import Foundation
import Isomer
import SwiftUI
#if canImport(Dispatch)
import Dispatch
#endif

/// Where the probe's server is, on the device (`adb reverse tcp:18080 tcp:18080`).
let server = "http://localhost:18080"
let socketServer = "ws://localhost:18080"

@main
struct NetworkProbeApp: App {
    var body: some Scene {
        WindowGroup { ProbeRoot() }
    }
}

struct ProbeRoot: View {
    @State private var lines: [String] = []
    @AppStorage("launches") private var storedLaunches = 0

    var body: some View {
        NavigationStack {
            List {
                ForEach(lines, id: \.self) { Text($0) }
            }
            .navigationTitle("Network")
        }
        .task {
            let probe = Probe()
            let launch = await probe.run(storedLaunches: storedLaunches)
            #if !os(WASI)
            storedLaunches = launch
            probe.check("app storage written", UserDefaults.standard.integer(forKey: "launches"), launch)
            #endif
            await probe.finish(launch: launch)
            lines = probe.lines
        }
    }
}

final class Probe: @unchecked Sendable {
    var lines: [String] = []
    let files = FileManager.default

    func record(_ line: String) {
        lines.append(line)
        Bridge.log("[net] \(line)")
    }

    func check<T: Equatable>(_ name: String, _ found: T, _ expected: T) {
        record(found == expected ? "ok \(name)" : "FAIL \(name): \(found), expected \(expected)")
    }

    /// A check whose work may throw; a throw is its failure.
    func check(_ name: String, expected: String, _ work: () async throws -> String) async {
        do {
            check(name, try await work(), expected)
        } catch {
            record("FAIL \(name): \(error)")
        }
    }

    /// The URLError a request fails with, as its code's name.
    func failure(_ work: () async throws -> Void) async -> String {
        do {
            try await work()
            return "no error"
        } catch let error as URLError {
            switch error.code {
            case .timedOut: return "timedOut"
            case .cannotFindHost: return "cannotFindHost"
            case .cannotConnectToHost: return "cannotConnectToHost"
            case .notConnectedToInternet: return "notConnectedToInternet"
            case .networkConnectionLost: return "networkConnectionLost"
            case .badServerResponse: return "badServerResponse"
            case .unknown: return "unknown"
            default: return "URLError \(error.code.rawValue)"
            }
        } catch {
            return "\(error)"
        }
    }

    /// The summary line, and the report to the server.
    func finish(launch: Int) async {
        let failed = lines.filter { $0.hasPrefix("FAIL") }.count
        record("done launch \(launch): \(lines.filter { $0.hasPrefix("ok") }.count) ok, \(failed) failed")
        var report = request("/report", method: "POST", body: lines.joined(separator: "\n"))
        report.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        _ = try? await URLSession.shared.data(for: report)
    }

    func run(storedLaunches: Int) async -> Int {
        let launch = directories()
        #if !os(WASI)
        check("app storage kept", storedLaunches, launch - 1)
        #endif
        #if canImport(Dispatch)
        await check("the main queue runs a block", expected: "ran") { await self.mainQueue() }
        #endif
        await http()
        await webSockets()
        return launch
    }

    #if canImport(Dispatch)
    /// What a library's `DispatchQueue.main.async` comes to: the host's
    /// Looper drains libdispatch's main queue (NativeBridge), or the block
    /// never runs and this says so after three seconds.
    @MainActor
    func mainQueue() async -> String {
        @MainActor final class Once {
            var done: CheckedContinuation<String, Never>?
            init(_ done: CheckedContinuation<String, Never>) { self.done = done }
            func resume(_ answer: String) {
                done?.resume(returning: answer)
                done = nil
            }
        }
        return await withCheckedContinuation { done in
            let once = Once(done)
            DispatchQueue.main.async { MainActor.assumeIsolated { once.resume("ran") } }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                once.resume("not run in 3 s")
            }
        }
    }
    #endif

    // MARK: Files

    func read(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

    func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }

    /// The directories and what the last launch left in them; returns this launch's number.
    func directories() -> Int {
        #if os(WASI)
        record("the app's directories not checked: Android's WasmView maps no home")
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "probe-scratch.txt")
        check("temporary written", (try? { try write("scratch", to: scratch); return try read(scratch) }()) ?? "unwritable", "scratch")
        return 1
        #else
        let environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        check("home is the files directory", home.hasSuffix("/dev.isomer.networkprobe/files"), true)
        check("HOME", environment["HOME"] ?? "none", home)
        check("documents", URL.documentsDirectory.path, home + "/Documents")
        check("application support", URL.applicationSupportDirectory.path, home + "/Library/Application Support")
        check("caches", URL.cachesDirectory.path, environment["XDG_CACHE_HOME"] ?? "none")
        check("caches in the cache directory", URL.cachesDirectory.path.hasSuffix("/dev.isomer.networkprobe/cache/Caches"), true)
        check("temporary", NSTemporaryDirectory(), (environment["TMPDIR"] ?? "none") + "/")
        check("bundle identifier", Bundle.main.bundleIdentifier ?? "none", "dev.isomer.networkprobe")
        for (name, directory) in [
            ("Documents", URL.documentsDirectory), ("Application Support", URL.applicationSupportDirectory),
            ("Caches", URL.cachesDirectory), ("Library/Caches", URL(fileURLWithPath: home + "/Library/Caches")),
        ] {
            // A directory, links followed (Library/Caches is one here).
            check("\(name) exists", (try? files.contentsOfDirectory(atPath: directory.path)) != nil, true)
        }

        // The launch count, kept in Documents.
        let counter = URL.documentsDirectory.appending(path: "launches.txt")
        let launch = ((try? read(counter)).flatMap { Int($0) } ?? 0) + 1
        record("launch \(launch)")
        do {
            try write("\(launch)", to: counter)
            check("count written", try read(counter), "\(launch)")
        } catch {
            record("FAIL count written: \(error)")
        }

        // Application Support keeps what the last launch wrote; Caches too
        // (nothing cleared it), through the home's link as well.
        for (name, directory) in [("support", URL.applicationSupportDirectory), ("cache", URL.cachesDirectory)] {
            let file = directory.appending(path: "\(name).txt")
            if launch > 1 { check("\(name) kept", (try? read(file)) ?? "missing", "\(launch - 1)") }
            do {
                try write("\(launch)", to: file)
                check("\(name) written", try read(file), "\(launch)")
            } catch {
                record("FAIL \(name) written: \(error)")
            }
        }
        check("cache through the home's link", (try? read(URL(fileURLWithPath: home + "/Library/Caches/cache.txt"))) ?? "missing", "\(launch)")

        // A file in the temporary directory, listed and removed.
        let scratch = files.temporaryDirectory.appending(path: "probe-scratch.txt")
        do {
            try write("scratch", to: scratch)
            check("temporary listed", try files.contentsOfDirectory(atPath: files.temporaryDirectory.path).contains("probe-scratch.txt"), true)
            try files.removeItem(at: scratch)
            check("temporary removed", files.fileExists(atPath: scratch.path), false)
        } catch {
            record("FAIL temporary: \(error)")
        }
        return launch
        #endif
    }

    // MARK: HTTP

    func request(_ path: String, method: String = "GET", body: String? = nil, timeout: TimeInterval = 10) -> URLRequest {
        var request = URLRequest(url: URL(string: server + path)!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body { request.httpBody = Data(body.utf8) }
        return request
    }

    func send(_ request: URLRequest) async throws -> (String, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (String(decoding: data, as: UTF8.self), response as! HTTPURLResponse)
    }

    /// The server's echo of a request, decoded.
    struct Echo: Decodable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: String
    }

    func echo(_ text: String) throws -> Echo { try JSONDecoder().decode(Echo.self, from: Data(text.utf8)) }

    func http() async {
        await check("GET with header fields", expected: "200 GET 1 probe a=1, b=2") {
            var request = self.request("/echo?q=1")
            request.setValue("probe", forHTTPHeaderField: "X-Probe")
            let (text, response) = try await self.send(request)
            let echo = try self.echo(text)
            return "\(response.statusCode) \(echo.method) \(echo.path.hasSuffix("?q=1") ? 1 : 0) \(echo.headers["x-probe"] ?? "none") \(response.value(forHTTPHeaderField: "Set-Cookie") ?? "none")"
        }
        await check("POST with a body", expected: "200 POST hello, server text/plain") {
            var request = self.request("/echo", method: "POST", body: "hello, server")
            request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
            let (text, response) = try await self.send(request)
            let echo = try self.echo(text)
            return "\(response.statusCode) \(echo.method) \(echo.body) \(echo.headers["content-type"] ?? "none")"
        }
        await check("a 404 is an answer", expected: "404 not found") {
            let (text, response) = try await self.send(self.request("/missing"))
            return "\(response.statusCode) \(text)"
        }
        await check("302 followed", expected: "200 GET /echo?redirected=1") {
            let (text, response) = try await self.send(self.request("/redirect"))
            return "\(response.statusCode) \(try self.echo(text).method) \(response.url.map { $0.path + "?" + ($0.query ?? "") } ?? "none")"
        }
        await check("303 after a POST is a GET", expected: "200 GET  /echo") {
            let (text, response) = try await self.send(self.request("/redirect303", method: "POST", body: "dropped"))
            let echo = try self.echo(text)
            return "\(response.statusCode) \(echo.method) \(echo.body) \(response.url?.path ?? "none")"
        }
        await check("307 keeps the POST", expected: "200 POST kept") {
            let (text, response) = try await self.send(self.request("/redirect307", method: "POST", body: "kept"))
            let echo = try self.echo(text)
            return "\(response.statusCode) \(echo.method) \(echo.body)"
        }
        check("a redirect loop fails", await failure { _ = try await self.send(self.request("/loop")) }, "unknown")
        let started = Date()
        check("a timeout", await failure { _ = try await self.send(self.request("/slow", timeout: 1)) }, "timedOut")
        check("the timeout's time", Date().timeIntervalSince(started) < 4, true)
        await check("gzip undone (Android's)", expected: String(repeating: "compressed hello ", count: 100)) {
            try await self.send(self.request("/gzip")).0
        }
        await check("gzip undone (the app's Accept-Encoding)", expected: String(repeating: "compressed hello ", count: 100)) {
            var request = self.request("/gzip")
            request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
            return try await self.send(request).0
        }
        await check("a large body", expected: "1000000 \(999_999 % 251)") {
            let (data, _) = try await URLSession.shared.data(from: URL(string: server + "/large")!)
            return "\(data.count) \(Int(data.last ?? 0))"
        }
        await check("a completion handler", expected: "200 GET") {
            let (status, text): (Int, String) = await withCheckedContinuation { continuation in
                URLSession.shared.dataTask(with: URL(string: server + "/echo")!) { data, response, error in
                    continuation.resume(returning: ((response as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data ?? Data(), as: UTF8.self)))
                }.resume()
            }
            return "\(status) \((try? self.echo(text).method) ?? text)"
        }
        await check("upload", expected: "POST uploaded") {
            let (data, _) = try await URLSession.shared.upload(for: self.request("/echo", method: "POST"), from: Data("uploaded".utf8))
            let echo = try self.echo(String(decoding: data, as: UTF8.self))
            return "\(echo.method) \(echo.body)"
        }
        await check("download", expected: "1000000") {
            let (file, _) = try await URLSession.shared.download(from: URL(string: server + "/large")!)
            return "\(try Data(contentsOf: file).count)"
        }
        check("a refused port", await failure { _ = try await URLSession.shared.data(from: URL(string: "http://localhost:1/")!) }, "cannotConnectToHost")
        check("a name that doesn't resolve", await failure { _ = try await URLSession.shared.data(from: URL(string: "http://no-such-host.invalid/")!) }, "cannotFindHost")
    }

    // MARK: WebSockets

    func text(_ message: URLSessionWebSocketTask.Message) -> String {
        switch message {
        case .string(let text): return text
        case .data(let data): return "data \(data.count)"
        }
    }

    func webSockets() async {
        let task = URLSession.shared.webSocketTask(with: URL(string: socketServer + "/ws")!, protocols: ["probe.v1", "probe.v0"])
        task.resume()
        await check("text echo", expected: "hello") {
            try await task.send(.string("hello"))
            return self.text(try await task.receive())
        }
        check("subprotocol", (task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") ?? "none", "probe.v1")
        await check("binary echo", expected: "0,1,2,255") {
            try await task.send(.data(Data([0, 1, 2, 255])))
            guard case .data(let data) = try await task.receive() else { return "not data" }
            return data.map { "\($0)" }.joined(separator: ",")
        }
        await check("in order", expected: "one two three") {
            for word in ["one", "two", "three"] { try await task.send(.string(word)) }
            var words: [String] = []
            for _ in 0..<3 { words.append(self.text(try await task.receive())) }
            return words.joined(separator: " ")
        }
        await check("fragmented, a ping inside", expected: "fragmented pong inside") {
            try await task.send(.string("fragments"))
            return "\(self.text(try await task.receive())) \(self.text(try await task.receive()))"
        }
        await check("a large message", expected: "data 200000") {
            try await task.send(.string("large"))
            return self.text(try await task.receive())
        }
        await check("the server's close", expected: "closed goingAway bye") {
            try await task.send(.string("close"))
            do {
                let message = try await task.receive()
                return "received \(self.text(message))"
            } catch {
                return "closed \(task.closeCode == .goingAway ? "goingAway" : "\(task.closeCode.rawValue)") \(String(decoding: task.closeReason ?? Data(), as: UTF8.self))"
            }
        }
        await check("the server's close answered", expected: "1001") { try await self.lastClose("echo") }

        // A header field on the handshake; the app's close with a receive waiting.
        var request = URLRequest(url: URL(string: socketServer + "/ws")!)
        request.setValue("ws-probe", forHTTPHeaderField: "X-Probe")
        let second = URLSession.shared.webSocketTask(with: request)
        second.resume()
        await check("a header field on the handshake", expected: "header ws-probe") { self.text(try await second.receive()) }
        let waiting = Task { () -> String in
            do {
                return "received \(self.text(try await second.receive()))"
            } catch {
                return "ended"
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        let closed = Date()
        second.cancel(with: .normalClosure, reason: Data("done".utf8))
        check("the app's close ends a waiting receive", await waiting.value, "ended")
        check("at once", Date().timeIntervalSince(closed) < 2, true)
        check("the app's close code", second.closeCode, .normalClosure)
        await check("the app's close reached the server", expected: "1000 done") { try await self.lastClose("client") }

        let refused = URLSession.shared.webSocketTask(with: URL(string: "ws://localhost:1/")!)
        refused.resume()
        check("a refused WebSocket", await failure { _ = try await refused.receive() }, "cannotConnectToHost")
    }

    /// What the server last saw of a close (`kind` "echo": the app's answer
    /// to the server's; "client": the app's own), waiting a little for it.
    func lastClose(_ kind: String) async throws -> String {
        var seen = ""
        for _ in 0..<20 {
            seen = try await send(request("/last-close?kind=\(kind)")).0
            if seen != "none" { return seen }
            try await Task.sleep(for: .milliseconds(100))
        }
        return seen
    }
}
