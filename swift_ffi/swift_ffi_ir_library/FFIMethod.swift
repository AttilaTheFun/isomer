/// A method of an exported interface.
public struct FFIMethod: Codable, Equatable {
    public var name: String
    public var parameters: [FFIParameter]
    public var returnType: String
    /// Effects on interface methods bridge like free functions: `throws`
    /// surfaces an ERROR blob, `async` completes later through the fixed
    /// `swift_ffi_async_resume` entry (host-implemented) or the
    /// `async_complete` import (Swift-owned instances on wasm).
    public var isAsync: Bool
    public var isThrowing: Bool

    public init(
        name: String, parameters: [FFIParameter], returnType: String,
        isAsync: Bool = false, isThrowing: Bool = false
    ) {
        self.name = name
        self.parameters = parameters
        self.returnType = returnType
        self.isAsync = isAsync
        self.isThrowing = isThrowing
    }

    private enum CodingKeys: String, CodingKey {
        case name, parameters, returnType, isAsync, isThrowing
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        parameters = try container.decode([FFIParameter].self, forKey: .parameters)
        returnType = try container.decode(String.self, forKey: .returnType)
        isAsync = try container.decodeIfPresent(Bool.self, forKey: .isAsync) ?? false
        isThrowing = try container.decodeIfPresent(Bool.self, forKey: .isThrowing) ?? false
    }
}
