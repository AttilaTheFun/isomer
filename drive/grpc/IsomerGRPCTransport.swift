// IsomerGRPCTransport: an Isomer app's services over gRPC Swift 2 (HTTP/2),
// the transport an app is driven over remotely. `IsomerGRPCServer` serves an
// `IsomerServer` as session_service.proto's three services;
// `IsomerGRPCConnection` reaches one as an `IsomerConnection`. Their methods
// are registered and called here by name, each message going through as its
// serialized bytes (IsomerServer's `serve` and IsomerCall carry bytes), so no
// code is generated from session_service.proto. gRPC Swift 2 runs from macOS
// 15 and iOS 18: so does this module's API. Below them a client takes the
// WebSocket transport.

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import IsomerServing

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

extension IsomerMethod {
    /// The method as session_service.proto names it (package isomer.wire).
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    var grpcDescriptor: MethodDescriptor {
        let parts = rawValue.split(separator: ".")
        return MethodDescriptor(fullyQualifiedService: "isomer.wire." + parts[0], method: String(parts[1]))
    }
}

/// A message as its serialized bytes, both ways: the transport neither reads
/// nor writes a message, IsomerServer's `serve` and the client's caller do.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct SerializedMessage: MessageSerializer, MessageDeserializer {
    func serialize<Bytes: GRPCContiguousBytes>(_ message: [UInt8]) throws -> Bytes {
        Bytes(message)
    }

    func deserialize<Bytes: GRPCContiguousBytes>(_ serializedMessageBytes: Bytes) throws -> [UInt8] {
        serializedMessageBytes.withUnsafeBytes { Array($0) }
    }
}

/// session_service.proto's services: Session.Connect, Headless.Drive and
/// Driver.Attach, each a bidirectional stream, served by `server`.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct IsomerServices: RegistrableRPCService {
    let server: any IsomerServer

    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        let server = self.server
        for method in IsomerMethod.allCases {
            router.registerHandler(
                forMethod: method.grpcDescriptor, deserializer: SerializedMessage(), serializer: SerializedMessage()
            ) { request, _ in
                let call = IsomerCallContext(request.metadata)
                return StreamingServerResponse { writer in
                    try await calling {
                        try await server.serve(method, inbound(request.messages), IsomerOutbound { try await writer.write($0) }, context: call)
                    }
                    return [:]
                }
            }
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
            services: [IsomerServices(server: server)]
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

    /// The method's bidirectional stream as an `IsomerCall` of bytes: what
    /// the caller writes goes out as the stream's requests, its responses
    /// come back.
    public func open(_ method: IsomerMethod, context: IsomerCallContext) async throws -> IsomerCall<[UInt8], [UInt8]> {
        let toServer = IsomerPipe<[UInt8]>()
        let fromServer = IsomerPipe<[UInt8]>()
        // The connection, not just its client, is held for the call: its
        // deinit stops the client.
        Task { [self] in
            do {
                try await client.bidirectionalStreaming(
                    request: StreamingClientRequest(metadata: context.grpcMetadata) { writer in
                        for try await bytes in toServer.inbound { try await writer.write(bytes) }
                    },
                    descriptor: method.grpcDescriptor,
                    serializer: SerializedMessage(),
                    deserializer: SerializedMessage(),
                    options: .defaults
                ) { response in
                    for try await message in response.messages { try await fromServer.outbound.write(message) }
                }
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
