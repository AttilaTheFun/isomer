// The shader translator's syntax tree: the subset of the Metal Shading
// Language it reads (structs, functions with their stage and attributes,
// constant globals and constexpr samplers, C-like statements and
// expressions).

/// A type as written: a name, its template arguments (`texture2d<float,
/// access::read>`), and the qualifiers in front of it.
public struct MSLTypeSpec: Hashable, Sendable, CustomStringConvertible {
    public var name: String
    public var templateArguments: [String] = []
    public var isConst = false
    /// `constant`, `device`, `thread`, `threadgroup`, when written.
    public var addressSpace: String?

    public var description: String {
        templateArguments.isEmpty ? name : "\(name)<\(templateArguments.joined(separator: ", "))>"
    }
}

/// `[[name(arguments)]]`.
public struct MSLAttribute: Hashable, Sendable {
    public var name: String
    public var arguments: [String]

    var integerArgument: Int? { arguments.first.flatMap { Int($0) } }
}

public struct MSLStructField: Sendable {
    public var type: MSLTypeSpec
    public var name: String
    public var arraySize: MSLExpr?
    public var attributes: [MSLAttribute]
    public var location: MSLSourceLocation
}

public struct MSLStruct: Sendable {
    public var name: String
    public var fields: [MSLStructField]
    public var location: MSLSourceLocation
}

public struct MSLParameter: Sendable {
    public var type: MSLTypeSpec
    public var isReference: Bool
    public var isPointer: Bool
    public var name: String
    public var arraySize: MSLExpr?
    public var attributes: [MSLAttribute]
    public var location: MSLSourceLocation
}

public enum MSLStage: String, Sendable {
    case vertex
    case fragment
    case kernel
}

public struct MSLFunction: Sendable {
    public var stage: MSLStage?
    public var returnType: MSLTypeSpec
    public var name: String
    public var parameters: [MSLParameter]
    public var body: [MSLStmt]
    public var attributes: [MSLAttribute]
    public var location: MSLSourceLocation
}

public struct MSLVarDecl: Sendable {
    public var type: MSLTypeSpec
    public var name: String
    public var arraySize: MSLExpr?
    /// `[N]` with the size left to the initializer list.
    public var arrayUnsized = false
    public var initializer: MSLExpr?
    /// `constexpr sampler s(filter::linear, …)`: the constructor arguments.
    public var constructorArguments: [MSLExpr]?
    public var isConstexpr = false
    /// `device Particle &p = particles[i];`: another name for the storage.
    public var isReference = false
    public var location: MSLSourceLocation
}

public indirect enum MSLExprKind: Sendable {
    case integer(String)
    case float(String)
    case bool(Bool)
    case identifier(String)
    /// `metal::max`, `access::read`, `filter::linear`.
    case qualified([String])
    case member(MSLExpr, String)
    case index(MSLExpr, MSLExpr)
    case call(MSLExpr, [MSLExpr])
    /// `float4(…)`, `Foo{…}`, `(float)x`.
    case construct(MSLTypeSpec, [MSLExpr], braces: Bool)
    case initializerList([MSLExpr])
    case unary(String, MSLExpr)
    case postfix(String, MSLExpr)
    case binary(String, MSLExpr, MSLExpr)
    case assign(String, MSLExpr, MSLExpr)
    case ternary(MSLExpr, MSLExpr, MSLExpr)
    /// `as_type<T>(x)`, `static_cast<T>(x)` and the like.
    case templateCall(String, [MSLTypeSpec], [MSLExpr])
}

public struct MSLExpr: Sendable {
    public var kind: MSLExprKind
    public var location: MSLSourceLocation
}

public indirect enum MSLStmt: Sendable {
    case block([MSLStmt])
    case declaration([MSLVarDecl])
    case expression(MSLExpr)
    case ifStmt(MSLExpr, MSLStmt, MSLStmt?)
    case forStmt(MSLStmt?, MSLExpr?, MSLExpr?, MSLStmt)
    case whileStmt(MSLExpr, MSLStmt)
    case doWhile(MSLStmt, MSLExpr)
    case switchStmt(MSLExpr, [MSLSwitchCase])
    case returnStmt(MSLExpr?, MSLSourceLocation)
    case breakStmt
    case continueStmt
    case discard
    case empty
}

public struct MSLSwitchCase: Sendable {
    /// Nil for `default`.
    public var values: [MSLExpr]?
    public var body: [MSLStmt]
}

public struct MSLTranslationUnit: Sendable {
    public var structs: [MSLStruct] = []
    public var functions: [MSLFunction] = []
    public var globals: [MSLVarDecl] = []
    /// `typedef`/`using` aliases: name to the aliased type.
    public var typeAliases: [String: MSLTypeSpec] = [:]
}
