/// A lightweight `Error` carrying a human-readable macro diagnostic message.
public struct MacroError: Error, CustomStringConvertible {
    public let description: String

    public init(_ message: String) {
        self.description = message
    }
}
