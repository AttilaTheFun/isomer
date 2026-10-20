import Foundation
import IsomerFoundation
import Synchronization

// URLSession over transports installed as a host installs them: an HTTP
// server faked from what it is sent, and a WebSocket server that echoes.
// What is read without a transport (file: and data: URLs) and what fails
// without one.

/// Answers by path: /echo sends back the body with the method and a
/// repeated field, /missing is a 404, /slow times out, /offline has no
/// network, /redirect answers from elsewhere, /hang answers only by being
/// cancelled. What it was sent is kept.
final class FakeHTTP: HTTPTransport {
    let sent = Mutex<[HTTPTransportRequest]>([])

    func send(_ request: HTTPTransportRequest) async throws -> HTTPTransportResponse {
        sent.withLock { $0.append(request) }
        switch request.url.path {
        case "/echo":
            return HTTPTransportResponse(
                statusCode: 200,
                headerFields: [
                    ("Content-Type", "text/plain; charset=UTF-8"), ("X-Method", request.method), ("Set-Cookie", "a=1"),
                    ("set-cookie", "b=2"),
                ],
                body: request.body)
        case "/missing":
            return HTTPTransportResponse(statusCode: 404, headerFields: [], body: Data("nope".utf8))
        case "/slow":
            throw NetworkTransportError(.timedOut, message: "no answer in \(request.timeoutInterval) s")
        case "/offline":
            throw NetworkTransportError(.notConnectedToInternet)
        case "/redirect":
            return HTTPTransportResponse(
                statusCode: 200, headerFields: [], body: Data("moved".utf8), url: URL(string: "https://example.com/final"))
        case "/hang":
            let gate = Gate()
            return try await withTaskCancellationHandler {
                try await gate.wait()
            } onCancel: {
                gate.open(throwing: CancellationError())
            }
        default:
            throw NetworkTransportError(.cannotFindHost)
        }
    }
}

/// A wait that ends when it is opened, whether that comes first or not.
final class Gate: Sendable {
    private let state = Mutex<(waiter: CheckedContinuation<HTTPTransportResponse, any Error>?, error: (any Error)?)>(
        (nil, nil))

    func wait() async throws -> HTTPTransportResponse {
        try await withCheckedThrowingContinuation { continuation in
            let error = state.withLock { state -> (any Error)? in
                if let error = state.error { return error }
                state.waiter = continuation
                return nil
            }
            if let error { continuation.resume(throwing: error) }
        }
    }

    func open(throwing error: any Error) {
        let waiter = state.withLock { state in
            state.error = error
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(throwing: error)
    }
}

/// Opens echo connections; refuses the host "refused".
final class FakeWebSocket: WebSocketTransport {
    let opened = Mutex<[WebSocketTransportRequest]>([])

    func connect(_ request: WebSocketTransportRequest) async throws -> any WebSocketTransportConnection {
        if request.url.host == "refused" { throw NetworkTransportError(.cannotConnectToHost, message: "refused") }
        opened.withLock { $0.append(request) }
        return EchoConnection(subprotocol: request.protocols.last)
    }
}

/// Sends back what it is sent; the text "bye" makes it close with 1000
/// and the reason "done", as a server would.
final class EchoConnection: WebSocketTransportConnection {
    let subprotocol: String?
    private let state = Mutex<(events: [WebSocketTransportEvent], waiter: CheckedContinuation<WebSocketTransportEvent, any Error>?, closed: WebSocketTransportEvent?)>(([], nil, nil))

    init(subprotocol: String?) {
        self.subprotocol = subprotocol
    }

    func send(text: String) async throws {
        if text == "bye" {
            arrive(.closed(code: 1000, reason: Data("done".utf8)))
        } else {
            arrive(.text(text))
        }
    }

    func send(data: Data) async throws {
        arrive(.data(data))
    }

    func receive() async throws -> WebSocketTransportEvent {
        try await withCheckedThrowingContinuation { continuation in
            let next = state.withLock { state -> WebSocketTransportEvent? in
                if !state.events.isEmpty { return state.events.removeFirst() }
                if let closed = state.closed { return closed }
                state.waiter = continuation
                return nil
            }
            if let next { continuation.resume(returning: next) }
        }
    }

    func close(code: Int, reason: Data) {
        arrive(.closed(code: code, reason: reason))
    }

