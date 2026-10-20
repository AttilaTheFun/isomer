/// An exported enum: a String- or Int-raw-valued Swift enum copied by raw
/// value at the boundary (a Kotlin enum class, a TypeScript union, a C++
/// enum class / string constants). Usable as dictionary keys in the wasm
/// dependency-injection story.
public struct FFIEnum: Codable, Equatable {
    /// "String" or "Int".
    public var rawType: String
    public var name: String
    public var cases: [FFIEnumCase]

    public init(name: String, rawType: String, cases: [FFIEnumCase]) {
        self.name = name
        self.rawType = rawType
        self.cases = cases
    }
}

/// One case of an exported enum: its Swift name and its raw value spelling
/// (the literal text: `"foo"` for String-raw, `3` for Int-raw; empty when
/// implicit).
public struct FFIEnumCase: Codable, Equatable {
    public var name: String
    public var rawValue: String

    public init(name: String, rawValue: String = "") {
        self.name = name
        self.rawValue = rawValue
    }
}
