// URLSessionWebSocketTask, as Apple's Foundation has it, over the WebSocket
// transport the host installed (IsomerFoundation's IsomerNetwork.webSocket).
// `resume()` opens the connection; what is sent or received before it is
// open waits for it. Sends go out one at a time in the order they were
// asked for, and receives take messages in the order they were asked for,
// each with its own queue. When the connection closes, its close code and
// reason are the task's, and a receive fails as Apple's does (POSIX
// ENOTCONN, "Socket is not connected"). A code CloseCode has no case for
// (an application's own, 4000 to 4999) reads as `.invalid`: Apple's enum,
// imported from C, holds any number and matches none of an app's cases,
// which a Swift enum cannot do; `.invalid` is the case an app's switch
// least often names.
//
// `sendPing` answers once the connection is open, or with the error that
// kept it from opening: the transports carry no pings (a browser's
// WebSocket cannot send one), and Apple's stack answers pings the server
// sends by itself, as theirs do.

import FoundationEssentials
import Synchronization
internal import IsomerFoundation

open class URLSessionWebSocketTask: URLSessionTask, @unchecked Sendable {
    /// A WebSocket message.
    public enum Message: Sendable {
        case data(Data)
        case string(String)
    }

    /// The close codes of RFC 6455.
    public enum CloseCode: Int, Sendable {
        case invalid = 0
        case normalClosure = 1000
        case goingAway = 1001
        case protocolError = 1002
        case unsupportedData = 1003
        case noStatusReceived = 1005
        case abnormalClosure = 1006
        case invalidFramePayloadData = 1007
        case policyViolation = 1008
        case messageTooBig = 1009
        case mandatoryExtensionMissing = 1010
        case internalServerError = 1011
        case tlsHandshakeFailure = 1015
    }

    private struct Socket: Sendable {
        var connection: (any WebSocketTransportConnection)?
        var failure: (any Error)?
        var waiting: [CheckedContinuation<any WebSocketTransportConnection, any Error>] = []
        var closed = false
        var closeCode: CloseCode = .invalid
        var closeReason: Data?
        var maximumMessageSize = 1_048_576
    }

    private let protocols: [String]
    private let socket = Mutex(Socket())
    private let sends = _SerialWork()
    private let receives = _SerialWork()

    init(session: URLSession, identifier: Int, request: URLRequest, protocols: [String]) {
        self.protocols = protocols
        super.init(session: session, identifier: identifier, request: request)
    }

    /// The largest message a receive takes, in bytes (1 MiB unless set): a
    /// larger one fails the receive (POSIX EMSGSIZE) and closes the
    /// connection with `.messageTooBig`.
    open var maximumMessageSize: Int {
        get { socket.withLock { $0.maximumMessageSize } }
        set { socket.withLock { $0.maximumMessageSize = newValue } }
    }

    /// How the connection closed; `.invalid` until it has.
    open var closeCode: CloseCode { socket.withLock { $0.closeCode } }

    /// The reason the closing handshake gave; nil until the connection
    /// closed, and when it gave none.
    open var closeReason: Data? { socket.withLock { $0.closeReason } }

    // MARK: Sending and receiving

