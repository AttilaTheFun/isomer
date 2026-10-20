import SwiftSyntax
import SwiftSyntaxMacros

// The per-declaration signature model the ABI-emitting macros share. Macros
// expand one declaration at a time and cannot see the rest of the module, so
// every classification here is SYNTACTIC:
//
//   * scalars / String / [UInt8] / Result<...> / Lazy<...> by spelling;
//   * `any P` existentials are interfaces (Swift 6 requires the `any`
//     spelling for protocol-typed values, so this is compiler-enforced);
//   * the function's own generic parameter names are generic;
//   * any other bare identifier is a `Bridgeable` VALUE type (an
//     @ExportedStruct / @ExportedEnum / consumer conformance) and crosses as
//     a blob — if the type does not actually conform, the expansion fails to
//     compile with a clear "does not conform to 'Bridgeable'" diagnostic.

/// One bridged value position (parameter, closure element, method argument,
/// or return).
enum ABIValueKind: Equatable {
    /// Int, Int32, Double, or Bool — crosses directly over the flat C ABI.
    case scalar(String)
    /// String: UTF-8 (ptr, len) in; +1 box out.
    case string
    /// [UInt8]: raw (ptr, len) in; +1 box out.
    case bytes
    /// `any P`: an interface — dual slot in, +1 box handle out.
    case interface(String)
    /// A generic parameter of the enclosing function: erased blob.
    case generic(String)
    /// Any other value type (@ExportedStruct / @ExportedEnum / Result<...> /
    /// a consumer Bridgeable conformance): erased blob.
    case blob
    /// Void (returns only).
    case void
}

struct ABIValue: Equatable {
    var kind: ABIValueKind
    /// The Swift spelling used to CONSTRUCT the value in generated code
    /// (`any ` stripped for interfaces; `Result<T, Error>` normalized to
    /// `Result<T, any Error>`).
    var spelling: String

    /// True when the value crosses as an erased (ptr, len) blob.
    var isBlobLike: Bool {
        switch kind {
        case .generic, .blob: return true
        default: return false
        }
    }
}

struct ABIClosure: Equatable {
    var parameters: [ABIValue]
    var returnValue: ABIValue
}

struct ABIParameter {
    /// The external argument label ("_" when unlabeled).
    var label: String
    var value: ABIValue
    var closure: ABIClosure?

    /// The argument expression for calling the original declaration.
    func callArgument(_ valueExpr: String) -> String {
        label == "_" ? valueExpr : "\(label): \(valueExpr)"
    }
}

struct ABIFunction {
    var name: String
    var parameters: [ABIParameter]
    /// The effective return value (`Result<T, E>` returns record `T` with
    /// `isThrowing`; `Lazy<T>` returns record `T` with `returnsLazy`).
    var returnValue: ABIValue
    var isAsync: Bool
    var isThrowing: Bool
    /// `-> Result<T, E>`: unwrap via `.get()` instead of `try`.
    var wrapsResult: Bool
    var returnsLazy: Bool
    var genericParameters: [String]

    /// The call into the original declaration, honoring argument labels and
    /// effects. `base` is e.g. `greeting` or `value.label`.
    func call(_ base: String, values: [String]) -> String {
        var expression = "\(base)(\(zip(parameters, values).map { $0.callArgument($1) }.joined(separator: ", ")))"
        if wrapsResult { expression += ".get()" }
        if isAsync { expression = "await \(expression)" }
        if isThrowing { expression = "try \(expression)" }
        return expression
    }
}

