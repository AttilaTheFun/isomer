import SwiftSyntax
import SwiftSyntaxMacros

/// Implements `@ExportedInterface`: validates that the annotated declaration
/// is a protocol whose method surface is bridgeable, and expands the
/// interface's whole C ABI as peers — the Swift box, the ordinal-dispatch
/// `@c(..._invoke)` / `@c(..._release)` entries, the dispatcher-backed
/// foreign proxy, the dual-slot resolver, and the dependency `register`
/// export. See ABIEmitter+Interface.swift for the conventions.
public protocol ExportedInterfaceMacroProtocol: PeerMacro {}

extension ExportedInterfaceMacroProtocol {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let proto = declaration.as(ProtocolDeclSyntax.self) else {
            throw MacroError("@ExportedInterface can only be applied to a protocol.")
        }
        let name = proto.name.text
        let namespace = try ABIModel.namespaceArgument(of: node)

        var methods: [ABIFunction] = []
        for member in proto.memberBlock.members {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else { continue }
            let context = "@ExportedInterface \(name) method '\(function.name.text)'"
            if function.genericParameterClause != nil {
                throw MacroError("\(context) may not be generic.")
            }
            let method = try ABIModel.function(function, context: context, allowEffects: true)
            if method.parameters.contains(where: { $0.closure != nil }) {
                throw MacroError("\(context): closures are only supported as parameters of "
                    + "exported free functions.")
            }
            if method.returnsLazy {
                throw MacroError("\(context): Lazy returns are only supported on exported "
                    + "free functions.")
            }
            methods.append(method)
        }

        // A protocol declared `@_spi(X)` gets its public peers declared the
        // same way, and a `package` protocol gets `package` peers: a public
        // peer cannot name a protocol less visible than itself, and a module
        // that uses the protocol sees it anyway. (Their members follow the
        // peer; the foreign proxy is internal.)
        let spi = proto.attributes.compactMap { element -> String? in
            guard let attribute = element.as(AttributeSyntax.self),
                  attribute.attributeName.trimmedDescription == "_spi" else { return nil }
            return attribute.trimmedDescription + " "
        }.joined()
        let isPackage = proto.modifiers.contains { $0.name.tokenKind == .keyword(.package) }
        let mainActor = proto.attributes.contains { element in
            element.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "MainActor"
        }
        return ABIEmitter.interfacePeers(protocolName: name, methods: methods, namespace: namespace, mainActor: mainActor)
            .map { peer in
                guard !spi.isEmpty || isPackage else { return "\(raw: peer)" }
                let lines = peer.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                    guard line.hasPrefix("public ") else { return String(line) }
                    return isPackage ? "package " + line.dropFirst("public ".count) : spi + line
                }
                return "\(raw: lines.joined(separator: "\n"))"
            }
    }
}
