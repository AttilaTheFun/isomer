/// An exported struct: a flat value type copied field-wise at the boundary
/// (a Kotlin data class, a TypeScript object).
public struct FFIStruct: Codable, Equatable {
    public var name: String
    public var fields: [FFIField]

    public init(name: String, fields: [FFIField]) {
        self.name = name
        self.fields = fields
    }
}
