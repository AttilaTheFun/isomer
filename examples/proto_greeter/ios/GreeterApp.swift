// The iOS-compiled form of the SwiftProtobuf greeter: the same GreeterProto
// module (swift_proto_library + RSPM SwiftProtobuf), round-tripped at launch
// and shown on screen + printed for the console check.
import SwiftUI
import GreeterProto

@main
struct GreeterApp: App {
    var body: some Scene {
        WindowGroup { Text(Self.greet()).padding() }
    }

    static func greet() -> String {
        do {
            var request = Iso_Example_GreetingRequest()
            request.name = "Isomer"
            request.mood = .cheerful
            let wire: Data = try request.serializedBytes()
            let parsed = try Iso_Example_GreetingRequest(serializedBytes: wire)
            var response = Iso_Example_GreetingResponse()
            response.message = "Hey \(parsed.name)!"
            response.sequence = 1
            response.tags = ["swift-protobuf", "ios-compiled"]
            let out: Data = try response.serializedBytes()
            let line = "greeter: \(response.message) [seq=\(response.sequence) tags=\(response.tags.joined(separator: ","))] request=\(wire.count)B response=\(out.count)B"
            print(line)
            return line
        } catch {
            let line = "greeter FAILED: \(error)"
            print(line)
            return line
        }
    }
}