    private func arrive(_ event: WebSocketTransportEvent) {
        let waiter = state.withLock { state -> CheckedContinuation<WebSocketTransportEvent, any Error>? in
            guard state.closed == nil else { return nil }
            if case .closed = event { state.closed = event }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            if case .closed = event { return nil }
            state.events.append(event)
            return nil
        }
        waiter?.resume(returning: event)
    }
}

/// The code of the URLError (or the POSIX error) `body` threw, or what it
/// returned instead.
func failure<T>(_ body: () async throws -> T) async -> String {
    do {
        return "returned \(try await body())"
    } catch let error as URLError {
        return "URLError \(error.code.rawValue)"
    } catch let error as POSIXError {
        return "POSIXError \(error.code.rawValue)"
    } catch {
        return "\(error)"
    }
}

final class Words: Sendable {
    let list = Mutex<[String]>([])
}

func text(_ data: Data?) -> String {
    data.map { String(decoding: $0, as: UTF8.self) } ?? "nil"
}

extension FoundationCheck {
    static func checkNetwork() async {
        let echo = URL(string: "https://example.com/echo")!

        // Requests.
        var request = URLRequest(url: echo)
        check("request method", request.httpMethod ?? "", "GET")
        check("request headers", "\(request.allHTTPHeaderFields == nil)", "true")
        request.setValue("1", forHTTPHeaderField: "X-A")
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.addValue("text/html", forHTTPHeaderField: "accept")
        request.setValue(nil, forHTTPHeaderField: "x-a")
        request.setValue("2", forHTTPHeaderField: "X-B")
        check("request fields", request.value(forHTTPHeaderField: "ACCEPT") ?? "", "text/plain,text/html")
        check("request field gone", "\(request.value(forHTTPHeaderField: "X-A") == nil) \(request.allHTTPHeaderFields?.count ?? 0)", "true 2")
        request.httpMethod = "POST"
        request.httpBody = Data("ping".utf8)
        check("request body", "\(text(request.httpBody)) \(request.httpBodyStream == nil)", "ping true")
        request.httpBodyStream = InputStream(data: Data("streamed".utf8))
        check("request stream", "\(request.httpBody == nil) \(request.httpBodyStream != nil)", "true true")
        check("request description", request.description, "https://example.com/echo")
        let same = URLRequest(url: echo, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        check("request equality", "\(same == URLRequest(url: echo, cachePolicy: .reloadIgnoringCacheData, timeoutInterval: 5)) \(same == URLRequest(url: echo))", "true false")
        let response = HTTPURLResponse(
            url: echo, statusCode: 201, httpVersion: nil,
            headerFields: ["content-type": "application/json; charset=utf-8", "Content-Length": "12"])!
        check("response", "\(response.statusCode) \(response.mimeType ?? "") \(response.textEncodingName ?? "") \(response.expectedContentLength) \(response.value(forHTTPHeaderField: "Content-Type") ?? "") \(response.suggestedFilename ?? "")", "201 application/json utf-8 12 application/json; charset=utf-8 echo")
        check("status text", HTTPURLResponse.localizedString(forStatusCode: 404), "not found")

        // Errors.
        let timedOut = URLError(.timedOut, userInfo: ["NSErrorFailingURLKey": echo])
        check("url error", "\(timedOut.errorCode) \(URLError.errorDomain) \(timedOut.failingURL?.absoluteString ?? "")", "-1001 NSURLErrorDomain https://example.com/echo")
        check("url error description", timedOut.localizedDescription, "The request timed out.")
        check("url error match", "\(URLError.Code.timedOut ~= timedOut) \(URLError.cancelled ~= timedOut)", "true false")
        check("error description", CocoaError(.fileNoSuchFile).localizedDescription, "The operation couldn’t be completed. (NSCocoaErrorDomain error 4.)")

        // Without a transport: offline; file: and data: URLs need none.
        check("no transport", await failure { try await URLSession.shared.data(from: echo) }, "URLError -1009")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("isomer-session.txt")
        try? Data("from a file".utf8).write(to: file)
        do {
            let (data, response) = try await URLSession.shared.data(from: file)
            check("file url", "\(text(data)) \(response.mimeType ?? "") \(response.expectedContentLength) \(response is HTTPURLResponse)", "from a file text/plain 11 false")
        } catch {
            check("file url", "\(error)", "from a file")
        }
        check("file missing", await failure { try await URLSession.shared.data(from: file.appendingPathExtension("gone")) }, "URLError -1100")
        do {
            let (data, response) = try await URLSession.shared.data(from: URL(string: "data:text/plain;charset=utf-8;base64,aGVsbG8=")!)
            check("data url", "\(text(data)) \(response.mimeType ?? "") \(response.textEncodingName ?? "")", "hello text/plain utf-8")
        } catch {
            check("data url", "\(error)", "hello")
        }
        check("unsupported scheme", await failure { try await URLSession.shared.data(from: URL(string: "ftp://example.com/a")!) }, "URLError -1002")

        // Over the HTTP transport.
        let http = FakeHTTP()
        IsomerNetwork.http = http
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": "check", "X-B": "ignored"]
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        configuration.timeoutIntervalForRequest = 99
        check("configuration copied", "\(session.configuration.timeoutIntervalForRequest)", "15.0")
        request.httpBody = Data("ping".utf8)
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            check("http data", "\(text(data)) \(http?.statusCode ?? 0) \(http?.value(forHTTPHeaderField: "x-method") ?? "") \(http?.mimeType ?? "") \(http?.textEncodingName ?? "")", "ping 200 POST text/plain utf-8")
            check("http repeated field", http?.value(forHTTPHeaderField: "Set-Cookie") ?? "", "a=1, b=2")
        } catch {
            check("http data", "\(error)", "ping")
        }
        let sent = http.sent.withLock { $0.last }
        check("http sent", "\(sent?.method ?? "") \(sent?.headerFields.map { "\($0.name)=\($0.value)" }.joined(separator: " ") ?? "") \(sent?.timeoutInterval ?? 0)", "POST Accept=text/plain,text/html X-B=2 User-Agent=check Content-Type=application/x-www-form-urlencoded 15.0")
        let missing = URL(string: "https://example.com/missing")!
        do {
            let (data, response) = try await session.data(from: missing)
            check("http 404", "\(text(data)) \((response as? HTTPURLResponse)?.statusCode ?? 0)", "nope 404")
        } catch {
            check("http 404", "\(error)", "nope 404")
        }
        check("http timed out", await failure { try await session.data(from: URL(string: "https://example.com/slow")!) }, "URLError -1001")
        do {
            _ = try await session.data(from: URL(string: "https://example.com/slow")!)
        } catch let error as URLError {
            check("http error info", "\(error.failingURL?.path ?? "") \(error.userInfo["NSDebugDescription"] as? String ?? "")", "/slow no answer in 15.0 s")
        } catch {
            check("http error info", "\(error)", "URLError")
        }
        check("http offline", await failure { try await session.data(from: URL(string: "https://example.com/offline")!) }, "URLError -1009")
        do {
            let (_, response) = try await session.data(from: URL(string: "https://example.com/redirect")!)
            check("http redirect", response.url?.absoluteString ?? "", "https://example.com/final")
        } catch {
            check("http redirect", "\(error)", "https://example.com/final")
        }
        do {
            let (data, _) = try await session.upload(for: URLRequest(url: echo), from: Data("up".utf8))
            check("http upload", text(data), "up")
        } catch {
            check("http upload", "\(error)", "up")
        }

        // Completion handlers.
        let handled: String = await withCheckedContinuation { continuation in
            let task = session.dataTask(with: echo) { data, response, error in
                continuation.resume(returning: "\(text(data)).\((response as? HTTPURLResponse)?.statusCode ?? 0).\(error == nil)")
            }
            check("task suspended", "\(task.state == .suspended) \(task.taskIdentifier > 0)", "true true")
            task.resume()
        }
        check("data task", handled, ".200.true")
        let downloaded: String = await withCheckedContinuation { continuation in
            var post = URLRequest(url: echo)
            post.httpMethod = "PUT"
            post.httpBody = Data("to a file".utf8)
            session.downloadTask(with: post) { location, _, error in
                let contents = location.flatMap { try? Data(contentsOf: $0) }
                continuation.resume(returning: "\(text(contents)) \(error == nil) \(location?.lastPathComponent.hasPrefix("CFNetworkDownload_") ?? false)")
            }.resume()
        }
        check("download task", downloaded, "to a file true true")
        do {
            let (location, _) = try await session.download(from: echo)
            check("download kept", "\(FileManager.default.fileExists(atPath: location.path))", "true")
            try? FileManager.default.removeItem(at: location)
        } catch {
            check("download kept", "\(error)", "true")
        }
        let uploaded: String = await withCheckedContinuation { continuation in
            session.uploadTask(with: URLRequest(url: echo), from: Data("handled".utf8)) { data, _, _ in
                continuation.resume(returning: text(data))
            }.resume()
        }
        check("upload task", uploaded, "handled")

        // Cancelling.
        let hang = URL(string: "https://example.com/hang")!
        let cancelledEarly: String = await withCheckedContinuation { continuation in
            let task = session.dataTask(with: hang) { _, _, error in
                continuation.resume(returning: "\((error as? URLError)?.code.rawValue ?? 0)")
            }
            task.cancel()
            check("cancel state", "\(task.state == .canceling)", "true")
        }
        check("cancel before resume", cancelledEarly, "-999")
        let waiting = Task { await failure { try await session.data(from: hang) } }
        while http.sent.withLock({ $0.last?.url != hang }) { await Task.yield() }
        waiting.cancel()
        check("cancel async", await waiting.value, "URLError -999")
        let other = URLSession(configuration: .ephemeral)
        let invalidated: String = await withCheckedContinuation { continuation in
            other.dataTask(with: hang) { _, _, error in
                continuation.resume(returning: "\((error as? URLError)?.code.rawValue ?? 0)")
            }.resume()
            other.invalidateAndCancel()
        }
        check("invalidate and cancel", invalidated, "-999")
        check("session tasks", "\(await session.allTasks.count)", "0")

        // WebSocket tasks.
        let socket = session.webSocketTask(with: URL(string: "wss://example.com/socket")!, protocols: ["one", "two"])
        check("socket closed code", "\(socket.closeCode == .invalid)", "true")
        check("socket no transport", await failure { () async throws -> String in
            let task = session.webSocketTask(with: URL(string: "wss://example.com/socket")!)
            task.resume()
            return "\(try await task.receive())"
        }, "URLError -1009")
        let sockets = FakeWebSocket()
        IsomerNetwork.webSocket = sockets
        socket.resume()
        let pong: String = await withCheckedContinuation { continuation in
            socket.sendPing { error in continuation.resume(returning: "\(error == nil)") }
        }
        check("socket ping", pong, "true")
        let opened = sockets.opened.withLock { $0.last }
        check("socket opened", "\(opened?.url.absoluteString ?? "") \(opened?.protocols ?? []) \(opened?.headerFields.map(\.name) ?? []) \(opened?.timeoutInterval ?? 0)", "wss://example.com/socket [\"one\", \"two\"] [\"User-Agent\", \"X-B\"] 15.0")
        check("socket response", "\((socket.response as? HTTPURLResponse)?.statusCode ?? 0) \((socket.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") ?? "")", "101 two")
        do {
            try await socket.send(.string("hello"))
            try await socket.send(.data(Data([1, 2, 3])))
            var received: [String] = []
            for _ in 0..<2 {
                switch try await socket.receive() {
                case .string(let text): received.append(text)
                case .data(let data): received.append("\(Array(data))")
                }
            }
            check("socket echo", received.joined(separator: " "), "hello [1, 2, 3]")
        } catch {
            check("socket echo", "\(error)", "hello [1, 2, 3]")
        }
        // Handler forms keep their order.
        for word in ["a", "b", "c"] { socket.send(.string(word)) { _ in } }
        let ordered: String = await withCheckedContinuation { continuation in
            let words = Words()
            for _ in 0..<3 {
                socket.receive { result in
                    let all = words.list.withLock { words -> [String]? in
                        if case .success(.string(let text)) = result { words.append(text) } else { words.append("?") }
                        return words.count == 3 ? words : nil
                    }
                    if let all { continuation.resume(returning: all.joined()) }
                }
            }
        }
        check("socket order", ordered, "abc")
        do {
            try await socket.send(.string("bye"))
        } catch {
            check("socket bye", "\(error)", "")
        }
        check("socket closed", await failure { try await socket.receive() }, "POSIXError \(POSIXError.ENOTCONN.rawValue)")
        check("socket close", "\(socket.closeCode == .normalClosure) \(text(socket.closeReason)) \(socket.state == .completed)", "true done true")
        let leaving = session.webSocketTask(with: URLRequest(url: URL(string: "https://example.com/socket")!))
        leaving.resume()
        leaving.cancel(with: .goingAway, reason: Data("later".utf8))
        check("socket cancel", "\(leaving.closeCode == .goingAway) \(text(leaving.closeReason))", "true later")
        check("socket after cancel", await failure { try await leaving.receive() }, "POSIXError \(POSIXError.ENOTCONN.rawValue)")
        let refused = session.webSocketTask(with: URL(string: "ws://refused/")!)
        refused.resume()
        let refusal: String = await withCheckedContinuation { continuation in
            refused.sendPing { error in continuation.resume(returning: "\((error as? URLError)?.code.rawValue ?? 0)") }
        }
        check("socket refused", refusal, "-1004")
    }
}
