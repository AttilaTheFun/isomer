// Foundation's networking for a reactor a native Swift process runs under
// WasmKit: URLSession as the hosts IsomerNetworkHost declares
// (shared/isomer_network_host), which the guest's runtime installs as its
// Foundation's transports when it starts (HotBridge's `iso_hot_start`).
// Apple's WasmView (`WasmViewModel`) and the Linux and Windows wasm hosts
// inject them under `isomerHTTP` and `isomerWebSocket` beneath their own
// dependencies, so a feature's `URLSession` reaches the network as the
// host's own code does: on Apple platforms the system's stack, its cookies,
// cache, proxies and App Transport Security (an http: URL needs the app's
// Info.plist to allow it); on Linux and Windows the toolchain's
// FoundationNetworking (libcurl).
//
// A failure to get any answer throws a message that starts with the reason
// Foundation turns into the guest's `URLError` ("timedOut: …"), from the
// NSURLError code. The guest's cancelling a task does not reach these hosts
// (the interfaces have no cancel): the exchange runs on, and its answer is
// dropped.

import Foundation
#if os(Linux) || os(Windows)
import FoundationNetworking
#endif
import IsomerNetworkWasmHost
import SwiftFFIWasmHost

/// The network hosts as the reactor's injected dependencies, fresh for
/// each reactor (a reload's connections are its own).
package func isomerNetworkDependencies() -> [String: SwiftFFIDependency] {
    [
        NetworkHostKey.isomerHTTP.rawValue: Dependencies.hTTPHost { URLSessionHTTPHost() },
        NetworkHostKey.isomerWebSocket.rawValue: Dependencies.webSocketHost { URLSessionWebSocketHost() },
    ]
}

/// What a host throws: its description crosses to the guest, which reads
/// the reason from its start.
struct NetworkHostFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) { self.description = description }

    /// The reason URLSession's `error` means, and what it said.
    init(_ error: any Error) {
        let error = error as NSError
        self.init("\(Self.reason(error)): \(error.localizedDescription)")
    }

    private static func reason(_ error: NSError) -> String {
        if error.domain == NSPOSIXErrorDomain {
            // A WebSocket's connection gone under it (ENOTCONN, ECONNRESET…).
            return "networkConnectionLost"
        }
        guard error.domain == NSURLErrorDomain else { return "unknown" }
        switch error.code {
        case NSURLErrorTimedOut:
            return "timedOut"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "cannotFindHost"
        case NSURLErrorCannotConnectToHost:
            return "cannotConnectToHost"
        case NSURLErrorNetworkConnectionLost:
            return "networkConnectionLost"
        case NSURLErrorNotConnectedToInternet, NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive,
            NSURLErrorDataNotAllowed:
            return "notConnectedToInternet"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired,
            // App Transport Security refused a plain connection: the nearest
            // reason the guest has.
            NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "secureConnectionFailed"
        case NSURLErrorCancelled:
            return "cancelled"
        case NSURLErrorBadServerResponse, NSURLErrorCannotParseResponse, NSURLErrorCannotDecodeRawData,
            NSURLErrorCannotDecodeContentData:
            return "badServerResponse"
        default:
            return "unknown"
        }
    }
}

/// Header fields as the hosts read and write them: `[["name", "value"], …]`.
private func headerFields(_ json: String) -> [(name: String, value: String)] {
    guard let pairs = try? JSONDecoder().decode([[String]].self, from: Data(json.utf8)) else { return [] }
    return pairs.compactMap { $0.count == 2 ? (name: $0[0], value: $0[1]) : nil }
}

private func headersJSON(_ fields: [[String]]) -> String {
    (try? String(decoding: JSONEncoder().encode(fields), as: UTF8.self)) ?? "[]"
}

// MARK: - HTTP

/// `HTTPHost` over `URLSession.shared`: the guest's requests are the app's
/// own. Redirects are followed and content codings undone by the system;
/// `timeout` is the request's `timeoutInterval` (how long it may wait for
/// more, as in the guest's Foundation).
final class URLSessionHTTPHost: HTTPHost, @unchecked Sendable {
    func send(method: String, url: String, headers: String, body: [UInt8], timeout: Double) async throws
        -> HTTPHostResponse
    {
        guard let target = URL(string: url) else { throw NetworkHostFailure("unknown: not a URL: \(url)") }
        var request = URLRequest(url: target)
        request.httpMethod = method
        if timeout > 0 { request.timeoutInterval = timeout }
        for field in headerFields(headers) {
            request.addValue(field.value, forHTTPHeaderField: field.name)
        }
        if !body.isEmpty, method != "GET", method != "HEAD" {
            request.httpBody = Data(body)
        }
        // The completion handler's form: `data(for:)` needs iOS 15.
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: NetworkHostFailure(error))
                } else if let response {
                    continuation.resume(returning: (data ?? Data(), response))
                } else {
                    continuation.resume(throwing: NetworkHostFailure("badServerResponse: no response"))
                }
            }.resume()
        }
        guard let answer = response as? HTTPURLResponse else {
            throw NetworkHostFailure("badServerResponse: not an HTTP response")
        }
        let fields = answer.allHeaderFields
            .compactMap { name, value in (name as? String).map { [$0, "\(value)"] } }
            .sorted { $0[0].lowercased() < $1[0].lowercased() }
        return HTTPHostResponse(
            status: Int32(answer.statusCode), headers: headersJSON(fields), body: [UInt8](data),
            url: answer.url.flatMap { $0 == target ? nil : $0.absoluteString } ?? "")
    }
}

