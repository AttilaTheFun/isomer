/// An exported free function.
///
/// `returnType` is the *success* type: a `Result<T, E>`-returning function is
/// recorded as returning `T` with `isThrowing` set (the analyzer unwraps it),
/// so throwing functions and Result-returning functions bridge identically.
/// A `Lazy<T>`-returning function is recorded as returning `T` with
/// `returnsLazy` set (the value crosses as a deferred handle).
public struct FFIFunction: Codable, Equatable {
    public var name: String
    public var parameters: [FFIParameter]
    public var returnType: String
    public var isAsync: Bool
    /// Failable from the consumer's point of view (`throws` or `-> Result`).
    public var isThrowing: Bool
    /// The Swift declaration returns `Result` (the glue unwraps via `.get()`)
    /// rather than throwing directly.
    public var wrapsResult: Bool
    /// The declared generic type-parameter names (each `Bridgeable`-
    /// constrained; validated by the macro). Empty for concrete functions.
    public var genericParameters: [String]
    /// The declaration returns `Lazy<returnType>`.
    public var returnsLazy: Bool
    /// The C symbol namespace segment (`@ExportedFunction(namespace:)`):
    /// the export is `swift_ffi_[<namespace>_]<name>`.
    public var namespace: String?

    public init(
        name: String,
        parameters: [FFIParameter],
        returnType: String,
        isAsync: Bool = false,
        isThrowing: Bool = false,
        wrapsResult: Bool = false,
        genericParameters: [String] = [],
        returnsLazy: Bool = false,
        namespace: String? = nil
    ) {
        self.name = name
        self.parameters = parameters
        self.returnType = returnType
        self.isAsync = isAsync
        self.isThrowing = isThrowing
        self.wrapsResult = wrapsResult
        self.genericParameters = genericParameters
        self.returnsLazy = returnsLazy
        self.namespace = namespace
    }

    /// Backward-compatible decoding: IR written before the bridge-v2 fields
    /// existed simply lacks the keys.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        parameters = try container.decode([FFIParameter].self, forKey: .parameters)
        returnType = try container.decode(String.self, forKey: .returnType)
        isAsync = try container.decodeIfPresent(Bool.self, forKey: .isAsync) ?? false
        isThrowing = try container.decodeIfPresent(Bool.self, forKey: .isThrowing) ?? false
        wrapsResult = try container.decodeIfPresent(Bool.self, forKey: .wrapsResult) ?? false
        genericParameters =
            try container.decodeIfPresent([String].self, forKey: .genericParameters) ?? []
        returnsLazy = try container.decodeIfPresent(Bool.self, forKey: .returnsLazy) ?? false
        namespace = try container.decodeIfPresent(String.self, forKey: .namespace)
    }
}
