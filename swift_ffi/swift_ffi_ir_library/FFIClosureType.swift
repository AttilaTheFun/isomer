/// The shape of a closure parameter: canonical element type names (scalars,
/// generic parameter names, `@ExportedStruct`s, `Result<...>` spellings) and
/// the return type (`Void` when absent). Closures cross the bridge as
/// single-method foreign objects; arguments travel erased (arity is static).
public struct FFIClosureType: Codable, Equatable {
    public var parameters: [String]
    public var returnType: String

    public init(parameters: [String], returnType: String) {
        self.parameters = parameters
        self.returnType = returnType
    }
}