    @preconcurrency
    open func send(
        _ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable ((any Error)?) -> Void
    ) {
        sends.add {
            do {
                try await self.deliver(message)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    public func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let done = _Rendezvous<Void>()
        send(message) { error in done.resolve(error.map { .failure($0) } ?? .success(())) }
        try await done.value()
    }

    @preconcurrency
    open func receive(
        completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, any Error>) -> Void
    ) {
        receives.add {
            do {
                completionHandler(.success(try await self.take()))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }

    public func receive() async throws -> URLSessionWebSocketTask.Message {
        let next = _Rendezvous<Message>()
        receive { next.resolve($0) }
        return try await next.value()
    }

    /// Answers once the connection is open, or with why it could not open.
    open func sendPing(pongReceiveHandler: @escaping @Sendable ((any Error)?) -> Void) {
        Task {
            do {
                _ = try await self.connection()
                pongReceiveHandler(nil)
            } catch {
                pongReceiveHandler(error)
            }
        }
    }

    /// Closes the connection with `closeCode` and `reason`, which become
    /// the task's.
    open func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let (open, waiting) = socket.withLock { socket in
            if !socket.closed {
                socket.closed = true
                socket.closeCode = closeCode
                socket.closeReason = reason
            }
            defer { socket.waiting = [] }
            return (socket.connection, socket.waiting)
        }
        open?.close(code: closeCode.rawValue, reason: reason ?? Data())
        // What waited for a connection that will not open now.
        for waiter in waiting { waiter.resume(throwing: Self.notConnected) }
        super.cancel()
    }

    /// Closes the connection going away (1001), as Apple's does.
    open override func cancel() {
        cancel(with: .goingAway, reason: nil)
    }

    // MARK: The connection

    /// Opens the connection; the task runs until it closes.
    override func _run() async {
        guard let transport = IsomerNetwork.webSocket else {
            fail(
                URLError(
                    .notConnectedToInternet, url: originalRequest?.url,
                    debugDescription:
                        "No WebSocket transport is installed (IsomerFoundation's IsomerNetwork.webSocket)."))
            return
        }
        guard let request = originalRequest, let url = Self.webSocketURL(request.url) else {
            fail(URLError(.unsupportedURL, url: originalRequest?.url))
            return
        }
        var fields = request._headerFields.filter {
            $0.name.caseInsensitiveCompare("Sec-WebSocket-Protocol") != .orderedSame
        }
        for field in session.sessionConfiguration._additionalHeaderFields
        where request.value(forHTTPHeaderField: field.name) == nil {
            fields.append(field)
        }
        let connection: any WebSocketTransportConnection
        do {
            connection = try await transport.connect(
                WebSocketTransportRequest(
                    url: url, protocols: protocols, headerFields: fields, timeoutInterval: request.timeoutInterval))
        } catch {
            fail(URLSession.urlError(error, url: request.url))
            return
        }
        // The handshake's answer, as Apple's task gives it.
        var answer = ["Upgrade": "websocket", "Connection": "Upgrade"]
        if let subprotocol = connection.subprotocol { answer["Sec-WebSocket-Protocol"] = subprotocol }
        let response = HTTPURLResponse(url: url, statusCode: 101, httpVersion: "HTTP/1.1", headerFields: answer)
        let waiting = socket.withLock { socket -> [CheckedContinuation<any WebSocketTransportConnection, any Error>]? in
            guard socket.failure == nil && !socket.closed else { return nil }
            socket.connection = connection
            defer { socket.waiting = [] }
            return socket.waiting
        }
        guard let waiting else {
            // Cancelled while it opened: closed as asked.
            let (code, reason) = socket.withLock { ($0.closeCode, $0.closeReason) }
            let sent = code == .invalid ? CloseCode.goingAway : code
            connection.close(code: sent.rawValue, reason: reason ?? Data())
            return
        }
        status.withLock { $0.response = response }
        for waiter in waiting { waiter.resume(returning: connection) }
    }

    /// The open connection, once it is; throws what kept it from opening or
    /// closed it.
    private func connection() async throws -> any WebSocketTransportConnection {
        try await withCheckedThrowingContinuation { continuation in
            let ready = socket.withLock { socket -> Result<any WebSocketTransportConnection, any Error>? in
                if let failure = socket.failure { return .failure(failure) }
                if socket.closed { return .failure(Self.notConnected) }
                if let connection = socket.connection { return .success(connection) }
                socket.waiting.append(continuation)
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    private func deliver(_ message: Message) async throws {
        let connection = try await connection()
        do {
            switch message {
            case .string(let text): try await connection.send(text: text)
            case .data(let data): try await connection.send(data: data)
            }
        } catch {
            throw URLSession.urlError(error, url: originalRequest?.url)
        }
    }

    private func take() async throws -> Message {
        let connection = try await connection()
        let event: WebSocketTransportEvent
        do {
            event = try await connection.receive()
        } catch {
            let failure = URLSession.urlError(error, url: originalRequest?.url)
            closed(code: CloseCode.abnormalClosure.rawValue, reason: nil, failure: failure)
            throw failure
        }
        let limit = maximumMessageSize
        switch event {
        case .text(let text):
            guard text.utf8.count <= limit else { throw tooBig(connection) }
            return .string(text)
        case .data(let data):
            guard data.count <= limit else { throw tooBig(connection) }
            return .data(data)
        case .closed(let code, let reason):
            closed(code: code, reason: reason.isEmpty ? nil : reason, failure: nil)
            throw Self.notConnected
        }
    }

    private func tooBig(_ connection: any WebSocketTransportConnection) -> any Error {
        connection.close(code: CloseCode.messageTooBig.rawValue, reason: Data())
        closed(code: CloseCode.messageTooBig.rawValue, reason: nil, failure: nil)
        return POSIXError(.EMSGSIZE)
    }

    /// The connection closed: the task completes, its close code and reason
    /// what the handshake said (unless the app closed it first).
    private func closed(code: Int, reason: Data?, failure: (any Error)?) {
        socket.withLock { socket in
            if !socket.closed {
                socket.closed = true
                socket.closeCode = CloseCode(rawValue: code) ?? .invalid
                socket.closeReason = reason
            }
        }
        _finish(failure.map { .failed($0, response) } ?? .ended)
    }

    /// The connection could not be opened: whatever waits on it fails.
    private func fail(_ error: any Error) {
        let waiting = socket.withLock { socket in
            socket.failure = error
            defer { socket.waiting = [] }
            return socket.waiting
        }
        for waiter in waiting { waiter.resume(throwing: error) }
        _finish(.failed(error, nil))
    }

    /// Apple's error for a socket used after it closed.
    private static var notConnected: any Error { POSIXError(.ENOTCONN) }

    /// ws and wss as they are; http and https as the WebSocket schemes they
    /// stand for (Apple's task takes those too).
    private static func webSocketURL(_ url: URL?) -> URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "ws", "wss": return url
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        default: return nil
        }
        return components.url
    }
}

/// Work run one item at a time in the order it was added; adding never
/// waits.
final class _SerialWork: Sendable {
    private let state = Mutex<(pending: [@Sendable () async -> Void], running: Bool)>(([], false))

    func add(_ work: @escaping @Sendable () async -> Void) {
        let start = state.withLock { state -> Bool in
            state.pending.append(work)
            defer { state.running = true }
            return !state.running
        }
        if start { Task { await self.drain() } }
    }

    private func drain() async {
        while true {
            let next = state.withLock { state -> (@Sendable () async -> Void)? in
                guard !state.pending.isEmpty else {
                    state.running = false
                    return nil
                }
                return state.pending.removeFirst()
            }
            guard let next else { return }
            await next()
        }
    }
}
