// IsomerWebSocketTransport: an Isomer app's services over WebSockets
// (SwiftNIO), for clients without gRPC: browsers, the Android head, iOS
// before 18. Each connection is one call, named by its path (/session,
// /headless, /driver); each binary message is one of the call's messages,
// and an empty one ends its sender's messages (a WebSocket has no half-close:
// a client that has sent its last command still reads the answers, until the
// server closes).
// A browser can't set headers on a WebSocket, so the token may come as the
// `token` query parameter as well as an `Authorization` header, and `iso_…`
// query parameters are the call's metadata (the app's launch environment).
//
// The server also serves a directory's files over plain HTTP on the same
// port (the web's thin client, web/remote_client).

#if !os(WASI)

import Foundation
import IsomerServing
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

/// HTTP's response parts as an async channel writes them.
final class HTTPResponsePartHandler: ChannelOutboundHandler, RemovableChannelHandler {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch unwrapOutboundIn(data) {
        case .head(let head): context.write(wrapOutboundOut(.head(head)), promise: promise)
        case .body(let buffer): context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        case .end(let trailers): context.write(wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct IsomerWebSocketServer: Sendable {
    public let server: any IsomerServer
    public let host: String
    public let port: Int
    /// A directory whose files are served on GET (the web's thin client).
    public let site: String?

    public init(_ server: any IsomerServer, host: String = "127.0.0.1", port: Int, site: String? = nil) {
        self.server = server
        self.host = host
        self.port = port
        self.site = site
    }

    enum Connection {
        case webSocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, HTTPRequestHead)
        case http(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
    }

    /// Serves until cancelled; `listening` is told the port bound (the
    /// system's choice for 0).
    public func run(listening: @escaping @Sendable (Int) async -> Void = { _ in }) async throws {
        let listener: NIOAsyncChannel<EventLoopFuture<Connection>, Never> = try await ServerBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    let upgrader = NIOTypedWebSocketServerUpgrader<Connection>(
                        maxFrameSize: 1 << 26,
                        shouldUpgrade: { channel, head in
                            let path = String(head.uri.split(separator: "?").first ?? "")
                            return channel.eventLoop.makeSucceededFuture(IsomerMethod(path: path) == nil ? nil : HTTPHeaders())
                        },
                        upgradePipelineHandler: { channel, head in
                            channel.eventLoop.makeCompletedFuture {
                                // A client's message may come in fragments:
                                // joined here into whole messages.
                                try channel.pipeline.syncOperations.addHandler(
                                    NIOWebSocketFrameAggregator(
                                        minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: 1 << 16, maxAccumulatedFrameSize: 1 << 26))
                                return Connection.webSocket(try NIOAsyncChannel(wrappingChannelSynchronously: channel), head)
                            }
                        }
                    )
                    let configuration = NIOTypedHTTPServerUpgradeConfiguration(
                        upgraders: [upgrader],
                        notUpgradingCompletionHandler: { channel in
                            channel.eventLoop.makeCompletedFuture {
                                try channel.pipeline.syncOperations.addHandler(HTTPResponsePartHandler())
                                return Connection.http(try NIOAsyncChannel(wrappingChannelSynchronously: channel))
                            }
                        }
                    )
                    return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                        configuration: .init(upgradeConfiguration: configuration))
                }
            }
        await listening(listener.channel.localAddress?.port ?? port)
        try await withThrowingDiscardingTaskGroup { group in
            try await listener.executeThenClose { connections in
                for try await connection in connections {
                    group.addTask {
                        do {
                            switch try await connection.get() {
                            case .webSocket(let channel, let head): try await serve(channel, head: head)
                            case .http(let channel): try await serveFiles(channel)
                            }
                        } catch {
                            // One connection's failure is its own.
                        }
                    }
                }
            }
        }
    }