enum ABIModel {
    /// The `namespace:` string-literal argument of an exported macro, if any.
    /// Validated as a lowercase C-identifier segment.
    static func namespaceArgument(of node: AttributeSyntax) throws -> String? {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
            let first = arguments.first(where: { $0.label?.text == "namespace" })
        else { return nil }
        guard let literal = first.expression.as(StringLiteralExprSyntax.self),
            literal.segments.count == 1,
            let segment = literal.segments.first?.as(StringSegmentSyntax.self)
        else {
            throw MacroError("`namespace:` must be a literal string.")
        }
        let namespace = segment.content.text
        guard !namespace.isEmpty,
            namespace.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "_" }),
            namespace.first?.isNumber != true
        else {
            throw MacroError(
                "namespace '\(namespace)' must be a lowercase C-identifier segment "
                    + "([a-z_][a-z0-9_]*).")
        }
        return namespace
    }

    /// The C symbol for one export: `swift_ffi_[<ns>_]<name>`.
    static func cSymbol(namespace: String?, _ name: String) -> String {
        "swift_ffi_\(namespace.map { "\($0)_" } ?? "")\(name)"
    }

    /// Classifies one bridged value position.
    static func value(
        of type: TypeSyntax, generics: Set<String>, context: String
    ) throws -> ABIValue {
        let stripped = BridgeTypes.strippedType(type)
        let text = stripped.trimmedDescription
        if text.hasPrefix("any ") {
            let name = String(text.dropFirst(4))
            guard BridgeTypes.isPossibleInterfaceName(name) else {
                throw MacroError("\(context): unsupported existential '\(text)'.")
            }
            return ABIValue(kind: .interface(name), spelling: name)
        }
        if text.hasPrefix("some ") {
            throw MacroError("\(context): opaque `some` types cannot cross the bridge.")
        }
        switch text {
        case "Int", "Int32", "Double", "Bool":
            return ABIValue(kind: .scalar(text), spelling: text)
        case "String":
            return ABIValue(kind: .string, spelling: text)
        case "[UInt8]":
            return ABIValue(kind: .bytes, spelling: text)
        case "Void", "()":
            return ABIValue(kind: .void, spelling: "Void")
        default:
            break
        }
        if generics.contains(text) {
            return ABIValue(kind: .generic(text), spelling: text)
        }
        if BridgeTypes.resultSuccessType(stripped) != nil {
            return ABIValue(kind: .blob, spelling: swiftSpelling(text))
        }
        // Arrays of bridgeable scalars/strings (`[String]`, `[Int]`, …) cross
        // as LIST blobs (Array+Bridgeable) — erased-position values.
        if text.hasPrefix("["), text.hasSuffix("]"), !text.contains(":") {
            var element = Substring(text.dropFirst().dropLast())
            while element.first == " " { element = element.dropFirst() }
            while element.last == " " { element = element.dropLast() }
            if ["Int", "Int32", "Double", "Bool", "String"].contains(String(element)) {
                return ABIValue(kind: .blob, spelling: text)
            }
        }
        guard BridgeTypes.isPossibleInterfaceName(text) else {
            throw MacroError(
                "\(context) has unbridgeable type '\(text)'. "
                    + "Supported: \(BridgeTypes.supportedTypesDescription).")
        }
        // A bare identifier: an @ExportedStruct / @ExportedEnum / consumer
        // Bridgeable value type. (A protocol here would be a Swift 6 error
        // already — existentials must be spelled `any P`.)
        return ABIValue(kind: .blob, spelling: text)
    }

    /// The Swift spelling used to construct a bridged value of a declared
    /// type (`Result<T, Error>` needs `any Error` in generated code).
    static func swiftSpelling(_ type: String) -> String {
        String(
            String(type.replacing(", Error>", with: ", any Error>"))
                .replacing(",Error>", with: ", any Error>"))
    }

    /// Parses one function/method declaration into the ABI model.
    static func function(
        _ function: FunctionDeclSyntax, context: String, allowEffects: Bool = true
    ) throws -> ABIFunction {
        let name = function.name.text
        let generics = try BridgeTypes.bridgeableGenericParameters(of: function, context: context)
        let genericNames = function.genericParameterClause.map { $0.parameters.map(\.name.text) } ?? []

        var parameters: [ABIParameter] = []
        for parameter in function.signature.parameterClause.parameters {
            let label = parameter.firstName.text
            let parameterContext = "\(context) parameter '\(label)'"
            if let closureSyntax = BridgeTypes.closureType(parameter.type) {
                var elements: [ABIValue] = []
                for element in closureSyntax.parameters {
                    let value = try value(
                        of: element.type, generics: generics,
                        context: "\(parameterContext) closure parameter")
                    guard !value.isInterfaceOrClosureBanned else {
                        throw MacroError(
                            "\(parameterContext): closure parameters must be value types "
                                + "(no interfaces or nested closures).")
                    }
                    elements.append(value)
                }
                let returnValue: ABIValue
                if let returnType = closureSyntax.returnClause.type as TypeSyntax?,
                    !BridgeTypes.isVoid(BridgeTypes.typeName(returnType)) {
                    returnValue = try value(
                        of: returnType, generics: generics,
                        context: "\(parameterContext) closure return")
                    guard !returnValue.isInterfaceOrClosureBanned else {
                        throw MacroError(
                            "\(parameterContext): closure returns must be value types.")
                    }
                } else {
                    returnValue = ABIValue(kind: .void, spelling: "Void")
                }
                parameters.append(
                    ABIParameter(
                        label: label,
                        value: ABIValue(kind: .blob, spelling: parameter.type.trimmedDescription),
                        closure: ABIClosure(parameters: elements, returnValue: returnValue)))
                continue
            }
            let value = try value(of: parameter.type, generics: generics, context: parameterContext)
            if case .void = value.kind {
                throw MacroError("\(parameterContext) may not be Void.")
            }
            parameters.append(ABIParameter(label: label, value: value))
        }

        let isAsync = function.signature.effectSpecifiers?.asyncSpecifier != nil
        var isThrowing = function.signature.effectSpecifiers?.throwsClause != nil
        var wrapsResult = false
        var returnsLazy = false
        var returnValue = ABIValue(kind: .void, spelling: "Void")
        if let returnType = function.signature.returnClause?.type {
            if let success = BridgeTypes.resultSuccessType(returnType) {
                wrapsResult = true
                isThrowing = true
                returnValue = try value(
                    of: success, generics: generics, context: "\(context) Result success")
            } else if let payload = BridgeTypes.lazySuccessType(returnType) {
                returnsLazy = true
                returnValue = try value(
                    of: payload, generics: generics, context: "\(context) Lazy payload")
            } else if !BridgeTypes.isVoid(BridgeTypes.typeName(returnType)) {
                returnValue = try value(of: returnType, generics: generics, context: "\(context) return")
            }
        }
        if !allowEffects, isAsync || isThrowing {
            throw MacroError(
                "\(context) may not be async or throwing (only exported free functions "
                    + "bridge effects).")
        }

        return ABIFunction(
            name: name,
            parameters: parameters,
            returnValue: returnValue,
            isAsync: isAsync,
            isThrowing: isThrowing,
            wrapsResult: wrapsResult,
            returnsLazy: returnsLazy,
            genericParameters: genericNames)
    }
}

