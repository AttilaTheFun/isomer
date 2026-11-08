// IsomerServing: an Isomer app's services, apart from any transport.
//
// `IsomerServer` is what an app serves (shared/wire/session_service.proto's
// three calls, as plain Swift: no gRPC, so it builds wherever Isomer does,
// iOS 16 included). Adapters carry it: IsomerGRPCTransport (gRPC Swift 2 over
// HTTP/2, the primary transport for driving remotely),
// IsomerWebSocketTransport (the same messages over a WebSocket, for clients
// without gRPC: browsers, the Android head, iOS before 18) and
// IsomerProcessTransport (standard input and output, a Unix socket: no TCP on
// one machine). In one process a client calls the server directly
// (`IsomerLocalConnection`).
//
// A client sees any of them as an `IsomerConnection`, so the CLI and the tests
// don't know which transport they drive an app over.

import Foundation
import IsomerWire
import SwiftProtobuf

/// The calls an app serves (session_service.proto), by their gRPC names.
public enum IsomerMethod: String, Sendable, CaseIterable {
    /// A head draws the app: its events in, frames out.
    case connect = "Session.Connect"
    /// A driver uses the app: commands in, answers out.
    case drive = "Headless.Drive"
    /// A headful app that dialled out is driven: answers in, commands out.
    case attach = "Driver.Attach"

    /// A WebSocket's path for the call.
    public var path: String {
        switch self {
        case .connect: "/session"
        case .drive: "/headless"
        case .attach: "/driver"
        }
    }

    public init?(path: String) {
        guard let method = Self.allCases.first(where: { $0.path == path }) else { return nil }
        self = method
    }
}

/// A call's metadata: `authorization` (`Bearer <token>`), the app's launch
/// environment (`iso_…` keys), and where a hub routes it (`iso-target`).
public struct IsomerCallContext: Sendable {
    public var metadata: [String: String]

    public init(metadata: [String: String] = [:]) {
        self.metadata = metadata
    }

    /// The bearer token the call carries, if any.
    public var token: String? {
        guard let value = metadata["authorization"], value.hasPrefix("Bearer ") else { return nil }
        return String(value.dropFirst("Bearer ".count))
    }

    /// The app's launch environment: each `iso_…` key as its ISO_… variable.
    public var environment: [String: String] {
        var environment: [String: String] = [:]
        for (key, value) in metadata where key.lowercased().hasPrefix("iso_") {
            environment[key.uppercased()] = value
        }
        return environment
    }

    /// The attached app a hub routes the call to (`iso-target`).
    public var target: String? { metadata["iso-target"] }

    public static func authorized(_ token: String?, metadata: [String: String] = [:]) -> Self {
        var metadata = metadata
        if let token { metadata["authorization"] = "Bearer \(token)" }
        return Self(metadata: metadata)
    }
}

/// Why a call failed, as gRPC's status codes name it.
public struct IsomerCallError: Error, CustomStringConvertible, Sendable {
    public enum Code: String, Sendable {
        case unimplemented, unauthenticated, invalidArgument, notFound, unavailable, `internal`
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code.rawValue): \(message)" }
}

/// Messages into a call: a plain throwing stream (not `some AsyncSequence<…>`,
/// whose failure type needs iOS 18).
public typealias IsomerInbound<Message: Sendable> = AsyncThrowingStream<Message, any Error>

/// Where a call writes its messages.
public struct IsomerOutbound<Message: Sendable>: Sendable {
    private let send: @Sendable (Message) async throws -> Void

    public init(_ send: @escaping @Sendable (Message) async throws -> Void) {
        self.send = send
    }

    public func write(_ message: Message) async throws {
        try await send(message)
    }
}

/// What an Isomer app serves. Each call returns when it's over: its inbound
/// messages ended, or the server ended it.
public protocol IsomerServer: Sendable {
    func connect(
        _ messages: IsomerInbound<Wire_ClientMessage>,
        _ frames: IsomerOutbound<Wire_ServerMessage>,
        context: IsomerCallContext
    ) async throws

    func drive(
        _ commands: IsomerInbound<Wire_Command>,
        _ answers: IsomerOutbound<Wire_Answer>,
        context: IsomerCallContext
    ) async throws

    func attach(
        _ answers: IsomerInbound<Wire_Answer>,
        _ commands: IsomerOutbound<Wire_Command>,
        context: IsomerCallContext
    ) async throws
}

