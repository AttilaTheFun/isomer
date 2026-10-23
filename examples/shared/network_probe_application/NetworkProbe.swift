// Foundation's networking, checked from the app's side: URLSession's data,
// upload and download calls (async, and a data task with a completion
// handler) and its WebSocket tasks, against tools/testing/network_server.js,
// one line per check ("ok …" or "FAIL …") and a last one, "done: …". The
// same source runs on the web (the page's fetch and WebSocket, network.js)
// and in a WasmView (Apple's URLSession, WasmView's network hosts): the
// app's code is Apple's API either way, only the host's transport differs.
//
// Where the server is: the page's own origin on the web (the page's URL
// arrives through `.onOpenURL`), ISO_NETWORK_SERVER (WasmKit hands a reactor
// the host's ISO_* environment) in a WasmView. Drivers:
// tools/testing/run_network_check.js (headless Chrome), and the iOS
// simulator's run in examples/apple/network_probe_wasm_ios_application.

import Foundation
import SwiftUI

@main
struct NetworkProbeApp: App {
    var body: some Scene {
        WindowGroup { NetworkProbeRoot() }
    }
}

struct NetworkProbeRoot: View {
    @State private var lines: [String] = []
    @State private var started = false

    var body: some View {
        NavigationStack {
            List {
                Section("Checks") {
                    ForEach(Array(lines.enumerated()), id: \.offset) { Text($0.element) }
                }
            }
            .navigationTitle("Network")
        }
        .onOpenURL { start(server: $0) }
        .onAppear {
            if let server = ProcessInfo.processInfo.environment["ISO_NETWORK_SERVER"], let url = URL(string: server) {
                start(server: url)
            }
        }
    }

    /// Runs the checks once, against the origin of `server`.
    private func start(server: URL) {
        guard !started, let scheme = server.scheme, scheme.hasPrefix("http"), let host = server.host else { return }
        started = true
        let base = "\(scheme)://\(host)" + (server.port.map { ":\($0)" } ?? "")
        Task {
            await NetworkChecks(base: base) { lines.append($0) }.run()
        }
    }
}

/// What the server's /echo saw of a request.
struct Echo: Decodable {
    let method: String
    let url: String
    let headers: [String: String]
    let body: String
}

@MainActor
final class NetworkChecks {
    let base: String
    let webSocketBase: String
    let report: @MainActor (String) -> Void
    let session = URLSession.shared
    var failures = 0
    var count = 0

    init(base: String, report: @escaping @MainActor (String) -> Void) {
        self.base = base
        self.webSocketBase = "ws" + base.dropFirst("http".count)
        self.report = report
    }

    func record(_ line: String) {
        count += 1
        if line.hasPrefix("FAIL") { failures += 1 }
        print("[network] \(line)")
        report(line)
    }

    /// `body`'s answer, compared with `expected`.
    func check(_ name: String, _ expected: String, _ body: () async throws -> String) async {
        do {
            let found = try await body()
            record(found == expected ? "ok \(name)" : "FAIL \(name): \(found), expected \(expected)")
        } catch {
            record("FAIL \(name): \(error)")
        }
    }

    /// That `body` fails with `code`.
    func checkFails(_ name: String, _ code: URLError.Code, _ body: () async throws -> Void) async {
        do {
            try await body()
            record("FAIL \(name): answered")
        } catch let error as URLError where error.code == code {
            record("ok \(name)")
        } catch {
            record("FAIL \(name): \(error)")
        }
    }

    func url(_ path: String) -> URL { URL(string: base + path)! }

    func echo(_ data: Data) throws -> Echo { try JSONDecoder().decode(Echo.self, from: data) }

    func status(_ response: URLResponse) -> Int { (response as? HTTPURLResponse)?.statusCode ?? 0 }

    func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    func run() async {
        await checkHTTP()
        await checkWebSockets()
        record("done: \(count - failures) ok, \(failures) failed")
    }

    // MARK: HTTP