extension ABIValue {
    /// Interfaces and closures are banned inside closures / Lazy payloads.
    var isInterfaceOrClosureBanned: Bool {
        if case .interface = kind { return true }
        return false
    }

    /// The blob-encode expression for `expr` of this (value) type.
    func encodeExpr(_ expr: String) -> String {
        if case .interface(let name) = kind {
            // A +1 box handle: the receiving wrapper takes ownership.
            return "IsomerFFI.SwiftFFIBlob.encode(.handle(bits: UInt64(UInt(bitPattern: Int(bitPattern: Unmanaged.passRetained(SwiftFFIBox_\(name)(\(expr))).toOpaque()))), interface: \"\(name)\"))"
        }
        return "IsomerFFI.SwiftFFIBlob.encode((\(expr)).bridgeValue)"
    }

    /// The decode-and-construct expression from a `IsomerFFI.BridgeValue`.
    /// THROWS — the call site spells `try` / `try!`.
    func decodeValueExpr(_ valueExpr: String) -> String {
        if case .interface(let name) = kind {
            return "swiftFFIResolve_\(name)(\(valueExpr))"
        }
        return "\(ABIModel.swiftSpelling(spelling))(bridgeValue: \(valueExpr))"
    }

    /// The decode-and-construct expression from a `[UInt8]` blob.
    /// THROWS — the call site spells `try` / `try!`.
    func decodeBytesExpr(_ bytesExpr: String) -> String {
        decodeValueExpr("IsomerFFI.SwiftFFIBlob.decode(\(bytesExpr))")
    }
}
