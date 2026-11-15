// A prebuilt library's module (PrebuiltGreeter), built with library
// evolution so that its interface ships as text (.swiftinterface). It uses
// Isomer's Foundation inside its functions only: the import is `internal`,
// nothing of Foundation's is in its interface, and so importing a module
// built without library evolution (all of Isomer's are) doesn't warn.
internal import Foundation

/// A greeting for `name`, dated by Foundation (Date, ISO8601DateFormatter,
/// JSONEncoder): the archive's code calls into Isomer's Foundation.
public func greeting(for name: String, secondsSince1970 seconds: Double) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")
    let stamp = formatter.string(from: Date(timeIntervalSince1970: seconds))
    let encoded = (try? JSONEncoder().encode([name])).map { $0.count } ?? 0
    return "Hello, \(name) (\(encoded) bytes of JSON) at \(stamp)"
}

/// A type of the library's own, resilient to the app that imports it.
public struct Greeter: Sendable {
    public var name: String

    public init(name: String) {
        self.name = name
    }

    public func greet() -> String {
        greeting(for: name, secondsSince1970: 0)
    }
}
