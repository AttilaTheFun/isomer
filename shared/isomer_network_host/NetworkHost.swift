// The hosts' side of Foundation's networking: what a host implements as
// swift_ffi interfaces (the browser's fetch and WebSocket, Android's
// HttpURLConnection and socket client, Apple's URLSession in a WAMR shell),
// and the adapters that make them IsomerFoundation's transports. A host
// injects its implementations under `NetworkHostKey`'s keys (the web's boot
// does, as an app injects its own services) or hands them to
// `installIsomerNetworkHosts(http:webSocket:)` (Kotlin, before the runtime
// starts); the platform runtime installs what was injected when it starts
// (`installInjectedNetworkHosts`).
//
// A host reports a failure to get any answer by throwing with a message
// that starts with the reason, `NetworkTransportError.Reason`'s raw value
// ("timedOut: no answer in 60 s"); an answer with an error status is an
// answer.

import Foundation
import IsomerFFI
import IsomerFoundation

/// The keys of Isomer's own entries among the injected dependencies.
@ExportedEnum
public enum NetworkHostKey: String {
    case isomerHTTP
    case isomerWebSocket
}

/// A host's answer to one HTTP request.
@ExportedStruct
public struct HTTPHostResponse {
    public let status: Int32
    /// The header fields, as JSON: `[["name", "value"], …]`.
    public let headers: String
    public let body: [UInt8]
    /// The URL that answered, after redirects ("" for the request's own).
    public let url: String
}

/// One HTTP exchange, whole bodies both ways, content codings undone.
@ExportedInterface(namespace: "isomer")
public protocol HTTPHost {
    /// `headers` as `HTTPHostResponse.headers` has them; `timeout` in
    /// seconds.
    func send(method: String, url: String, headers: String, body: [UInt8], timeout: Double) async throws
        -> HTTPHostResponse
}

/// What a WebSocket received: `kind` 0 text, 1 data, 2 closed (then `code`
/// and `text`, the reason).
@ExportedStruct
public struct WebSocketHostEvent {
    public let kind: Int32
    public let text: String
    public let data: [UInt8]
    public let code: Int32
}

/// WebSocket connections, by the id `open` gives each.
@ExportedInterface(namespace: "isomer")
public protocol WebSocketHost {
    /// Opens a connection; `protocols` and `headers` as JSON arrays. Throws
    /// when it cannot.
    func open(url: String, protocols: String, headers: String, timeout: Double) async throws -> Int32
    /// The subprotocol the server chose ("" for none).
    func subprotocol(id: Int32) -> String
    func sendText(id: Int32, text: String) async throws
    func sendData(id: Int32, data: [UInt8]) async throws
    /// The next message, or the close (repeated to every later call).
    func next(id: Int32) async throws -> WebSocketHostEvent
    /// Closes the connection; a pending `next` answers with the close.
    /// (Not `close`: the generated proxies have their own, which releases
    /// them.)
    func disconnect(id: Int32, code: Int32, reason: String)
}

/// Installs the hosts' implementations as Foundation's transports (what a
/// Kotlin host calls before the runtime starts).
@ExportedFunction(namespace: "isomer")
public func installIsomerNetworkHosts(http: any HTTPHost, webSocket: any WebSocketHost) {
    IsomerNetwork.http = HostHTTPTransport(host: http)
    IsomerNetwork.webSocket = HostWebSocketTransport(host: webSocket)
}

/// Installs what the host injected under `NetworkHostKey`'s keys, keeping
/// transports already installed where it injected none.
public func installInjectedNetworkHosts() {
    if let http = injected(.isomerHTTP, as: (any HTTPHost).self) {
        IsomerNetwork.http = HostHTTPTransport(host: http)
    }
    if let webSocket = injected(.isomerWebSocket, as: (any WebSocketHost).self) {
        IsomerNetwork.webSocket = HostWebSocketTransport(host: webSocket)
    }
}

private func injected<T>(_ key: NetworkHostKey, as type: T.Type) -> T? {
    (dependencies[key] as? Lazy<T>)?.value ?? dependencies[key] as? T
}

