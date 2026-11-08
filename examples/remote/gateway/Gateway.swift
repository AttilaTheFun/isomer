// The gateway (gateway/Gateway.swift): an Isomer app built headless (--@isomer//headless), served to
// remote clients, one run of the app for each connection (shared/wire's
// session.proto, headless.proto and session_service.proto in isomer):
//
//   ws://<host>:<port>/session     a remote session: each binary message a
//                                  ClientMessage in, a ServerMessage out
//   ws://<host>:<port>/headless?ISO_STORYBOOK_STORY=…
//                                  the headless driver: a Command in, an
//                                  Answer out
//   http://<host>:<port>/…         the files of --site (the web's thin client)
//   gRPC on --grpc-port            Session.Connect and Headless.Drive
//
//   gateway --app <the app's binary> [--host 127.0.0.1] [--port 8090]
//           [--grpc-port 8091] [--site <directory>]
//
// Once listening it prints one line, `gateway: ws://<host>:<port>/session
// grpc <host>:<port>`, the ports bound (the system's, for 0).
//
// The app speaks the same messages length-delimited on its standard input
// and output (ISO_HEADLESS_PROTOCOL=session or binary); the gateway frames
// them and passes them on, reading only a session's `start` (the app's
// launch environment, its ISO_ entries).

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import RemoteServiceServer
import RemoteWire
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct Options {
    var app = ""
    var host = "127.0.0.1"
    var port = 8090
    var grpcPort = 8091
    var site: String?

    init(_ arguments: [String]) {
        var rest = arguments.makeIterator()
        while let argument = rest.next() {
            switch argument {
            case "--app": app = rest.next() ?? ""
            case "--host": host = rest.next() ?? host
            case "--port": port = Int(rest.next() ?? "") ?? port
            case "--grpc-port": grpcPort = Int(rest.next() ?? "") ?? grpcPort
            case "--site": site = rest.next()
            default:
                FileHandle.standardError.write(Data("gateway: unknown argument \(argument)\n".utf8))
                exit(2)
            }
        }
        if app.isEmpty {
            FileHandle.standardError.write(Data("gateway: --app <the app built headless> is needed\n".utf8))
            exit(2)
        }
    }
}

/// One run of the app: what goes to its standard input and comes from its
/// standard output, a message at a time.
final class AppRun: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    let messages: AsyncStream<[UInt8]>

    /// `mode`: "session" or "binary" (the headless driver).
    init(app: String, mode: String, environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: app)
        var launch = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("ISO_") }
        for (key, value) in environment where key.hasPrefix("ISO_") { launch[key] = value }
        launch["ISO_HEADLESS_PROTOCOL"] = mode
        process.environment = launch
        process.standardInput = input
        process.standardOutput = output
        let descriptor = output.fileHandleForReading.fileDescriptor
        var continuation: AsyncStream<[UInt8]>.Continuation!
        messages = AsyncStream { continuation = $0 }
        let yield = continuation!
        try process.run()
        Thread.detachNewThread {
            while let message = Delimited.read(from: descriptor) { yield.yield(message) }
            yield.finish()
        }
    }

    func send(_ message: [UInt8]) {
        try? input.fileHandleForWriting.write(contentsOf: Delimited.frame(message))
    }

    /// Ends the run: its input closes (the host exits at its end), and it is
    /// stopped if it hasn't gone a second later.
    func end() {
        try? input.fileHandleForWriting.close()
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Length-delimited messages: a varint length, then the message.
enum Delimited {
    static func frame(_ message: [UInt8]) -> Data {
        var framed = Data()
        var length = UInt64(message.count)
        repeat {
            var byte = UInt8(length & 0x7F)
            length >>= 7
            if length != 0 { byte |= 0x80 }
            framed.append(byte)
        } while length != 0
        framed.append(contentsOf: message)
        return framed
    }

    static func read(from descriptor: Int32) -> [UInt8]? {
        var length = 0
        var shift = 0
        while true {
            guard shift < 63, let byte = readExactly(1, from: descriptor)?.first else { return nil }
            length |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return length == 0 ? [] : readExactly(length, from: descriptor)
    }

    private static func readExactly(_ count: Int, from descriptor: Int32) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let got = bytes.withUnsafeMutableBytes { buffer in
                #if canImport(Darwin)
                Darwin.read(descriptor, buffer.baseAddress! + filled, count - filled)
                #else
                Glibc.read(descriptor, buffer.baseAddress! + filled, count - filled)
                #endif
            }
            if got < 0 && errno == EINTR { continue }
            if got <= 0 { return nil }
            filled += got
        }
        return bytes
    }
}