    /// A call's metadata from its request: the `Authorization` header (or a
    /// `token` query parameter) and the `iso_…` query parameters.
    static func context(of head: HTTPRequestHead) -> IsomerCallContext {
        var metadata: [String: String] = [:]
        if let authorization = head.headers.first(name: "Authorization") { metadata["authorization"] = authorization }
        for item in URLComponents(string: head.uri)?.queryItems ?? [] {
            let name = item.name.lowercased()
            if name == "token", let value = item.value { metadata["authorization"] = "Bearer \(value)" }
            if name.hasPrefix("iso_") || name == "iso-target" { metadata[name] = item.value ?? "" }
        }
        return IsomerCallContext(metadata: metadata)
    }

    func serve(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, head: HTTPRequestHead) async throws {
        let path = String(head.uri.split(separator: "?").first ?? "")
        guard let method = IsomerMethod(path: path) else { return }
        let context = Self.context(of: head)
        let server = server
        try await channel.executeThenClose { inbound, outbound in
            let fromClient = IsomerPipe<[UInt8]>()
            let allocator = channel.channel.allocator
            try await withThrowingTaskGroup(of: Void.self) { group in
                // The client's messages, until it closes; the call goes on to
                // answer what it sent before closing.
                group.addTask {
                    for try await frame in inbound {
                        switch frame.opcode {
                        case .binary where frame.unmaskedData.readableBytes == 0:
                            fromClient.finish()
                        case .binary: try await fromClient.outbound.write(Array(buffer: frame.unmaskedData))
                        case .ping: try await outbound.write(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData))
                        case .connectionClose:
                            fromClient.finish()
                            return
                        default: break
                        }
                    }
                    fromClient.finish()
                }
                var closing = allocator.buffer(capacity: 2)
                do {
                    try await server.serve(method, fromClient.inbound, IsomerOutbound { message in
                        try await outbound.write(WebSocketFrame(fin: true, opcode: .binary, data: allocator.buffer(bytes: message)))
                    }, context: context)
                    closing.write(webSocketErrorCode: .normalClosure)
                } catch let error as IsomerCallError {
                    // The reason a client reads in its close: the call's error.
                    closing.write(webSocketErrorCode: error.code == .unauthenticated ? .policyViolation : .unexpectedServerError)
                    closing.writeString(String(error.description.prefix(120)))
                } catch {
                    closing.write(webSocketErrorCode: .unexpectedServerError)
                }
                try? await outbound.write(WebSocketFrame(fin: true, opcode: .connectionClose, data: closing))
                group.cancelAll()
            }
        }
    }

    /// The site's files (GET only), or 404.
    func serveFiles(_ channel: NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>) async throws {
        let site = site
        try await channel.executeThenClose { inbound, outbound in
            for try await part in inbound {
                guard case .head(let head) = part else { continue }
                var path = String(head.uri.split(separator: "?").first ?? "/")
                if path.hasSuffix("/") { path += "index.html" }
                var body: Data?
                if head.method == .GET, let site, !path.contains("..") {
                    body = FileManager.default.contents(atPath: site + path)
                }
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: String(body?.count ?? 0))
                headers.add(name: "Content-Type", value: Self.contentType(path))
                headers.add(name: "Cache-Control", value: "no-store")
                try await outbound.write(.head(HTTPResponseHead(version: head.version, status: body == nil ? .notFound : .ok, headers: headers)))
                if let body { try await outbound.write(.body(ByteBuffer(bytes: body))) }
                try await outbound.write(.end(nil))
            }
        }
    }

    static func contentType(_ path: String) -> String {
        switch path.split(separator: ".").last ?? "" {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript"
        case "css": "text/css"
        case "json": "application/json"
        case "wasm": "application/wasm"
        case "png": "image/png"
        case "svg": "image/svg+xml"
        case "ttf": "font/ttf"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }
}

