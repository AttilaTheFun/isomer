// The wasm probe: GRPCCore + the generated greeter stubs + the IN-PROCESS
// transport (no sockets — WASI-legal). Proves the shared-logic layer (stubs,
// service impls, client code) is platform-portable; only the wire transport
// is platform-specific (NIO on host/iOS/Android, host-bridged on wasm/web).
import Foundation
import GRPCCore
import GRPCInProcessTransport
import GreeterProto
import GreeterServiceClient
import GreeterServiceServer

// grpc-swift-2 is macOS 15+. The examples module builds at macOS 15 today,
// so this gate always passes; it stays so the greeter keeps compiling if the
// module's floor is ever lowered.
@available(macOS 15, *)
struct Greeter: GreeterServiceServer.Iso_Example_Greeter.SimpleServiceProtocol {
    func greet(
        request: Iso_Example_GreetingRequest,
        context: ServerContext
    ) async throws -> Iso_Example_GreetingResponse {
        return Iso_Example_GreetingResponse.with {
            $0.message = "Hey \(request.name)!"
            $0.sequence = 1
            $0.tags = ["grpc-swift-2", "in-process"]
        }
    }
}

@main
struct InProcessGreeter {
    static func main() async throws {
        guard #available(macOS 15, *) else {
            print("greeter-inprocess: needs macOS 15")
            return
        }
        try await Runner.run()
    }
}

@available(macOS 15, *)
enum Runner {
    static func run() async throws {
        let transport = InProcessTransport()
        try await withThrowingTaskGroup(of: Void.self) { group in
            let server = GRPCServer(transport: transport.server, services: [Greeter()])
            group.addTask { try await server.serve() }
            try await withGRPCClient(transport: transport.client) { client in
                let greeter = GreeterServiceClient.Iso_Example_Greeter.Client(wrapping: client)
                var request = Iso_Example_GreetingRequest()
                request.name = "Isomer"
                request.mood = .cheerful
                let response = try await greeter.greet(request)
                print("greeter-inprocess: \(response.message) [seq=\(response.sequence) tags=\(response.tags.joined(separator: ","))]")
            }
            group.cancelAll()
        }
    }
}