// MARK: - WebSocket

/// `WebSocketHost` over `URLSessionWebSocketTask`, one connection per id.
/// What arrives waits in the connection's queue until `next` takes it; once
/// the connection closed, `next` answers with the close every time, so a
/// closed connection's record stays for the guest to ask.
///
/// URLSession calls back on its own queue while the guest asks from the
/// reactor's thread and the generated dispatcher's tasks: `lock` guards
/// every connection's state, and continuations resume outside it.
final class URLSessionWebSocketHost: WebSocketHost, @unchecked Sendable {
    private final class Connection {
        let task: URLSessionWebSocketTask
        var opening: CheckedContinuation<Int32, any Error>?
        var subprotocol = ""
        var events: [WebSocketHostEvent] = []
        var waiting: [CheckedContinuation<WebSocketHostEvent, any Error>] = []
        var closed: WebSocketHostEvent?

        init(task: URLSessionWebSocketTask) { self.task = task }
    }

    /// The session's delegate, apart from the host: a session keeps its
    /// delegate until it is invalidated, which the host does when it goes.
    private final class Delegate: NSObject, URLSessionWebSocketDelegate {
        weak var host: URLSessionWebSocketHost?

        func urlSession(
            _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol subprotocol: String?
        ) {
            host?.opened(webSocketTask, subprotocol: subprotocol ?? "")
        }

        func urlSession(
            _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
            didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
        ) {
            host?.closed(webSocketTask, code: closeCode.rawValue, reason: reason)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            guard let task = task as? URLSessionWebSocketTask else { return }
            host?.completed(task, error: error)
        }
    }

    private let lock = NSLock()
    private var connections: [Int32: Connection] = [:]
    private var ids: [Int: Int32] = [:]
    private var lastID: Int32 = 0
    private let session: URLSession

    init() {
        let delegate = Delegate()
        session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        delegate.host = self
    }

    deinit {
        session.invalidateAndCancel()
    }

