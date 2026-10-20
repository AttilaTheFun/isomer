// The greeter: build a request, serialize it, parse it back, and answer —
// pure SwiftProtobuf round trips, identical source on every platform
// (macOS/iOS compiled, wasm32 for the web, Android).
import Foundation
import GreeterProto

func greet(_ requestBytes: Data) throws -> Data {
    let request = try Iso_Example_GreetingRequest(serializedBytes: requestBytes)
    var response = Iso_Example_GreetingResponse()
    switch request.mood {
    case .cheerful: response.message = "Hey \(request.name)!"
    case .formal: response.message = "Good day, \(request.name)."
    default: response.message = "Hello, \(request.name)."
    }
    response.sequence = 1
    response.tags = ["swift-protobuf", "cross-platform"]
    let out: Data = try response.serializedBytes()
    return out
}

var request = Iso_Example_GreetingRequest()
request.name = "Isomer"
request.mood = .cheerful

let wire: Data = try request.serializedBytes()
let responseWire = try greet(wire)
let response = try Iso_Example_GreetingResponse(serializedBytes: responseWire)
print("greeter: \(response.message) [seq=\(response.sequence) tags=\(response.tags.joined(separator: ","))] request=\(wire.count)B response=\(responseWire.count)B")
