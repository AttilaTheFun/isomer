import SwiftSyntax
import SwiftSyntaxMacros

/// Implements `@ExportedFunction`: validates the bridged signature and
/// expands the function's C ABI as a peer `@c(swift_ffi_[<ns>_]<name>)`
/// entry thunk (plus a private trampoline for generic exports). See
/// ABIEmitter.swift for the conventions.
public protocol ExportedFunctionMacroProtocol: PeerMacro {}

extension ExportedFunctionMacroProtocol {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let function = declaration.as(FunctionDeclSyntax.self) else {
            throw MacroError("@ExportedFunction can only be applied to a function.")
        }
        let name = function.name.text
        let namespace = try ABIModel.namespaceArgument(of: node)
        let abi = try ABIModel.function(function, context: "@ExportedFunction \(name)")

        // The async completion machinery does not carry erased generics or
        // closures.
        if abi.isAsync {
            let hasClosure = abi.parameters.contains { $0.closure != nil }
            if !abi.genericParameters.isEmpty || hasClosure {
                throw MacroError(
                    "@ExportedFunction \(name): async functions may not (yet) combine with "
                        + "generics or closure parameters.")
            }
        }

        // Each type parameter must be inferable from a direct parameter —
        // the erased C ABI has no way to name a return-only T.
        var inferable: Set<String> = []
        for parameter in abi.parameters {
            if case .generic(let generic) = parameter.value.kind {
                inferable.insert(generic)
            }
        }
        for generic in abi.genericParameters.sorted() where !inferable.contains(generic) {
            throw MacroError(
                "@ExportedFunction \(name) generic parameter '\(generic)' must appear as the "
                    + "type of at least one parameter (return-only generics cannot cross the "
                    + "erased ABI).")
        }

        if abi.returnsLazy, case .interface = abi.returnValue.kind {
            throw MacroError(
                "@ExportedFunction \(name): Lazy payloads must be value types.")
        }

        return try ABIEmitter.functionPeers(abi, namespace: namespace).map { "\(raw: $0)" }
    }
}
