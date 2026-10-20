// The gRPC Swift 2 greeter client: one unary call over localhost HTTP/2.
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GreeterProto
import GreeterServiceClient

// grpc-swift-2 is macOS 15+. The examples module builds at macOS 15 today,
// so this gate always passes; it stays so the greeter keeps compiling if the
// module's floor is ever lowered.
@main
struct GreeterClient {
    static func main() async throws {
        guard #available(macOS 15, *) else {
            print("greeter: needs macOS 15")
            return
        }
        try await Runner.run()
    }
}

@available(macOS 15, *)
enum Runner {
    static func run() async throws {
        let port = Int(ProcessInfo.processInfo.environment["GREETER_PORT"] ?? "9040") ?? 9040
        try await withGRPCClient(
            transport: .http2NIOPosix(
                target: .ipv4(host: "127.0.0.1", port: port),
                transportSecurity: .plaintext
            )
        ) { client in
            let greeter = Iso_Example_Greeter.Client(wrapping: client)
            var request = Iso_Example_GreetingRequest()
            request.name = "Isomer"
            request.mood = .cheerful
            let response = try await greeter.greet(request)
            print("greeter-client: \(response.message) [seq=\(response.sequence) tags=\(response.tags.joined(separator: ","))]")
        }
    }
}
