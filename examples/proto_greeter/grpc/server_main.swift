// The gRPC Swift 2 greeter server: plaintext NIO HTTP/2 on localhost.
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GreeterProto
import GreeterServiceServer

@available(macOS 15, *)
struct Greeter: Iso_Example_Greeter.SimpleServiceProtocol {
    func greet(
        request: Iso_Example_GreetingRequest,
        context: ServerContext
    ) async throws -> Iso_Example_GreetingResponse {
        return Iso_Example_GreetingResponse.with {
            $0.message = request.mood == .cheerful ? "Hey \(request.name)!" : "Hello, \(request.name)."
            $0.sequence = 1
            $0.tags = ["grpc-swift-2", "nio-http2"]
        }
    }
}

// grpc-swift-2 is macOS 15+. The examples module builds at macOS 15 today,
// so this gate always passes; it stays so the greeter keeps compiling if the
// module's floor is ever lowered.
@main
struct GreeterServer {
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
        let server = GRPCServer(
            transport: .http2NIOPosix(
                address: .ipv4(host: "127.0.0.1", port: port),
                transportSecurity: .plaintext
            ),
            services: [Greeter()]
        )
        print("greeter-server: listening on 127.0.0.1:\(port)")
        try await server.serve()
    }
}
