import SwiftFFIIRLibrary
import SwiftSyntax

/// Walks a parsed source file and collects the exported surface.
final class ExportCollector: SyntaxVisitor {
    /// The names of the swift_ffi marker attributes the collector keys on.
    private enum ExportAttribute: String {
        case function = "ExportedFunction"
        case interface = "ExportedInterface"
        case structure = "ExportedStruct"
        case enumeration = "ExportedEnum"
    }

    var module = FFIModule()

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if exportAttribute(on: node.attributes) == .function {
            let (returnType, isThrowing, wrapsResult, returnsLazy) =
                effectiveReturn(of: node.signature)
            module.functions.append(
                FFIFunction(
                    name: node.name.text,
                    parameters: parameters(of: node.signature.parameterClause),
                    returnType: returnType,
                    isAsync: node.signature.effectSpecifiers?.asyncSpecifier != nil,
                    isThrowing: isThrowing,
                    wrapsResult: wrapsResult,
                    genericParameters: node.genericParameterClause.map {
                        $0.parameters.map(\.name.text)
                    } ?? [],
                    returnsLazy: returnsLazy,
                    namespace: namespaceArgument(on: node.attributes)
                ))
        }
        return .skipChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        guard exportAttribute(on: node.attributes) == .structure else { return .skipChildren }
        var fields: [FFIField] = []
        for member in node.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in variable.bindings {
                // Stored properties only: a binding with a type annotation and
                // no accessor block.
                guard binding.accessorBlock == nil,
                    let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                    let type = binding.typeAnnotation?.type.trimmedDescription
                else { continue }
                fields.append(FFIField(name: name, type: type))
            }
        }
        module.structs.append(FFIStruct(name: node.name.text, fields: fields))
        return .skipChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        guard exportAttribute(on: node.attributes) == .enumeration else { return .skipChildren }
        let inherited = node.inheritanceClause?.inheritedTypes.compactMap {
            $0.type.trimmedDescription
        } ?? []
        let rawType = inherited.first(where: { $0 == "String" || $0 == "Int" }) ?? "String"
        var cases: [FFIEnumCase] = []
        for member in node.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                cases.append(
                    FFIEnumCase(
                        name: element.name.text,
                        rawValue: element.rawValue?.value.trimmedDescription ?? ""
                    ))
            }
        }
        module.enums.append(FFIEnum(name: node.name.text, rawType: rawType, cases: cases))
        return .skipChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        guard exportAttribute(on: node.attributes) == .interface else { return .skipChildren }
        var methods: [FFIMethod] = []
        for member in node.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else { continue }
            methods.append(
                FFIMethod(
                    name: function.name.text,
                    parameters: parameters(of: function.signature.parameterClause),
                    returnType: returnType(of: function.signature),
                    isAsync: function.signature.effectSpecifiers?.asyncSpecifier != nil,
                    isThrowing: function.signature.effectSpecifiers?.throwsClause != nil
                ))
        }
        module.interfaces.append(
            FFIInterface(
                name: node.name.text,
                methods: methods,
                namespace: namespaceArgument(on: node.attributes)
            ))
        return .skipChildren
    }

    // MARK: - Extraction

    /// Returns the export attribute applied to a declaration, if any.
    private func exportAttribute(on attributes: AttributeListSyntax) -> ExportAttribute? {
        for attribute in attributes {
            guard let attribute = attribute.as(AttributeSyntax.self) else { continue }
            if let kind = ExportAttribute(rawValue: attribute.attributeName.trimmedDescription) {
                return kind
            }
        }
        return nil
    }

    /// The `namespace:` string literal of an exported attribute, if present —
    /// the same per-declaration segment the macro bakes into its `@c` symbol
    /// names, so the consumer generators agree with the expansion exactly.
    private func namespaceArgument(on attributes: AttributeListSyntax) -> String? {
        for attribute in attributes {
            guard let attribute = attribute.as(AttributeSyntax.self),
                let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
                let first = arguments.first(where: { $0.label?.text == "namespace" }),
                let literal = first.expression.as(StringLiteralExprSyntax.self),
                let segment = literal.segments.first?.as(StringSegmentSyntax.self)
            else { continue }
            return segment.content.text
        }
        return nil
    }

    /// Canonicalizes a bridged type's source text for the IR: interface
    /// existentials are recorded by bare protocol name (`any Counter` →
    /// `Counter`), so generators match interfaces without caring how the
    /// source spells the existential.
    private func canonicalType(_ text: String) -> String {
        text.hasPrefix("any ") ? String(text.dropFirst(4)) : text
    }

    /// Unwraps attributes/specifiers (`@escaping`, `@Sendable`) around a type.
    private func strippedType(_ type: TypeSyntax) -> TypeSyntax {
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return strippedType(attributed.baseType)
        }
        return type
    }

    /// The single generic argument of a `Name<T, ...>` spelling, if the type
    /// is one.
    private func genericArgument(_ type: TypeSyntax, of name: String) -> TypeSyntax? {
        guard let identifier = strippedType(type).as(IdentifierTypeSyntax.self),
            identifier.name.text == name,
            let first = identifier.genericArgumentClause?.arguments.first,
            case .type(let argument) = first.argument
        else { return nil }
        return argument
    }

    /// Extracts the bridged parameters of a function/method parameter clause.
    private func parameters(of clause: FunctionParameterClauseSyntax) -> [FFIParameter] {
        clause.parameters.map { parameter in
            let label = parameter.firstName.text
            // Closure parameter: record the element/return shape alongside the
            // source spelling.
            if let function = strippedType(parameter.type).as(FunctionTypeSyntax.self) {
                let closure = FFIClosureType(
                    parameters: function.parameters.map {
                        canonicalType($0.type.trimmedDescription)
                    },
                    returnType: canonicalType(function.returnClause.type.trimmedDescription)
                )
                return FFIParameter(
                    label: label,
                    type: canonicalType(parameter.type.trimmedDescription),
                    closure: closure
                )
            }
            // Result<S, E> value parameter: record the success type.
            if let success = genericArgument(parameter.type, of: "Result") {
                return FFIParameter(
                    label: label,
                    type: canonicalType(parameter.type.trimmedDescription),
                    resultSuccess: canonicalType(success.trimmedDescription)
                )
            }
            return FFIParameter(
                label: label,
                type: canonicalType(parameter.type.trimmedDescription)
            )
        }
    }

    private func returnType(of signature: FunctionSignatureSyntax) -> String {
        signature.returnClause.map { canonicalType($0.type.trimmedDescription) } ?? "Void"
    }

    /// The bridged return surface: `throws -> T` and `-> Result<T, E>` are both
    /// recorded as returning `T` with the throwing bit set, so they bridge to the
    /// same consumer shape (Kotlin `Result<T>`, TypeScript `Result<T>`).
    /// `wrapsResult` tells the glue to unwrap via `.get()` instead of `try`.
    /// `-> Lazy<T>` is recorded as returning `T` with `returnsLazy` set (the
    /// value crosses as a deferred handle).
    private func effectiveReturn(
        of signature: FunctionSignatureSyntax
    ) -> (type: String, isThrowing: Bool, wrapsResult: Bool, returnsLazy: Bool) {
        let throwing = signature.effectSpecifiers?.throwsClause != nil
        guard let type = signature.returnClause?.type else {
            return ("Void", throwing, false, false)
        }
        if let success = genericArgument(type, of: "Result") {
            return (canonicalType(success.trimmedDescription), true, true, false)
        }
        if let payload = genericArgument(type, of: "Lazy") {
            return (canonicalType(payload.trimmedDescription), throwing, false, true)
        }
        return (canonicalType(type.trimmedDescription), throwing, false, false)
    }
}