    func open(url: String, protocols: String, headers: String, timeout: Double) async throws -> Int32 {
        guard let target = URL(string: url) else {
            throw NetworkHostFailure("cannotConnectToHost: not a URL: \(url)")
        }
        var request = URLRequest(url: target)
        if timeout > 0 { request.timeoutInterval = timeout }
        for field in headerFields(headers) {
            request.addValue(field.value, forHTTPHeaderField: field.name)
        }
        let offered = (try? JSONDecoder().decode([String].self, from: Data(protocols.utf8))) ?? []
        if !offered.isEmpty {
            request.setValue(offered.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        let task = session.webSocketTask(with: request)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            lastID += 1
            let id = lastID
            let connection = Connection(task: task)
            connection.opening = continuation
            connections[id] = connection
            ids[task.taskIdentifier] = id
            lock.unlock()
            // The handshake's own deadline (the request's timeout is
            // URLSession's, for waiting on the server).
            if timeout > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.refuse(id, NetworkHostFailure("timedOut: the WebSocket did not open in \(timeout) s"))
                }
            }
            task.resume()
        }
    }

    func subprotocol(id: Int32) -> String {
        lock.lock()
        defer { lock.unlock() }
        return connections[id]?.subprotocol ?? ""
    }

    func sendText(id: Int32, text: String) async throws {
        try await send(id, .string(text))
    }

    func sendData(id: Int32, data: [UInt8]) async throws {
        try await send(id, .data(Data(data)))
    }

    func next(id: Int32) async throws -> WebSocketHostEvent {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard let connection = connections[id] else {
                lock.unlock()
                continuation.resume(throwing: NetworkHostFailure("networkConnectionLost: no WebSocket \(id)"))
                return
            }
            if !connection.events.isEmpty {
                let event = connection.events.removeFirst()
                lock.unlock()
                continuation.resume(returning: event)
            } else if let closed = connection.closed {
                lock.unlock()
                continuation.resume(returning: closed)
            } else {
                connection.waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    func disconnect(id: Int32, code: Int32, reason: String) {
        lock.lock()
        let connection = connections[id]
        lock.unlock()
        guard let connection else { return }
        // Codes a close may carry (1005, 1006 and 1015 only report one that
        // came without); a reason of at most 123 bytes.
        let sent: Int = [1005, 1006, 1015].contains(code) || !(1000...4999).contains(code) ? 1000 : Int(code)
        var bytes = Array(reason.utf8)
        if bytes.count > 123 {
            // Cut at a character's start (a continuation byte is 10xxxxxx).
            var end = 123
            while end > 0, bytes[end] & 0xC0 == 0x80 { end -= 1 }
            bytes = Array(bytes[..<end])
        }
        connection.task.cancel(
            with: URLSessionWebSocketTask.CloseCode(rawValue: sent) ?? .normalClosure, reason: Data(bytes))
        // The close the app asked for is the connection's from now: a `next`
        // waiting answers with it at once.
        finish(connection, code: code, reason: reason)
    }

    // MARK: The connections' events

    private func send(_ id: Int32, _ message: URLSessionWebSocketTask.Message) async throws {
        lock.lock()
        let connection = connections[id]
        let open = connection != nil && connection?.opening == nil && connection?.closed == nil
        lock.unlock()
        guard let connection, open else {
            throw NetworkHostFailure("networkConnectionLost: the WebSocket is closed")
        }
        // The completion handler's form: `send(_:) async` needs iOS 15.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.task.send(message) { error in
                if let error {
                    continuation.resume(throwing: NetworkHostFailure(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func connection(of task: URLSessionTask) -> (Int32, Connection)? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = ids[task.taskIdentifier], let connection = connections[id] else { return nil }
        return (id, connection)
    }

    fileprivate func opened(_ task: URLSessionWebSocketTask, subprotocol: String) {
        guard let (id, connection) = connection(of: task) else { return }
        lock.lock()
        let opening = connection.opening
        connection.opening = nil
        connection.subprotocol = subprotocol
        lock.unlock()
        // Refused already (its deadline passed): the task is being cancelled.
        guard let opening else { return }
        receive(connection)
        opening.resume(returning: id)
    }

    /// Takes the task's messages one after another until it ends; its end
    /// arrives through the delegate (`closed`, `completed`).
    private func receive(_ connection: Connection) {
        connection.task.receive { [weak self] result in
            guard let self, case .success(let message) = result else { return }
            switch message {
            case .string(let text):
                self.deliver(connection, WebSocketHostEvent(kind: 0, text: text, data: [], code: 0))
            case .data(let data):
                self.deliver(connection, WebSocketHostEvent(kind: 1, text: "", data: [UInt8](data), code: 0))
            @unknown default:
                break
            }
            self.receive(connection)
        }
    }

    private func deliver(_ connection: Connection, _ event: WebSocketHostEvent) {
        lock.lock()
        guard connection.closed == nil else {
            lock.unlock()
            return
        }
        if connection.waiting.isEmpty {
            connection.events.append(event)
            lock.unlock()
        } else {
            let waiter = connection.waiting.removeFirst()
            lock.unlock()
            waiter.resume(returning: event)
        }
    }

    /// The connection closed with `code` and `reason`: the close goes after
    /// what is queued, to every call waiting (none waits while anything is
    /// queued), and to every later `next`.
    private func finish(_ connection: Connection, code: Int32, reason: String) {
        lock.lock()
        guard connection.closed == nil else {
            lock.unlock()
            return
        }
        let closed = WebSocketHostEvent(kind: 2, text: reason, data: [], code: code)
        connection.closed = closed
        let waiting = connection.waiting
        connection.waiting = []
        lock.unlock()
        for waiter in waiting { waiter.resume(returning: closed) }
    }

    /// Fails an opening connection (its deadline, or the task ending before
    /// it opened) and forgets it.
    private func refuse(_ id: Int32, _ failure: NetworkHostFailure) {
        lock.lock()
        guard let connection = connections[id], let opening = connection.opening else {
            lock.unlock()
            return
        }
        connection.opening = nil
        connections[id] = nil
        ids[connection.task.taskIdentifier] = nil
        lock.unlock()
        connection.task.cancel()
        opening.resume(throwing: failure)
    }

    fileprivate func closed(_ task: URLSessionWebSocketTask, code: Int, reason: Data?) {
        guard let (_, connection) = connection(of: task) else { return }
        finish(connection, code: Int32(code), reason: reason.map { String(decoding: $0, as: UTF8.self) } ?? "")
    }

    fileprivate func completed(_ task: URLSessionWebSocketTask, error: (any Error)?) {
        guard let (id, connection) = connection(of: task) else { return }
        lock.lock()
        let opening = connection.opening != nil
        lock.unlock()
        if opening {
            // Ended before it opened: refused, unreachable, or a handshake
            // the server did not answer as a WebSocket.
            refuse(id, error.map { NetworkHostFailure($0) }
                ?? NetworkHostFailure("badServerResponse: the server did not open a WebSocket"))
            return
        }
        // Ended without a close it reported (`closed`): the server's code if
        // one came, else 1006, a connection that ended without a closing
        // handshake.
        let code = task.closeCode == .invalid ? 1006 : task.closeCode.rawValue
        finish(connection, code: Int32(code), reason: task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "")
    }
}
