// The network beneath Isomer's Foundation. `URLSession` there is Apple's
// API over transports a host installs in `IsomerNetwork`: HTTP exchanges
// through `http`, WebSocket connections through `webSocket`. Each platform
// fills them in from its own networking (the browser's `fetch` and
// `WebSocket`, Android's HTTP stack and a WebSocket client in its runtime,
// Apple's URLSession in a WAMR host). Without one, a task fails as it would
// on a device offline (`URLError.notConnectedToInternet`). Apps call
// URLSession; only hosts use what is here.
//
// The types are plain values (String, Data, Int, [String], header fields
// as name-value pairs in order) so that a host written in another language
// can be reached through swift_ffi by a small adapter: swift_ffi's
// interfaces take no `async`, so the adapter keeps a continuation per
// exchange and resumes it from the export the host calls back.

import FoundationEssentials
import Synchronization

/// The transports Isomer's Foundation sends `URLSession`'s work through.
///
/// A host installs them before the app makes its first request; a task
/// reads them when it starts.
public enum IsomerNetwork {
    /// Performs `URLSession`'s HTTP and HTTPS requests: data, upload and
    /// download tasks and their async forms.
    public static var http: (any HTTPTransport)? {
        get { installed.withLock { $0.http } }
        set { installed.withLock { $0.http = newValue } }
    }

    /// Opens `URLSession`'s WebSocket connections
    /// (`URLSessionWebSocketTask`).
    public static var webSocket: (any WebSocketTransport)? {
        get { installed.withLock { $0.webSocket } }
        set { installed.withLock { $0.webSocket = newValue } }
    }
}

private let installed = Mutex<(http: (any HTTPTransport)?, webSocket: (any WebSocketTransport)?)>((nil, nil))

// MARK: - HTTP

/// Performs one HTTP exchange: a request sent, its whole response read.
public protocol HTTPTransport: Sendable {
    /// Sends `request` and returns the server's response with its body read
    /// to the end.
    ///
    /// A status the server answered with, 404 or 500 as much as 200, is a
    /// response. Redirects are followed, as `URLSession` follows them, and
    /// the response says where it came from. The body is what the app
    /// should see: content codings the platform's stack undoes (gzip,
    /// Brotli) are undone.
    ///
    /// Throws a `NetworkTransportError` when there is no response; its
    /// reason becomes the `URLError` code the app sees (any other error is
    /// `URLError.unknown`). The calling task is cancelled when the app
    /// cancels the `URLSessionTask`: a transport that can stop the exchange
    /// (an `AbortController`, OkHttp's `Call.cancel()`) stops it then.
    /// Whatever it returns after that is not used.
    func send(_ request: HTTPTransportRequest) async throws -> HTTPTransportResponse
}

/// What an HTTP exchange sends.
public struct HTTPTransportRequest: Sendable {
    /// The request's method: "GET", "POST", "PUT"…
    public var method: String

    /// An http or https URL.
    public var url: URL

    /// The request's header fields in the order they were set, the names as
    /// the app wrote them; the session's additional headers come after the
    /// request's own. A platform's stack may drop the fields it keeps for
    /// itself (a browser's `fetch` sets `Host`, `Content-Length`,
    /// `Cookie`…).
    public var headerFields: [(name: String, value: String)]

    /// The body; empty for none.
    public var body: Data

    /// How many seconds the exchange may wait on the server, to connect or
    /// for more of its response, before it fails with
    /// `NetworkTransportError.Reason.timedOut`. A stack that has only a
    /// timeout for the whole exchange uses it for that.
    public var timeoutInterval: TimeInterval

    public init(
        method: String,
        url: URL,
        headerFields: [(name: String, value: String)],
        body: Data,
        timeoutInterval: TimeInterval
    ) {
        self.method = method
        self.url = url
        self.headerFields = headerFields
        self.body = body
        self.timeoutInterval = timeoutInterval
    }
}

/// What an HTTP exchange received.
public struct HTTPTransportResponse: Sendable {
    /// The status code: 200, 404…
    public var statusCode: Int

    /// The response's header fields in the order they came. A field that
    /// came more than once is listed each time (Foundation joins their
    /// values with commas, as Apple's does).
    public var headerFields: [(name: String, value: String)]

    /// The whole body, its content codings undone; empty for none.
    public var body: Data

    /// The URL the response came from when redirects led away from the
    /// request's; nil when it is the request's own.
    public var url: URL?

    public init(
        statusCode: Int,
        headerFields: [(name: String, value: String)],
        body: Data,
        url: URL? = nil
    ) {
        self.statusCode = statusCode
        self.headerFields = headerFields
        self.body = body
        self.url = url
    }
}