/// The reason a host's error names, `.unknown` when it names none.
func transportError(_ error: any Error) -> NetworkTransportError {
    if let error = error as? NetworkTransportError { return error }
    let message = "\(error)"
    for reason in [NetworkTransportError.Reason.timedOut, .cannotFindHost, .cannotConnectToHost,
                   .networkConnectionLost, .notConnectedToInternet, .secureConnectionFailed,
                   .cancelled, .badServerResponse] where message.contains(reason.rawValue + ":")
        || message.hasSuffix(reason.rawValue) {
        return NetworkTransportError(reason, message: message)
    }
    return NetworkTransportError(.unknown, message: message)
}

/// Header fields as the JSON the hosts read and write.
func headersJSON(_ fields: [(name: String, value: String)]) -> String {
    (try? String(decoding: JSONEncoder().encode(fields.map { [$0.name, $0.value] }), as: UTF8.self)) ?? "[]"
}

func headerFields(_ json: String) -> [(name: String, value: String)] {
    guard let pairs = try? JSONDecoder().decode([[String]].self, from: Data(json.utf8)) else { return [] }
    return pairs.compactMap { $0.count == 2 ? (name: $0[0], value: $0[1]) : nil }
}

// The host objects are used from the runtime's tasks: a JavaScript one only
// ever from its one thread, a Kotlin or Swift one is safe from any.
final class HostHTTPTransport: HTTPTransport, @unchecked Sendable {
    let host: any HTTPHost

    init(host: any HTTPHost) { self.host = host }

    func send(_ request: HTTPTransportRequest) async throws -> HTTPTransportResponse {
        let answer: HTTPHostResponse
        do {
            answer = try await host.send(
                method: request.method, url: request.url.absoluteString,
                headers: headersJSON(request.headerFields), body: [UInt8](request.body),
                timeout: request.timeoutInterval)
        } catch {
            throw transportError(error)
        }
        return HTTPTransportResponse(
            statusCode: Int(answer.status), headerFields: headerFields(answer.headers),
            body: Data(answer.body), url: answer.url.isEmpty ? nil : URL(string: answer.url))
    }
}

final class HostWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    let host: any WebSocketHost

    init(host: any WebSocketHost) { self.host = host }

    func connect(_ request: WebSocketTransportRequest) async throws -> any WebSocketTransportConnection {
        let encoder = JSONEncoder()
        let protocols = (try? String(decoding: encoder.encode(request.protocols), as: UTF8.self)) ?? "[]"
        do {
            let id = try await host.open(
                url: request.url.absoluteString, protocols: protocols,
                headers: headersJSON(request.headerFields), timeout: request.timeoutInterval)
            return HostWebSocketConnection(host: host, id: id)
        } catch {
            throw transportError(error)
        }
    }
}

final class HostWebSocketConnection: WebSocketTransportConnection, @unchecked Sendable {
    let host: any WebSocketHost
    let id: Int32

    init(host: any WebSocketHost, id: Int32) {
        self.host = host
        self.id = id
    }

    var subprotocol: String? {
        let chosen = host.subprotocol(id: id)
        return chosen.isEmpty ? nil : chosen
    }

    func send(text: String) async throws {
        do { try await host.sendText(id: id, text: text) } catch { throw transportError(error) }
    }

    func send(data: Data) async throws {
        do { try await host.sendData(id: id, data: [UInt8](data)) } catch { throw transportError(error) }
    }

    func receive() async throws -> WebSocketTransportEvent {
        let event: WebSocketHostEvent
        do { event = try await host.next(id: id) } catch { throw transportError(error) }
        switch event.kind {
        case 0: return .text(event.text)
        case 1: return .data(Data(event.data))
        default: return .closed(code: Int(event.code), reason: Data(event.text.utf8))
        }
    }

    func close(code: Int, reason: Data) {
        host.disconnect(id: id, code: Int32(code), reason: String(decoding: reason, as: UTF8.self))
    }
}
