// IsomerRemote: an Isomer app's services reached by URL, whatever carries
// them (the CLI's and the tests' one way in):
//
//   grpc://host:port[/target]    gRPC Swift 2 over HTTP/2 (plaintext)
//   grpcs://host:port[/target]   the same over TLS
//   ws://host:port[/base]        WebSockets (clients without gRPC)
//   unix:/path/to/socket         a Unix socket on this machine
//   exec:/path/to/app            an app built headless, started for each call
//
// `?target=<name>` (or grpc's path) names an app attached to a hub: a headful
// app that dialled out (session_service.proto's Driver.Attach).

import Foundation
import IsomerGRPCTransport
import IsomerProcessTransport
import IsomerServing
import IsomerWebSocketTransport

public enum IsomerRemote {
    /// What a URL names: its connection, and the metadata its calls carry.
    public struct Endpoint: Sendable {
        public let connection: any IsomerConnection
        public let metadata: [String: String]

        /// A call's context: the endpoint's metadata, the token, and more.
        public func context(token: String?, metadata extra: [String: String] = [:]) -> IsomerCallContext {
            IsomerCallContext.authorized(token, metadata: metadata.merging(extra) { $1 })
        }
    }

    public static func endpoint(_ url: String) throws -> Endpoint {
        #if os(Windows) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        if url.hasPrefix("unix:") || url.hasPrefix("exec:") {
            throw IsomerCallError(.unimplemented, "no unix: or exec: transport here (grpc, grpcs or ws)")
        }
        #else
        if url.hasPrefix("unix:") {
            return Endpoint(connection: IsomerProcessConnection(.unixSocket(String(url.dropFirst("unix:".count)))), metadata: [:])
        }
        if url.hasPrefix("exec:") {
            var parts = String(url.dropFirst("exec:".count)).split(separator: " ").map(String.init)
            guard !parts.isEmpty else { throw IsomerCallError(.invalidArgument, "exec: names no app") }
            let path = parts.removeFirst()
            return Endpoint(connection: IsomerProcessConnection(.executable(path, arguments: parts, environment: [:])), metadata: [:])
        }
        #endif
        guard let components = URLComponents(string: url), let scheme = components.scheme, let host = components.host else {
            throw IsomerCallError(.invalidArgument, "not an app's URL: \(url)")
        }
        var metadata: [String: String] = [:]
        if let target = components.queryItems?.first(where: { $0.name == "target" })?.value { metadata["iso-target"] = target }
        switch scheme {
        case "grpc", "grpcs":
            guard #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) else {
                throw IsomerCallError(.unavailable, "gRPC needs macOS 15 or iOS 18: use the app's ws:// URL")
            }
            let target = components.path.split(separator: "/").first.map(String.init)
            if let target, !target.isEmpty { metadata["iso-target"] = target }
            let connection = try IsomerGRPCConnection(host: host, port: components.port ?? (scheme == "grpcs" ? 443 : 80), tls: scheme == "grpcs")
            return Endpoint(connection: connection, metadata: metadata)
        case "ws":
            guard #available(macOS 14, iOS 17, tvOS 17, watchOS 10, *) else {
                throw IsomerCallError(.unavailable, "this client's WebSocket transport needs macOS 14 or iOS 17")
            }
            var base = components.path
            while base.hasSuffix("/") { base.removeLast() }
            return Endpoint(connection: IsomerWebSocketConnection(host: host, port: components.port ?? 80, base: base), metadata: metadata)
        default:
            throw IsomerCallError(.invalidArgument, "no transport for \(scheme): (grpc, grpcs, ws, unix or exec)")
        }
    }
}