/// A session's launch environment, from its first message.
func environment(ofStart bytes: [UInt8]) -> [String: String]? {
    guard let message = try? Wire_ClientMessage(serializedBytes: bytes), case .start(let start)? = message.message else {
        return nil
    }
    return start.environment
}

// MARK: - gRPC

struct SessionService: Wire_Session.SimpleServiceProtocol {
    let app: String

    func connect(
        request: RPCAsyncSequence<Wire_ClientMessage, any Error>,
        response: RPCWriter<Wire_ServerMessage>,
        context: ServerContext
    ) async throws {
        var incoming = request.makeAsyncIterator()
        guard let first = try await incoming.next(), case .start(let start)? = first.message else {
            throw RPCError(code: .invalidArgument, message: "a session's first message is its start")
        }
        let run = try AppRun(app: app, mode: "session", environment: start.environment)
        defer { run.end() }
        run.send(try first.serializedBytes())
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while let message = try await incoming.next() { run.send(try message.serializedBytes()) }
            }
            group.addTask {
                for await bytes in run.messages { try await response.write(try Wire_ServerMessage(serializedBytes: bytes)) }
            }
            // Either side's end is the session's.
            try await group.next()
            group.cancelAll()
        }
    }
}

struct HeadlessService: Wire_Headless.ServiceProtocol {
    let app: String

