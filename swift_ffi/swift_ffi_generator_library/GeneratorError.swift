/// A whole-module validation failure, phrased for the person who wrote the
/// exported declaration.
public struct GeneratorError: Error, CustomStringConvertible {
    public let description: String

    public init(_ message: String) {
        self.description = message
    }
}