// MARK: - WebSocket

/// Opens WebSocket connections.
public protocol WebSocketTransport: Sendable {
    /// Opens a connection and returns it once the opening handshake is
    /// done.
    ///
    /// Throws a `NetworkTransportError` when the connection cannot be
    /// opened. The calling task is cancelled when the app cancels the
    /// `URLSessionWebSocketTask` before it opened.
    func connect(_ request: WebSocketTransportRequest) async throws -> any WebSocketTransportConnection
}

/// What a WebSocket connection is opened with.
public struct WebSocketTransportRequest: Sendable {
    /// A ws or wss URL.
    public var url: URL

    /// The subprotocols to offer (`Sec-WebSocket-Protocol`), most preferred
    /// first; empty for none.
    public var protocols: [String]

    /// Header fields for the opening handshake, in the order they were set.
    /// A browser's `WebSocket` cannot send any: there they are left out.
    public var headerFields: [(name: String, value: String)]

    /// How many seconds the opening handshake may take before it fails with
    /// `NetworkTransportError.Reason.timedOut`.
    public var timeoutInterval: TimeInterval

    public init(
        url: URL,
        protocols: [String],
        headerFields: [(name: String, value: String)],
        timeoutInterval: TimeInterval
    ) {
        self.url = url
        self.protocols = protocols
        self.headerFields = headerFields
        self.timeoutInterval = timeoutInterval
    }
}

/// An open WebSocket connection.
///
/// Foundation sends one message at a time and asks for one at a time, each
/// in the order the app did: a host's connection keeps what arrives in a
/// queue until `receive()` takes it.
public protocol WebSocketTransportConnection: AnyObject, Sendable {
    /// The subprotocol the server chose; nil for none.
    var subprotocol: String? { get }

    /// Sends a text message. Throws a `NetworkTransportError` when the
    /// connection is gone.
    func send(text: String) async throws

    /// Sends a binary message. Throws a `NetworkTransportError` when the
    /// connection is gone.
    func send(data: Data) async throws

    /// The next message, or that the connection closed: once it has, every
    /// call returns `.closed` with the same code and reason. Throws a
    /// `NetworkTransportError` when the connection failed without a closing
    /// handshake (or returns `.closed` with code 1006).
    func receive() async throws -> WebSocketTransportEvent

    /// Starts the closing handshake with `code` (1000 to 4999) and `reason`
    /// (UTF-8, at most 123 bytes; empty for none). What already arrived can
    /// still be received; then `receive()` returns `.closed`.
    ///
    /// A browser's `WebSocket` sends only 1000 or 3000 to 4999: a host
    /// there sends 1000 for the other codes.
    func close(code: Int, reason: Data)
}

/// What a WebSocket connection received.
public enum WebSocketTransportEvent: Sendable, Hashable {
    /// A text message.
    case text(String)

    /// A binary message.
    case data(Data)

    /// The connection closed, with the code and reason of its closing
    /// handshake: 1005 and no reason when the handshake carried no code,
    /// 1006 when the connection ended without one.
    case closed(code: Int, reason: Data)
}

// MARK: - Errors

/// Why a transport has no response to give, in the terms of the `URLError`
/// the app then sees.
public struct NetworkTransportError: Error, Sendable, Hashable {
    /// What went wrong. The raw value is the case's name, for hosts that
    /// report it as text.
    public enum Reason: String, Sendable, Hashable {
        /// The server did not answer in time: `URLError.timedOut`.
        case timedOut

        /// The host's name has no address: `URLError.cannotFindHost`.
        case cannotFindHost

        /// The connection was refused or never made:
        /// `URLError.cannotConnectToHost`.
        case cannotConnectToHost

        /// The connection broke during the exchange:
        /// `URLError.networkConnectionLost`.
        case networkConnectionLost

        /// The device has no network: `URLError.notConnectedToInternet`.
        case notConnectedToInternet

        /// The TLS handshake failed or the server's certificate was
        /// refused: `URLError.secureConnectionFailed`.
        case secureConnectionFailed

        /// The exchange was stopped: `URLError.cancelled`.
        case cancelled

        /// The server answered with something that is not HTTP (or not a
        /// WebSocket handshake): `URLError.badServerResponse`.
        case badServerResponse

        /// Anything else, and what a platform cannot tell apart (a
        /// browser's `fetch` says only that it failed): `URLError.unknown`.
        case unknown
    }

    public var reason: Reason

    /// What the platform said, for a developer reading the error: Foundation
    /// keeps it in the `URLError`'s user info under `NSDebugDescription`,
    /// not in its description.
    public var message: String

    public init(_ reason: Reason, message: String = "") {
        self.reason = reason
        self.message = message
    }
}
