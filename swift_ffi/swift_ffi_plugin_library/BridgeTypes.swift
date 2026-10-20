import SwiftSyntax

/// Namespace for the bridged-type vocabulary the macro validations share:
/// canonical type spelling, the bridgeability rules for parameters, returns,
/// and struct fields, and the bridge-v2 syntax classifiers (closures,
/// `Result`-as-value, `Lazy` returns, generic parameters).
public enum BridgeTypes {
    /// Normalizes a `TypeSyntax` to its trimmed source text (e.g. `Int`,
    /// `String`). Interface existentials canonicalize to the bare protocol
    /// name (`any Counter` → `Counter`), matching the analyzer's IR spelling.
    public static func typeName(_ type: TypeSyntax?) -> String {
        guard let type else { return "Void" }
        return canonicalTypeName(type.trimmedDescription)
    }

    /// The *success* type of a return: `Result<T, E>` validates as `T` (the
    /// bridge lowers it to the throwing convention).
    public static func returnTypeName(_ type: TypeSyntax?) -> String {
        guard let type else { return "Void" }
        if let success = resultSuccessType(type) {
            return canonicalTypeName(success.trimmedDescription)
        }
        return canonicalTypeName(type.trimmedDescription)
    }

    /// Strips an `any ` existential prefix from a bridged type's source text.
    public static func canonicalTypeName(_ text: String) -> String {
        text.hasPrefix("any ") ? String(text.dropFirst(4)) : text
    }

    public static func isVoid(_ name: String) -> Bool { name == "Void" || name == "()" }

    /// True when a type name could be an exported interface or struct: a plain
    /// capitalized identifier. The macro can only see one file, so these
    /// references are *permitted* here and validated for real by the
    /// whole-module analyzer.
    public static func isPossibleInterfaceName(_ name: String) -> Bool {
        guard let first = name.first, first.isUppercase else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    public static func isBridgeableParameter(_ name: String) -> Bool {
        BridgeValueType(typeName: name) != nil || isPossibleInterfaceName(name)
    }

    public static func isBridgeableReturn(_ name: String) -> Bool {
        isVoid(name) || isBridgeableParameter(name)
    }

    public static let supportedTypesDescription =
        BridgeValueType.allCases.map(\.rawValue).joined(separator: ", ")
        + ", or an @ExportedInterface protocol"

    // MARK: - Bridge-v2 syntax classifiers

    /// Unwraps attributes/specifiers (`@escaping`, `@Sendable`) around a type.
    public static func strippedType(_ type: TypeSyntax) -> TypeSyntax {
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return strippedType(attributed.baseType)
        }
        return type
    }

    /// The function type of a closure parameter, if the type is one.
    public static func closureType(_ type: TypeSyntax) -> FunctionTypeSyntax? {
        strippedType(type).as(FunctionTypeSyntax.self)
    }

    /// The single generic argument of a `Name<T>` spelling, if the type is one.
    public static func genericArgument(_ type: TypeSyntax, of name: String) -> TypeSyntax? {
        guard let identifier = strippedType(type).as(IdentifierTypeSyntax.self),
            identifier.name.text == name,
            let first = identifier.genericArgumentClause?.arguments.first,
            case .type(let argument) = first.argument
        else { return nil }
        return argument
    }

    /// The `T` of a `Result<T, E>` spelling, if the type is one.
    public static func resultSuccessType(_ type: TypeSyntax) -> TypeSyntax? {
        genericArgument(type, of: "Result")
    }

    /// The `T` of a `Lazy<T>` spelling, if the type is one.
    public static func lazySuccessType(_ type: TypeSyntax) -> TypeSyntax? {
        genericArgument(type, of: "Lazy")
    }

    /// The declared generic type-parameter names of a function, with their
    /// `Bridgeable` constraint validated: every parameter must be constrained
    /// to `Bridgeable` (or `IsomerFFI.Bridgeable`), either inline or in the
    /// `where` clause.
    public static func bridgeableGenericParameters(
        of function: FunctionDeclSyntax, context: String
    ) throws -> Set<String> {
        guard let clause = function.genericParameterClause else { return [] }
        var names: Set<String> = []
        var constrained: Set<String> = []
        for parameter in clause.parameters {
            names.insert(parameter.name.text)
            if let inherited = parameter.inheritedType, isBridgeableConstraint(inherited) {
                constrained.insert(parameter.name.text)
            }
        }
        if let requirements = function.genericWhereClause?.requirements {
            for requirement in requirements {
                if let conformance = requirement.requirement.as(
                    ConformanceRequirementSyntax.self),
                    isBridgeableConstraint(conformance.rightType),
                    let name = conformance.leftType.as(IdentifierTypeSyntax.self)?.name.text {
                    constrained.insert(name)
                }
            }
        }
        for name in names.sorted() where !constrained.contains(name) {
            throw MacroError(
                "\(context) generic parameter '\(name)' must be constrained to 'Bridgeable' "
                    + "(generic exports bridge by erasing to the Bridgeable vocabulary).")
        }
        return names
    }

    private static func isBridgeableConstraint(_ type: TypeSyntax) -> Bool {
        let name = type.trimmedDescription
        return name == "Bridgeable" || name == "IsomerFFI.Bridgeable"
    }

    /// Validates one bridged *value* type (recursively for `Result`), given
    /// the function's generic parameter names.
    ///
    /// - `allowClosure`: closures are only accepted where the caller says so
    ///   (direct parameters of exported functions — not inside closures or
    ///   `Result`).
    /// - `allowLazy`: `Lazy<T>` is only accepted in return position.
    public static func validateBridgeable(
        _ type: TypeSyntax,
        genericParameters: Set<String>,
        context: String,
        allowClosure: Bool = false,
        allowLazy: Bool = false
    ) throws {
        if let closure = closureType(type) {
            guard allowClosure else {
                throw MacroError("\(context): closures are only supported as direct parameters.")
            }
            for element in closure.parameters {
                try validateBridgeable(
                    element.type, genericParameters: genericParameters,
                    context: "\(context) closure parameter")
            }
            if !isVoid(typeName(closure.returnClause.type)) {
                try validateBridgeable(
                    closure.returnClause.type, genericParameters: genericParameters,
                    context: "\(context) closure return")
            }
            return
        }
        if let lazyInner = lazySuccessType(type) {
            guard allowLazy else {
                throw MacroError("\(context): Lazy<T> is only supported as a return type.")
            }
            try validateBridgeable(
                lazyInner, genericParameters: genericParameters,
                context: "\(context) Lazy payload")
            return
        }
        if let success = resultSuccessType(type) {
            try validateBridgeable(
                success, genericParameters: genericParameters,
                context: "\(context) Result success")
            return
        }
        let name = typeName(type)
        guard genericParameters.contains(name) || isBridgeableParameter(name) else {
            throw MacroError(
                "\(context) has unbridgeable type '\(name)'. "
                    + "Supported types: \(supportedTypesDescription).")
        }
    }
}
