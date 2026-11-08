// A client's view of an Isomer app's services, whatever the transport:
// `IsomerConnection` opens a call, an `IsomerCall` writes to it and reads
// from it. IsomerRemote makes one from a URL; `IsomerLocalConnection` calls a
// server in the same process (a test hosted in the app: no network).

import Foundation
import IsomerWire
import SwiftProtobuf

/// One open call: what the client writes and what it reads.
public struct IsomerCall<Outgoing: Sendable, Incoming: Sendable>: Sendable {
    public let outbound: IsomerOutbound<Outgoing>
    public let inbound: IsomerInbound<Incoming>
    private let finishing: @Sendable () async -> Void

    public init(
        outbound: IsomerOutbound<Outgoing>,
        inbound: IsomerInbound<Incoming>,
        finish: @escaping @Sendable () async -> Void
    ) {
        self.outbound = outbound
        self.inbound = inbound
        self.finishing = finish
    }

    public func write(_ message: Outgoing) async throws {
        try await outbound.write(message)
    }

    /// Ends the client's half: the server sees its inbound messages end.
    public func finish() async {
        await finishing()
    }
}

/// An app's services as a client reaches them.
public protocol IsomerConnection: Sendable {
    func open(_ method: IsomerMethod, context: IsomerCallContext) async throws -> IsomerCall<[UInt8], [UInt8]>
}

extension IsomerConnection {
    public func connect(context: IsomerCallContext = .init()) async throws -> IsomerCall<Wire_ClientMessage, Wire_ServerMessage> {
        try await typed(.connect, context: context)
    }

    public func drive(context: IsomerCallContext = .init()) async throws -> IsomerCall<Wire_Command, Wire_Answer> {
        try await typed(.drive, context: context)
    }

    public func attach(context: IsomerCallContext = .init()) async throws -> IsomerCall<Wire_Answer, Wire_Command> {
        try await typed(.attach, context: context)
    }

    private func typed<Outgoing: SwiftProtobuf.Message & Sendable, Incoming: SwiftProtobuf.Message & Sendable>(
        _ method: IsomerMethod, context: IsomerCallContext
    ) async throws -> IsomerCall<Outgoing, Incoming> {
        let call = try await open(method, context: context)
        return IsomerCall(
            outbound: IsomerOutbound { message in try await call.write(try message.serializedBytes()) },
            inbound: call.inbound.decoded(),
            finish: { await call.finish() }
        )
    }
}

/// A pair of ends of a stream of messages: one writes, the other reads.
public struct IsomerPipe<Message: Sendable>: Sendable {
    public let inbound: IsomerInbound<Message>
    public let outbound: IsomerOutbound<Message>
    private let continuation: IsomerInbound<Message>.Continuation

    public init() {
        let (stream, continuation) = IsomerInbound<Message>.makeStream()
        self.inbound = stream
        self.continuation = continuation
        self.outbound = IsomerOutbound { message in
            if case .terminated = continuation.yield(message) {
                throw IsomerCallError(.unavailable, "the call has ended")
            }
        }
    }

    public func finish(throwing error: (any Error)? = nil) {
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}

/// A server in this process, called directly: messages pass as bytes through
/// in-memory streams, with no socket and no copy beyond their encoding.
public struct IsomerLocalConnection: IsomerConnection {
    public let server: any IsomerServer

    public init(_ server: any IsomerServer) {
        self.server = server
    }

    public func open(_ method: IsomerMethod, context: IsomerCallContext) async throws -> IsomerCall<[UInt8], [UInt8]> {
        let toServer = IsomerPipe<[UInt8]>()
        let toClient = IsomerPipe<[UInt8]>()
        let server = server
        Task {
            do {
                try await server.serve(method, toServer.inbound, toClient.outbound, context: context)
                toClient.finish()
            } catch {
                toClient.finish(throwing: error)
            }
        }
        return IsomerCall(outbound: toServer.outbound, inbound: toClient.inbound, finish: { toServer.finish() })
    }
}
