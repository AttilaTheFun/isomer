// IsomerProcessTransport: an Isomer app's services between processes on one
// machine, with no TCP: over standard input and output (a client that starts
// the app) or a Unix socket (an app already running). Each connection carries
// one call: an `Wire_CallHeader` first (the method, its metadata), then the
// call's messages, each length-delimited (shared/wire/swift/Delimited.swift).

// Not on WASI (no processes or sockets) nor Windows (no Unix sockets or
// POSIX descriptors as written here): IsomerRemote says so for its URLs.
#if !os(WASI) && !os(Windows)

import Foundation
import IsomerServing
import IsomerWire
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Bytes over a file descriptor (a pipe's end, a socket), as delimited
/// messages.
struct DescriptorChannel: Sendable {
    let input: Int32
    let output: Int32

    /// The messages read from `input`, on a thread of their own, until its end.
    func messages() -> IsomerInbound<[UInt8]> {
        let input = input
        return IsomerInbound { continuation in
            Thread.detachNewThread {
                while let message = WireDelimited.read(from: input) { continuation.yield(message) }
                continuation.finish()
            }
        }
    }

    /// Writes one message, whole, to `output`.
    func write(_ message: [UInt8]) throws {
        var framed = [UInt8]()
        var length = UInt64(message.count)
        repeat {
            var byte = UInt8(length & 0x7F)
            length >>= 7
            if length != 0 { byte |= 0x80 }
            framed.append(byte)
        } while length != 0
        framed += message
        var sent = 0
        while sent < framed.count {
            let wrote = framed.withUnsafeBytes { buffer in
                systemWrite(output, buffer.baseAddress! + sent, framed.count - sent)
            }
            if wrote < 0 && errno == EINTR { continue }
            guard wrote > 0 else { throw IsomerCallError(.unavailable, "the other end has gone") }
            sent += wrote
        }
    }
}

private func systemWrite(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(descriptor, bytes, count)
    #elseif canImport(Glibc)
    Glibc.write(descriptor, bytes, count)
    #else
    Musl.write(descriptor, bytes, count)
    #endif
}

private func systemClose(_ descriptor: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(descriptor)
    #elseif canImport(Glibc)
    _ = Glibc.close(descriptor)
    #else
    _ = Musl.close(descriptor)
    #endif
}

/// A Unix socket's address, for `bind` and `connect`.
private func withSocketAddress<R>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) throws -> R {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { throw IsomerCallError(.invalidArgument, "socket path too long: \(path)") }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: bytes)
        buffer[bytes.count] = 0
    }
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

private func streamSocket() -> Int32 {
    #if canImport(Darwin)
    socket(AF_UNIX, SOCK_STREAM, 0)
    #else
    socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #endif
}

public enum IsomerProcessServer {
    /// Serves one call on standard input and output: its header, then its
    /// messages. Returns when the call is over.
    public static func serveStandardIO(_ server: any IsomerServer) async throws {
        let channel = DescriptorChannel(input: 0, output: 1)
        try await serve(server, on: channel)
    }

    /// Serves each connection to the Unix socket at `path` (made only its
    /// user can open), a call each, until the process ends.
    public static func listen(unixSocket path: String, _ server: any IsomerServer) throws {
        unlink(path)
        let listener = streamSocket()
        guard listener >= 0 else { throw IsomerCallError(.unavailable, "no socket: errno \(errno)") }
        let bound = try withSocketAddress(path) { bind(listener, $0, $1) }
        guard bound == 0 else { throw IsomerCallError(.unavailable, "can't bind \(path): errno \(errno)") }
        chmod(path, 0o600)
        guard systemListen(listener, 16) == 0 else { throw IsomerCallError(.unavailable, "can't listen on \(path): errno \(errno)") }
        Thread.detachNewThread {
            while true {
                let connection = accept(listener, nil, nil)
                if connection < 0 {
                    if errno == EINTR { continue }
                    return
                }
                Task {
                    try? await serve(server, on: DescriptorChannel(input: connection, output: connection))
                    systemClose(connection)
                }
            }
        }
    }

