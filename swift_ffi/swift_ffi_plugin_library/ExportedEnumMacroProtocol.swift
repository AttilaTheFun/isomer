import SwiftSyntax
import SwiftSyntaxMacros

/// Implements `@ExportedEnum`: validates that the annotated declaration is an
/// enum with a `String` or `Int` raw type (no associated values), and
/// generates the `Bridgeable` conformance over the raw value — so exported
/// enums cross the boundary by raw value and can serve as dictionary keys in
/// the wasm dependency-injection story.
public protocol ExportedEnumMacroProtocol: ExtensionMacro {}

/// The validated shape of an exported enum.
private func exportedEnum(
    of declaration: some DeclGroupSyntax
) throws -> (name: String, rawType: String) {
    guard let enumeration = declaration.as(EnumDeclSyntax.self) else {
        throw MacroError("@ExportedEnum can only be applied to an enum.")
    }
    let inherited = enumeration.inheritanceClause?.inheritedTypes.compactMap {
        $0.type.trimmedDescription
    } ?? []
    guard let rawType = inherited.first(where: { $0 == "String" || $0 == "Int" }) else {
        throw MacroError(
            "@ExportedEnum \(enumeration.name.text) must declare a String or Int raw type.")
    }
    for member in enumeration.memberBlock.members {
        guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
        for element in caseDecl.elements where element.parameterClause != nil {
            throw MacroError(
                "@ExportedEnum \(enumeration.name.text) case '\(element.name.text)' has "
                    + "associated values; exported enums are raw-value only.")
        }
    }
    return (enumeration.name.text, rawType)
}

extension ExportedEnumMacroProtocol {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let (name, rawType) = try exportedEnum(of: declaration)
        guard !protocols.isEmpty else { return [] }
        let extensionDecl: DeclSyntax =
            """
            extension \(type.trimmed): Bridgeable {
                public init(bridgeValue: BridgeValue) throws {
                    let raw = try \(raw: rawType)(bridgeValue: bridgeValue)
                    guard let value = \(type.trimmed)(rawValue: raw) else {
                        throw BridgeDecodingError("unknown \(raw: name) raw value \\(raw)")
                    }
                    self = value
                }

                public var bridgeValue: BridgeValue {
                    rawValue.bridgeValue
                }
            }
            """
        guard let result = extensionDecl.as(ExtensionDeclSyntax.self) else {
            throw MacroError("@ExportedEnum failed to build the Bridgeable extension.")
        }
        return [result]
    }
}