    func checkHTTP() async {
        await check("GET with a header field", "200 GET probe value yes") {
            var request = URLRequest(url: url("/echo"))
            request.setValue("probe value", forHTTPHeaderField: "X-Probe")
            let (data, response) = try await session.data(for: request)
            let seen = try echo(data)
            let answered = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-echo") ?? "none"
            return "\(status(response)) \(seen.method) \(seen.headers["x-probe"] ?? "none") \(answered)"
        }
        await check("POST with a body", "POST hello body text/plain") {
            var request = URLRequest(url: url("/echo"))
            request.httpMethod = "POST"
            request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("hello body".utf8)
            let seen = try echo(try await session.data(for: request).0)
            return "\(seen.method) \(seen.body) \(seen.headers["content-type"] ?? "none")"
        }
        await check("upload", "PUT uploaded") {
            var request = URLRequest(url: url("/echo"))
            request.httpMethod = "PUT"
            let seen = try echo(try await session.upload(for: request, from: Data("uploaded".utf8)).0)
            return "\(seen.method) \(seen.body)"
        }
        await check("download", "status 200") {
            let (file, _) = try await session.download(from: url("/status/200"))
            defer { try? FileManager.default.removeItem(at: file) }
            return text(try Data(contentsOf: file))
        }
        await check("a 404 is an answer", "404 status 404") {
            let (data, response) = try await session.data(from: url("/status/404"))
            return "\(status(response)) \(text(data))"
        }
        await check("a redirect is followed", "200 /echo?redirected=1 /echo") {
            let (data, response) = try await session.data(from: url("/redirect"))
            return "\(status(response)) \(try echo(data).url) \(response.url?.path ?? "none")"
        }
        await check("gzip undone", "compressed hello") {
            text(try await session.data(from: url("/gzip")).0)
        }
        await check("a data task's completion handler", "200 status 200") {
            let url = url("/status/200")
            let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { continuation in
                URLSession.shared.dataTask(with: url) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (data ?? Data(), response!))
                    }
                }.resume()
            }
            return "\(status(response)) \(text(data))"
        }
        await checkFails("a slow server times out", .timedOut) {
            var request = URLRequest(url: url("/slow?ms=4000"))
            request.timeoutInterval = 1
            _ = try await session.data(for: request)
        }
        // Four parts 400 ms apart with a second allowed: the timeout is how
        // long the exchange may wait for more, not for all of it.
        await check("a steady answer outlasts its timeout", "part 0;part 1;part 2;part 3;") {
            var request = URLRequest(url: url("/drip?parts=4&gap=400"))
            request.timeoutInterval = 1
            return text(try await session.data(for: request).0)
        }
        await checkFails("a refused connection", .cannotConnectToHost) {
            _ = try await session.data(from: URL(string: "http://127.0.0.1:1/")!)
        }
    }

    // MARK: WebSocket

    func message(_ message: URLSessionWebSocketTask.Message) -> String {
        switch message {
        case .string(let text): return "text \(text)"
        case .data(let data): return "data \(data.map { String($0) }.joined(separator: ","))"
        }
    }

    func lastClose() async throws -> String {
        let (data, _) = try await session.data(from: url("/ws/last-close"))
        return text(data)
    }

    func checkWebSockets() async {
        let echoURL = URL(string: webSocketBase + "/ws/echo")!
        let task = session.webSocketTask(with: echoURL, protocols: ["probe.v1", "other"])
        task.resume()
        await check("text echoed", "text hello") {
            try await task.send(.string("hello"))
            return message(try await task.receive())
        }
        await check("data echoed", "data 1,2,3") {
            try await task.send(.data(Data([1, 2, 3])))
            return message(try await task.receive())
        }
        await check("the subprotocol chosen", "probe.v1") {
            (task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") ?? "none"
        }
        await check("the server's close", "failed goingAway bye") {
            try await task.send(.string("close:1001:bye"))
            let ended = (try? await task.receive()) == nil
            return "\(ended ? "failed" : "received") \(task.closeCode) \(task.closeReason.map(text) ?? "none")"
        }

        // The app closes while a receive waits: the receive ends, and the
        // server hears the app's code and reason.
        let closing = session.webSocketTask(with: echoURL)
        closing.resume()
        await check("the app's close", "failed {\"code\":1000,\"reason\":\"done\"}") {
            try await closing.send(.string("open"))
            _ = try await closing.receive()
            let waiting = Task { try await closing.receive() }
            try await Task.sleep(nanoseconds: 200_000_000)
            closing.cancel(with: .normalClosure, reason: Data("done".utf8))
            let ended: Bool
            switch await waiting.result {
            case .success: ended = false
            case .failure: ended = true
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            return "\(ended ? "failed" : "received") \(try await lastClose())"
        }

        await checkFails("a refused WebSocket", .cannotConnectToHost) {
            let refused = session.webSocketTask(with: URL(string: "ws://127.0.0.1:1/ws/echo")!)
            refused.resume()
            _ = try await refused.receive()
        }
    }
}
