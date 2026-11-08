// An app's services over a WebSocket, through Foundation's URLSession: the
// client a head or a headful app uses wherever Isomer runs (iOS 16 and later,
// the Mac, and Android and the web through Isomer's Foundation, whose
// URLSession goes over the host's WebSocket). The app's side is
// IsomerWebSocketTransport's server: a connection a call, named by its path.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct IsomerURLSessionConnection: IsomerConnection {
    /// The app's server, `ws://host:port` or `wss://…` (and any path
    /// prefix a proxy puts it under).
    public let base: URL

    public init(_ base: URL) {
        self.base = base
    }

    public func open(_ method: IsomerMethod, context: IsomerCallContext) async throws -> IsomerCall<[UInt8], [UInt8]> {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw IsomerCallError(.invalidArgument, "not a WebSocket URL: \(base)")
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + method.path
        var query = components.queryItems ?? []
        var request = URLRequest(url: base)
        for (key, value) in context.metadata {
            if key == "authorization" {
                request.setValue(value, forHTTPHeaderField: "Authorization")
                // A host whose WebSocket can't carry headers (a browser's)
                // still carries the query.
                if let token = context.token { query.append(URLQueryItem(name: "token", value: token)) }
            } else {
                query.append(URLQueryItem(name: key, value: value))
            }
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw IsomerCallError(.invalidArgument, "not a WebSocket URL: \(base)") }
        request.url = url
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        let fromServer = IsomerPipe<[UInt8]>()
        Task {
            while true {
                do {
                    switch try await task.receive() {
                    case .data(let data): try await fromServer.outbound.write(Array(data))
                    case .string(let text): try await fromServer.outbound.write(Array(text.utf8))
                    @unknown default: break
                    }
                } catch {
                    // A normal close ends the call; another, its error.
                    if task.closeCode == .normalClosure || task.closeCode == .invalid && (error as? URLError)?.code == .cancelled {
                        fromServer.finish()
                    } else if task.closeCode == .policyViolation {
                        let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        fromServer.finish(throwing: IsomerCallError(.unauthenticated, reason))
                    } else if task.closeCode != .invalid {
                        let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        fromServer.finish(throwing: IsomerCallError(.internal, reason))
                    } else {
                        fromServer.finish(throwing: IsomerCallError(.unavailable, "\(error)"))
                    }
                    return
                }
            }
        }
        return IsomerCall(
            outbound: IsomerOutbound { message in try await task.send(.data(Data(message))) },
            inbound: fromServer.inbound,
            finish: {
                // The server ends the call when it has answered what came
                // before: it closes, and the receive loop above sees it.
                try? await task.send(.data(Data()))
            }
        )
    }
}