    static func serve(_ server: any IsomerServer, on channel: DescriptorChannel) async throws {
        var messages = channel.messages().makeAsyncIterator()
        guard let first = try await messages.next(), let header = try? Wire_CallHeader(serializedBytes: first) else {
            throw IsomerCallError(.invalidArgument, "a call opens with its header")
        }
        guard let method = IsomerMethod(rawValue: header.method) else {
            throw IsomerCallError(.unimplemented, "no method \(header.method)")
        }
        let inbound = IsomerInbound<[UInt8]> { continuation in
            let task = Task {
                do {
                    while let message = try await messages.next() { continuation.yield(message) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        try await server.serve(method, inbound, IsomerOutbound { try channel.write($0) }, context: IsomerCallContext(metadata: header.metadata))
    }
}

private func systemConnect(_ socket: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    Darwin.connect(socket, address, length)
    #elseif canImport(Glibc)
    Glibc.connect(socket, address, length)
    #else
    Musl.connect(socket, address, length)
    #endif
}

private func systemListen(_ socket: Int32, _ backlog: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.listen(socket, backlog)
    #elseif canImport(Glibc)
    Glibc.listen(socket, backlog)
    #else
    Musl.listen(socket, backlog)
    #endif
}

/// An app reached through a Unix socket it listens on, or started for each
/// call with the call on its standard input and output.
public struct IsomerProcessConnection: IsomerConnection {
    public enum Endpoint: Sendable {
        case unixSocket(String)
        /// An executable started for each call (an app built headless:
        /// `ISO_HEADLESS_PROTOCOL=binary` has it serve the call on its
        /// standard input and output).
        case executable(String, arguments: [String], environment: [String: String])
    }

    public let endpoint: Endpoint

    public init(_ endpoint: Endpoint) {
        self.endpoint = endpoint
    }

    public func open(_ method: IsomerMethod, context: IsomerCallContext) async throws -> IsomerCall<[UInt8], [UInt8]> {
        var header = Wire_CallHeader()
        header.method = method.rawValue
        header.metadata = context.metadata
        switch endpoint {
        case .unixSocket(let path):
            let descriptor = streamSocket()
            guard descriptor >= 0 else { throw IsomerCallError(.unavailable, "no socket: errno \(errno)") }
            let connected = try withSocketAddress(path) { systemConnect(descriptor, $0, $1) }
            guard connected == 0 else {
                systemClose(descriptor)
                throw IsomerCallError(.unavailable, "nothing listens at \(path)")
            }
            let channel = DescriptorChannel(input: descriptor, output: descriptor)
            try channel.write(try header.serializedBytes())
            return IsomerCall(
                outbound: IsomerOutbound { try channel.write($0) },
                inbound: channel.messages(),
                finish: { shutdown(descriptor, Int32(SHUT_WR)) }
            )
        case .executable(let path, let arguments, let environment):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            var launch = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            launch.merge(context.environment) { $1 }
            launch["ISO_HEADLESS_PROTOCOL"] = "binary"
            process.environment = launch
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            let channel = DescriptorChannel(
                input: output.fileHandleForReading.fileDescriptor,
                output: input.fileHandleForWriting.fileDescriptor
            )
            try channel.write(try header.serializedBytes())
            let writer = input.fileHandleForWriting
            return IsomerCall(
                outbound: IsomerOutbound { try channel.write($0) },
                inbound: channel.messages(),
                finish: {
                    // The app ends when its input does; one that hasn't a few
                    // seconds later is stopped. Nothing waits for it here: a
                    // test's synchronous call may be holding the thread that
                    // would see it go.
                    try? writer.close()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                        if process.isRunning { process.terminate() }
                    }
                }
            )
        }
    }
}

#endif
