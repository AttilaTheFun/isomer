// IsomerGRPCTransport: an Isomer app's services over gRPC Swift 2 (HTTP/2),
// the transport an app is driven over remotely. `IsomerGRPCServer` serves an
// `IsomerServer` as session_service.proto's three services
// (session_service.grpc.swift, protoc-gen-grpc-swift-2's, checked in);
// `IsomerGRPCConnection` reaches one as an `IsomerConnection`. gRPC Swift 2
// runs from macOS 15 and iOS 18: so does this module's API. Below them a
// client takes the WebSocket transport.

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import IsomerServing
import IsomerWire
import SwiftProtobuf

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension IsomerCallContext {
    init(_ metadata: GRPCCore.Metadata) {
        var values: [String: String] = [:]
        for entry in metadata {
            if case .string(let value) = entry.value { values[entry.key] = value }
        }
        self.init(metadata: values)
    }

    var grpcMetadata: GRPCCore.Metadata {
        var metadata = GRPCCore.Metadata()
        for (key, value) in self.metadata { metadata.addString(value, forKey: key) }
        return metadata
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension RPCError {
    init(_ error: IsomerCallError) {
        let code: RPCError.Code
        switch error.code {
        case .unimplemented: code = .unimplemented
        case .unauthenticated: code = .unauthenticated
        case .invalidArgument: code = .invalidArgument
        case .notFound: code = .notFound
        case .unavailable: code = .unavailable
        case .internal: code = .internalError
        }
        self.init(code: code, message: error.message)
    }

    var isomerError: IsomerCallError {
        let code: IsomerCallError.Code
        switch self.code {
        case .unimplemented: code = .unimplemented
        case .unauthenticated, .permissionDenied: code = .unauthenticated
        case .invalidArgument: code = .invalidArgument
        case .notFound: code = .notFound
        case .unavailable: code = .unavailable
        default: code = .internal
        }
        return IsomerCallError(code, message)
    }
}

/// A gRPC request's messages as an `IsomerInbound`.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
private func inbound<M: Sendable>(_ messages: RPCAsyncSequence<M, any Error>) -> IsomerInbound<M> {
    IsomerInbound { continuation in
        let task = Task {
            do {
                for try await message in messages { continuation.yield(message) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

/// Runs a call, with IsomerServing's errors as gRPC's.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
private func calling(_ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch let error as IsomerCallError {
        throw RPCError(error)
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct SessionService: Wire_Session.StreamingServiceProtocol {
    let server: any IsomerServer

    func connect(
        request: StreamingServerRequest<Wire_ClientMessage>, context: ServerContext
    ) async throws -> StreamingServerResponse<Wire_ServerMessage> {
        let call = IsomerCallContext(request.metadata)
        return StreamingServerResponse { writer in
            try await calling {
                try await server.connect(inbound(request.messages), IsomerOutbound { try await writer.write($0) }, context: call)
            }
            return [:]
        }
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct HeadlessService: Wire_Headless.StreamingServiceProtocol {
    let server: any IsomerServer

    func drive(
        request: StreamingServerRequest<Wire_Command>, context: ServerContext
    ) async throws -> StreamingServerResponse<Wire_Answer> {
        let call = IsomerCallContext(request.metadata)
        return StreamingServerResponse { writer in
            try await calling {
                try await server.drive(inbound(request.messages), IsomerOutbound { try await writer.write($0) }, context: call)
            }
            return [:]
        }
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct DriverService: Wire_Driver.StreamingServiceProtocol {
    let server: any IsomerServer

    func attach(
        request: StreamingServerRequest<Wire_Answer>, context: ServerContext
    ) async throws -> StreamingServerResponse<Wire_Command> {
        let call = IsomerCallContext(request.metadata)
        return StreamingServerResponse { writer in
            try await calling {
                try await server.attach(inbound(request.messages), IsomerOutbound { try await writer.write($0) }, context: call)
            }
            return [:]
        }
    }
}

/// TLS for a server: a PEM certificate chain and its private key.
public struct IsomerTLSFiles: Sendable {
    public var certificateChain: String
    public var privateKey: String

    public init(certificateChain: String, privateKey: String) {
        self.certificateChain = certificateChain
        self.privateKey = privateKey
    }
}

/// An `IsomerServer` served over gRPC: Session.Connect, Headless.Drive and
/// Driver.Attach.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public struct IsomerGRPCServer: Sendable {
    public let server: any IsomerServer
    public let host: String
    public let port: Int
    public let tls: IsomerTLSFiles?

    public init(_ server: any IsomerServer, host: String = "127.0.0.1", port: Int, tls: IsomerTLSFiles? = nil) {
        self.server = server
        self.host = host
        self.port = port
        self.tls = tls
    }

    /// Serves until cancelled; `listening` is told the port bound (the
    /// system's choice for 0).
    public func run(listening: @escaping @Sendable (Int) async -> Void = { _ in }) async throws {
        let security: HTTP2ServerTransport.Posix.TransportSecurity
        if let tls {
            security = .tls(
                certificateChain: [.file(path: tls.certificateChain, format: .pem)],
                privateKey: .file(path: tls.privateKey, format: .pem)
            )
        } else {
            security = .plaintext
        }
        let grpc = GRPCServer(
            transport: .http2NIOPosix(address: .ipv4(host: host, port: port), transportSecurity: security),
            services: [SessionService(server: server), HeadlessService(server: server), DriverService(server: server)]
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await grpc.serve() }
            let bound = (try await grpc.listeningAddress)?.ipv4?.port ?? port
            await listening(bound)
            try await group.next()
            group.cancelAll()
        }
    }
}

/// An app's services over gRPC: one HTTP/2 connection, a stream a call.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class IsomerGRPCConnection: IsomerConnection, @unchecked Sendable {
    private let client: GRPCClient<HTTP2ClientTransport.Posix>
    private let running: Task<Void, Never>

    /// `tls`: verify the server against the system's trust roots.
    public init(host: String, port: Int, tls: Bool = false) throws {
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: host, port: port),
            transportSecurity: tls ? .tls : .plaintext
        )
        let client = GRPCClient(transport: transport)
        self.client = client
        self.running = Task { try? await client.runConnections() }
    }

    deinit {
        client.beginGracefulShutdown()
    }

    /// Ends the connection once its calls are over.
    public func close() {
        client.beginGracefulShutdown()
    }

    public func open(_ method: IsomerMethod, context: IsomerCallContext) async throws -> IsomerCall<[UInt8], [UInt8]> {
        switch method {
        case .connect:
            return bridge(context) { (produce: @escaping @Sendable (RPCWriter<Wire_ClientMessage>) async throws -> Void, consume: @escaping @Sendable (StreamingClientResponse<Wire_ServerMessage>) async throws -> Void) in
                try await Wire_Session.Client(wrapping: self.client).connect(
                    metadata: context.grpcMetadata, requestProducer: produce, onResponse: consume)
            }
        case .drive:
            return bridge(context) { (produce: @escaping @Sendable (RPCWriter<Wire_Command>) async throws -> Void, consume: @escaping @Sendable (StreamingClientResponse<Wire_Answer>) async throws -> Void) in
                try await Wire_Headless.Client(wrapping: self.client).drive(
                    metadata: context.grpcMetadata, requestProducer: produce, onResponse: consume)
            }
        case .attach:
            return bridge(context) { (produce: @escaping @Sendable (RPCWriter<Wire_Answer>) async throws -> Void, consume: @escaping @Sendable (StreamingClientResponse<Wire_Command>) async throws -> Void) in
                try await Wire_Driver.Client(wrapping: self.client).attach(
                    metadata: context.grpcMetadata, requestProducer: produce, onResponse: consume)
            }
        }
    }

    /// A bidirectional stream as an `IsomerCall` of bytes: what the client
    /// writes goes out as the stream's requests, its responses come back.
    private func bridge<Outgoing: SwiftProtobuf.Message & Sendable, Incoming: SwiftProtobuf.Message & Sendable>(
        _ context: IsomerCallContext,
        _ call: @escaping @Sendable (
            @escaping @Sendable (RPCWriter<Outgoing>) async throws -> Void,
            @escaping @Sendable (StreamingClientResponse<Incoming>) async throws -> Void
        ) async throws -> Void
    ) -> IsomerCall<[UInt8], [UInt8]> {
        let toServer = IsomerPipe<[UInt8]>()
        let fromServer = IsomerPipe<[UInt8]>()
        Task {
            do {
                try await call(
                    { writer in
                        for try await bytes in toServer.inbound { try await writer.write(try Outgoing(serializedBytes: bytes)) }
                    },
                    { response in
                        for try await message in response.messages { try await fromServer.outbound.write(try message.serializedBytes()) }
                    }
                )
                fromServer.finish()
            } catch let error as RPCError {
                fromServer.finish(throwing: error.isomerError)
            } catch {
                fromServer.finish(throwing: error)
            }
        }
        return IsomerCall(outbound: toServer.outbound, inbound: fromServer.inbound, finish: { toServer.finish() })
    }
}
