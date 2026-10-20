import SwiftSyntax
import SwiftSyntaxMacros

/// Implements `@ExportedStruct`: validates that every stored property is a
/// bridgeable *value* type (structs are copied field-wise at the boundary —
/// no interfaces or nested structs), synthesizes the public memberwise
/// initializer the generated glue constructs instances with, and (bridge v2)
/// generates the `Bridgeable` conformance so annotated structs participate in
/// generic exports, `Result` payloads, closure arguments, and `Lazy` values.
public protocol ExportedStructMacroProtocol: MemberMacro, ExtensionMacro {}

/// The validated stored fields of an exported struct.
private func exportedFields(
    of declaration: some DeclGroupSyntax
) throws -> (name: String, fields: [(name: String, type: String)]) {
    guard let structure = declaration.as(StructDeclSyntax.self) else {
        throw MacroError("@ExportedStruct can only be applied to a struct.")
    }

    var fields: [(name: String, type: String)] = []
    for member in structure.memberBlock.members {
        guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
        for binding in variable.bindings {
            guard binding.accessorBlock == nil,
                let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                let type = binding.typeAnnotation?.type.trimmedDescription
            else { continue }
            guard BridgeValueType(typeName: type) != nil else {
                throw MacroError(
                    "@ExportedStruct property '\(name)' has type '\(type)'; struct fields "
                        + "must be bridgeable value types.")
            }
            fields.append((name, type))
        }
    }
    guard !fields.isEmpty else {
        throw MacroError("@ExportedStruct requires at least one stored property.")
    }
    return (structure.name.text, fields)
}

extension ExportedStructMacroProtocol {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let (_, fields) = try exportedFields(of: declaration)
        let parameters = fields.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
        let assignments = fields.map { "    self.\($0.name) = \($0.name)" }.joined(separator: "\n")
        return [
            """
            public init(\(raw: parameters)) {
            \(raw: assignments)
            }
            """
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // If the conformance is already present (e.g. re-expansion), add nothing.
        guard !protocols.isEmpty else { return [] }
        let (name, fields) = try exportedFields(of: declaration)

        let decodes = fields.enumerated().map { index, field in
            "self.\(field.name) = try \(field.type)(bridgeValue: fields[\(index)])"
        }.joined(separator: "\n        ")
        let encodes = fields.map { "\($0.name).bridgeValue" }.joined(separator: ", ")

        let extensionDecl: DeclSyntax =
            """
            extension \(type.trimmed): Bridgeable {
                public init(bridgeValue: BridgeValue) throws {
                    guard case .structure(_, let fields) = bridgeValue,
                        fields.count == \(raw: String(fields.count))
                    else {
                        throw BridgeDecodingError("expected \(raw: name) structure")
                    }
                    \(raw: decodes)
                }

                public var bridgeValue: BridgeValue {
                    .structure(name: "\(raw: name)", fields: [\(raw: encodes)])
                }
            }
            """
        guard let result = extensionDecl.as(ExtensionDeclSyntax.self) else {
            throw MacroError("@ExportedStruct failed to build the Bridgeable extension.")
        }
        return [result]
    }
}