    func drive(
        request: StreamingServerRequest<Wire_Command>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Wire_Answer> {
        var environment: [String: String] = [:]
        for (key, value) in request.metadata where key.hasPrefix("iso_") {
            if case .string(let text) = value { environment[key.uppercased()] = text }
        }
        let run = try AppRun(app: app, mode: "binary", environment: environment)
        return StreamingServerResponse { response in
            defer { run.end() }
            var answers = run.messages.makeAsyncIterator()
            for try await command in request.messages {
                run.send(try command.serializedBytes())
                guard let bytes = await answers.next() else { break }
                try await response.write(try Wire_Answer(serializedBytes: bytes))
                if command.cmd == "quit" { break }
            }
            return [:]
        }
    }
}

// MARK: - WebSocket and files

enum Connection {
    case webSocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, uri: String)
    case http(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
}

/// HTTP's response parts as the async channel writes them.
final class ResponsePartHandler: ChannelOutboundHandler, RemovableChannelHandler {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = unwrapOutboundIn(data)
        switch part {
        case .head(let head): context.write(wrapOutboundOut(.head(head)), promise: promise)
        case .body(let buffer): context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        case .end(let trailers): context.write(wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}

struct WebServer {
    let options: Options
    /// Told the port bound (the one asked for, or the system's for 0).
    let listening: @Sendable (Int) async -> Void

    func run() async throws {
        let server: NIOAsyncChannel<EventLoopFuture<Connection>, Never> = try await ServerBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: options.host, port: options.port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    let upgrader = NIOTypedWebSocketServerUpgrader<Connection>(
                        maxFrameSize: 1 << 26,
                        shouldUpgrade: { channel, head in
                            let path = head.uri.split(separator: "?").first ?? ""
                            let known = path == "/session" || path == "/headless"
                            return channel.eventLoop.makeSucceededFuture(known ? HTTPHeaders() : nil)
                        },
                        upgradePipelineHandler: { channel, head in
                            channel.eventLoop.makeCompletedFuture {
                                // The client's frames may come in parts; they are
                                // joined into whole messages here.
                                try channel.pipeline.syncOperations.addHandler(
                                    NIOWebSocketFrameAggregator(minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: 1 << 16,
                                                                maxAccumulatedFrameSize: 1 << 26))
                                return Connection.webSocket(try NIOAsyncChannel(wrappingChannelSynchronously: channel), uri: head.uri)
                            }
                        }
                    )
                    let configuration = NIOTypedHTTPServerUpgradeConfiguration(
                        upgraders: [upgrader],
                        notUpgradingCompletionHandler: { channel in
                            channel.eventLoop.makeCompletedFuture {
                                try channel.pipeline.syncOperations.addHandler(ResponsePartHandler())
                                return Connection.http(try NIOAsyncChannel(wrappingChannelSynchronously: channel))
                            }
                        }
                    )
                    return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                        configuration: .init(upgradeConfiguration: configuration))
                }
            }
        await listening(server.channel.localAddress?.port ?? options.port)
        try await withThrowingDiscardingTaskGroup { group in
            try await server.executeThenClose { connections in
                for try await connection in connections {
                    group.addTask {
                        do {
                            switch try await connection.get() {
                            case .webSocket(let channel, let uri): try await serve(channel, uri: uri)
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

    /// A session (or a driver) over a WebSocket: each binary message a
    /// message of the protocol.
    func serve(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, uri: String) async throws {
        let components = URLComponents(string: uri)
        let isSession = components?.path == "/session"
        try await channel.executeThenClose { inbound, outbound in
            var frames = inbound.makeAsyncIterator()
            var run: AppRun?
            defer { run?.end() }
            if isSession {
                // The start, before the app can be run.
                while run == nil, let frame = try await frames.next() {
                    guard frame.opcode == .binary else { continue }
                    let bytes = Array(buffer: frame.unmaskedData)
                    guard let environment = environment(ofStart: bytes) else { continue }
                    run = try AppRun(app: options.app, mode: "session", environment: environment)
                    run?.send(bytes)
                }
            } else {
                var environment: [String: String] = [:]
                for item in components?.queryItems ?? [] where item.name.hasPrefix("ISO_") {
                    environment[item.name] = item.value ?? ""
                }
                run = try AppRun(app: options.app, mode: "binary", environment: environment)
            }
            guard let run else { return }
            let allocator = channel.channel.allocator
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while let frame = try await frames.next() {
                        switch frame.opcode {
                        case .binary:
                            run.send(Array(buffer: frame.unmaskedData))
                        case .ping:
                            try await outbound.write(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData))
                        case .connectionClose:
                            var data = frame.unmaskedData
                            let code = data.readSlice(length: 2) ?? ByteBuffer()
                            try await outbound.write(WebSocketFrame(fin: true, opcode: .connectionClose, data: code))
                            return
                        default:
                            break
                        }
                    }
                }
                group.addTask {
                    for await message in run.messages {
                        try await outbound.write(WebSocketFrame(fin: true, opcode: .binary, data: allocator.buffer(bytes: message)))
                    }
                    // The app ended: so does the connection.
                    var code = allocator.buffer(capacity: 2)
                    code.write(webSocketErrorCode: .normalClosure)
                    try? await outbound.write(WebSocketFrame(fin: true, opcode: .connectionClose, data: code))
                }
                try await group.next()
                group.cancelAll()
            }
        }
    }

    /// The site's files (GET only), or 404.
    func serveFiles(_ channel: NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>) async throws {
        try await channel.executeThenClose { inbound, outbound in
            for try await part in inbound {
                guard case .head(let head) = part else { continue }
                var path = String(head.uri.split(separator: "?").first ?? "/")
                if path.hasSuffix("/") { path += "index.html" }
                var body: Data?
                if head.method == .GET, let site = options.site, !path.contains("..") {
                    body = FileManager.default.contents(atPath: site + path)
                }
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: String(body?.count ?? 0))
                headers.add(name: "Content-Type", value: contentType(path))
                headers.add(name: "Cache-Control", value: "no-store")
                let status: HTTPResponseStatus = body == nil ? .notFound : .ok
                try await outbound.write(.head(HTTPResponseHead(version: head.version, status: status, headers: headers)))
                if let body { try await outbound.write(.body(ByteBuffer(bytes: body))) }
                try await outbound.write(.end(nil))
            }
        }
    }

    func contentType(_ path: String) -> String {
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

@main
struct Gateway {
    static func main() async throws {
        let options = Options(Array(CommandLine.arguments.dropFirst()))
        let grpc = GRPCServer(
            transport: .http2NIOPosix(
                address: .ipv4(host: options.host, port: options.grpcPort),
                transportSecurity: .plaintext
            ),
            services: [SessionService(app: options.app), HeadlessService(app: options.app)]
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await grpc.serve() }
            let grpcPort = (try await grpc.listeningAddress)?.ipv4?.port ?? options.grpcPort
            group.addTask {
                try await WebServer(options: options) { port in
                    // One line a script waits for (port 0 is the system's choice).
                    print("gateway: ws://\(options.host):\(port)/session grpc \(options.host):\(grpcPort)")
                    fflush(stdout)
                }.run()
            }
            try await group.next()
            group.cancelAll()
        }
    }
}
