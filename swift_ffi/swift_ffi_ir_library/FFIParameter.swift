/// A single bridged parameter: its argument label (`_` when unlabeled) and its
/// bridgeable type name (a scalar, `String`, an exported interface/struct
/// name, a generic parameter name, a `Result<...>` spelling, or a closure).
public struct FFIParameter: Codable, Equatable {
    public var label: String
    public var type: String
    /// Set when the parameter is a closure; `type` keeps the source spelling.
    public var closure: FFIClosureType?
    /// Set when the parameter is a `Result<S, E>` value; the canonical
    /// success type name.
    public var resultSuccess: String?

    public init(
        label: String,
        type: String,
        closure: FFIClosureType? = nil,
        resultSuccess: String? = nil
    ) {
        self.label = label
        self.type = type
        self.closure = closure
        self.resultSuccess = resultSuccess
    }
}