/// An app's services through its WebSocket server: a connection a call.
@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
public struct IsomerWebSocketConnection: IsomerConnection {
    public let host: String
    public let port: Int
    /// The path the app's server is under (a proxy's prefix), without a
    /// trailing slash.
    public let base: String

    public init(host: String, port: Int, base: String = "") {
        self.host = host
        self.port = port
        self.base = base
    }

    enum Upgrade {
        case webSocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case refused
    }

    public func open(_ method: IsomerMethod, context: IsomerCallContext) async throws -> IsomerCall<[UInt8], [UInt8]> {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "\(host):\(port)")
        headers.add(name: "Content-Length", value: "0")
        var query: [String] = []
        for (key, value) in context.metadata {
            if key == "authorization" { headers.add(name: "Authorization", value: value) } else {
                query.append("\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)")
            }
        }
        let uri = base + method.path + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
        let request = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri, headers: headers)
        let upgrade: EventLoopFuture<Upgrade> = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            .connect(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    let upgrader = NIOTypedWebSocketClientUpgrader<Upgrade>(
                        maxFrameSize: 1 << 26,
                        upgradePipelineHandler: { channel, _ in
                            channel.eventLoop.makeCompletedFuture {
                                try channel.pipeline.syncOperations.addHandler(
                                    NIOWebSocketFrameAggregator(
                                        minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: 1 << 16, maxAccumulatedFrameSize: 1 << 26))
                                return Upgrade.webSocket(try NIOAsyncChannel(wrappingChannelSynchronously: channel))
                            }
                        }
                    )
                    let configuration = NIOTypedHTTPClientUpgradeConfiguration(
                        upgradeRequestHead: request,
                        upgraders: [upgrader],
                        notUpgradingCompletionHandler: { channel in channel.eventLoop.makeCompletedFuture { Upgrade.refused } }
                    )
                    return try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                        configuration: .init(upgradeConfiguration: configuration))
                }
            }
        guard case .webSocket(let channel) = try await upgrade.get() else {
            throw IsomerCallError(.notFound, "\(host):\(port) serves no \(method.rawValue)")
        }
        let toServer = IsomerPipe<[UInt8]>()
        let fromServer = IsomerPipe<[UInt8]>()
        let allocator = channel.channel.allocator
        Task {
            do {
                try await channel.executeThenClose { inbound, outbound in
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await message in toServer.inbound {
                                try await outbound.write(WebSocketFrame(
                                    fin: true, opcode: .binary, maskKey: .random(), data: allocator.buffer(bytes: message)))
                            }
                            // The client's messages end; the server closes
                            // once it has answered them.
                            try await outbound.write(WebSocketFrame(fin: true, opcode: .binary, maskKey: .random(), data: allocator.buffer(capacity: 0)))
                        }
                        group.addTask {
                            for try await frame in inbound {
                                switch frame.opcode {
                                case .binary: try await fromServer.outbound.write(Array(buffer: frame.unmaskedData))
                                case .connectionClose:
                                    var data = frame.unmaskedData
                                    let code = data.readWebSocketErrorCode()
                                    let reason = data.readString(length: data.readableBytes) ?? ""
                                    if let code, code != .normalClosure {
                                        let error = code == .policyViolation
                                            ? IsomerCallError(.unauthenticated, reason)
                                            : IsomerCallError(.internal, reason)
                                        fromServer.finish(throwing: error)
                                    } else {
                                        fromServer.finish()
                                    }
                                    // Nothing more goes out once the server has closed.
                                    toServer.finish()
                                    return
                                default: break
                                }
                            }
                            fromServer.finish()
                            toServer.finish()
                        }
                        // Over when the server has closed: what it sends after
                        // the client's last message is still read.
                        try await group.waitForAll()
                    }
                }
            } catch {
                fromServer.finish(throwing: error)
            }
        }
        return IsomerCall(outbound: toServer.outbound, inbound: fromServer.inbound, finish: { toServer.finish() })
    }
}

#endif