extension IsomerServer {
    public func connect(
        _ messages: IsomerInbound<Wire_ClientMessage>,
        _ frames: IsomerOutbound<Wire_ServerMessage>,
        context: IsomerCallContext
    ) async throws {
        throw IsomerCallError(.unimplemented, "this app serves no session")
    }

    public func drive(
        _ commands: IsomerInbound<Wire_Command>,
        _ answers: IsomerOutbound<Wire_Answer>,
        context: IsomerCallContext
    ) async throws {
        throw IsomerCallError(.unimplemented, "this app can't be driven")
    }

    public func attach(
        _ answers: IsomerInbound<Wire_Answer>,
        _ commands: IsomerOutbound<Wire_Command>,
        context: IsomerCallContext
    ) async throws {
        throw IsomerCallError(.unimplemented, "nothing attaches here")
    }

    /// One call with its messages as bytes (each a serialized message): what
    /// the transports without types of their own (a WebSocket, a pipe) carry.
    public func serve(
        _ method: IsomerMethod,
        _ inbound: IsomerInbound<[UInt8]>,
        _ outbound: IsomerOutbound<[UInt8]>,
        context: IsomerCallContext
    ) async throws {
        switch method {
        case .connect:
            try await connect(Self.decoding(inbound), Self.encoding(outbound), context: context)
        case .drive:
            try await drive(Self.decoding(inbound), Self.encoding(outbound), context: context)
        case .attach:
            try await attach(Self.decoding(inbound), Self.encoding(outbound), context: context)
        }
    }

    static func decoding<M: SwiftProtobuf.Message & Sendable>(_ bytes: IsomerInbound<[UInt8]>) -> IsomerInbound<M> {
        bytes.decoded()
    }

    static func encoding<M: SwiftProtobuf.Message & Sendable>(_ bytes: IsomerOutbound<[UInt8]>) -> IsomerOutbound<M> {
        IsomerOutbound { message in try await bytes.write(try message.serializedBytes()) }
    }
}

extension AsyncThrowingStream where Element == [UInt8], Failure == any Error {
    /// Each message's bytes decoded as `M`.
    public func decoded<M: SwiftProtobuf.Message & Sendable>(as type: M.Type = M.self) -> IsomerInbound<M> {
        let bytes = self
        return IsomerInbound { continuation in
            let task = Task {
                do {
                    for try await message in bytes { continuation.yield(try M(serializedBytes: message)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Checks a call's token. With no tokens, every call passes: a listener on
/// the loopback address or a socket only its user can open.
public struct IsomerAuthorization: Sendable {
    public var tokens: Set<String>

    public init(tokens: Set<String> = []) {
        self.tokens = tokens
    }

    /// The token in `ISO_DRIVE_TOKEN`, or the first line of the file
    /// `ISO_DRIVE_TOKEN_FILE` names.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        if let token = environment["ISO_DRIVE_TOKEN"], !token.isEmpty { return Self(tokens: [token]) }
        if let path = environment["ISO_DRIVE_TOKEN_FILE"],
           let text = try? String(contentsOfFile: path, encoding: .utf8),
           let line = text.split(whereSeparator: \.isNewline).first {
            return Self(tokens: [String(line).trimmingCharacters(in: .whitespaces)])
        }
        return Self()
    }

    public var required: Bool { !tokens.isEmpty }

    public func check(_ context: IsomerCallContext) throws {
        guard required else { return }
        guard let token = context.token, tokens.contains(token) else {
            throw IsomerCallError(.unauthenticated, "this app needs its token (Authorization: Bearer <token>)")
        }
    }
}

/// A server that checks each call's token before passing it on.
public struct IsomerAuthorizedServer: IsomerServer {
    public let server: any IsomerServer
    public let authorization: IsomerAuthorization

    public init(_ server: any IsomerServer, authorization: IsomerAuthorization) {
        self.server = server
        self.authorization = authorization
    }

    public func connect(_ messages: IsomerInbound<Wire_ClientMessage>, _ frames: IsomerOutbound<Wire_ServerMessage>, context: IsomerCallContext) async throws {
        try authorization.check(context)
        try await server.connect(messages, frames, context: context)
    }

    public func drive(_ commands: IsomerInbound<Wire_Command>, _ answers: IsomerOutbound<Wire_Answer>, context: IsomerCallContext) async throws {
        try authorization.check(context)
        try await server.drive(commands, answers, context: context)
    }

    public func attach(_ answers: IsomerInbound<Wire_Answer>, _ commands: IsomerOutbound<Wire_Command>, context: IsomerCallContext) async throws {
        try authorization.check(context)
        try await server.attach(answers, commands, context: context)
    }
}
