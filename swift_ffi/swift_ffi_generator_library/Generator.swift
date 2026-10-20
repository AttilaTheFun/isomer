import Foundation
import SwiftFFIIRLibrary


// The generator consumes merged IR and emits one CONSUMER-side artifact per
// invocation, selected by `--kind`:
//
//   c-header        C header declaring the macro-expanded `@c` symbols
//   jni-adapter     C adapter mapping `Java_*` JNI symbols onto the C ABI
//   kotlin          Kotlin bindings: a facade object + interface wrapper classes
//   ts              TypeScript module wrapping a wasm reactor's exports
//   cpp / rust      idiomatic C++ / Rust bindings over the C ABI
//   swift-host-wasm / c-host-wasm   Swift / C host bindings driving a reactor
//
// The Swift-side ABI itself is macro-expanded into the annotated module (see
// the plugin's ABIEmitter files); these backends must agree with it
// symbol-for-symbol (docs/abi.md).
//
// Ownership follows the swift-java model: interface instances and
// string returns cross the boundary as +1 retained handles that the consumer
// releases exactly once; parameters are borrowed for the call.
//
// Interfaces cross in both directions. Swift-owned instances cross out as
// boxed handles behind `Swift<Name>` consumer wrappers, whose method calls
// are ordinal-led blob dispatches through the interface's one `_invoke`
// entry. Consumer-implemented instances cross *in*: every interface
// parameter travels as a dual slot (swift_handle, foreign_ref) with exactly
// one side set, and the macro-expanded proxy calls back out through the one
// dispatcher channel (a bridge_closure natively; the fixed `closure_invoke`
// import on wasm).
public struct Generator {
    /// The merged whole-module IR the artifact is generated from.
    public let module: FFIModule

    /// The module's exported structs by name — feeds the type predicates the
    /// emitters share.
    let structIndex: [String: FFIStruct]

    public init(module: FFIModule) {
        self.module = module
        // The same struct can reach the generator twice when a module is
        // analyzed in two configurations (an alias resolving per platform);
        // keep the first, identical, declaration.
        self.structIndex = Dictionary(module.structs.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Emits one artifact.
    public func artifact(
        kind: GeneratorKind,
        moduleName: String,
        javaPackage: String = "com.example",
        javaClass: String = "Native",
        libraryName: String = "native",
        headerName: String = ""
    ) throws -> String {
        let header = headerName.isEmpty ? "\(moduleName.lowercased()).h" : headerName
        switch kind {
        case .jniAdapter:
            return emitJNIAdapter(module, moduleName: moduleName, package: javaPackage, className: javaClass, headerName: header)
        case .cHeader:
            return emitCHeader(module, moduleName: moduleName)
        case .cpp:
            return emitCpp(module, moduleName: moduleName, headerName: header)
        case .rust:
            return emitRust(module, moduleName: moduleName)
        case .ts:
            return emitTypeScript(module, moduleName: moduleName)
        case .kotlin:
            return emitKotlin(module, package: javaPackage, className: javaClass, libraryName: libraryName)
        case .swiftHostWasm:
            return emitSwiftHostWasm(module, moduleName: moduleName)
        case .cHostWasm:
            return try emitCHostWasm(module, moduleName: moduleName)
        }
    }
}

// MARK: - Shared type vocabulary

extension Generator {
    func isVoid(_ swift: String) -> Bool { swift == "Void" || swift == "()" }
    func isString(_ swift: String) -> Bool { swift == "String" }
    func isBytes(_ swift: String) -> Bool { swift == "[UInt8]" }

    /// Imports for every module that contributed exports beyond the root
    /// (exports may live in transitive deps, e.g. a dependency's exported surface
    /// re-exported through a bridge module).
    func extraModuleImports(_ module: FFIModule, root: String) -> String {
        let extras = module.sourceModules.filter { $0 != root }.sorted()
        guard !extras.isEmpty else { return "" }
        return extras.map { "import \($0)\n" }.joined()
    }
    /// Types that cross the C boundary as (pointer, length) in and a +1 byte box
    /// out — String (UTF-8) and [UInt8] (raw bytes).
    func isBuffer(_ swift: String) -> Bool { isString(swift) || isBytes(swift) }


    func isStruct(_ type: String) -> Bool { structIndex[type] != nil }

    func isEnum(_ type: String) -> Bool { module.enumNames.contains(type) }

    /// True when the type crosses in erased blob encoding (struct, enum,
    /// Result value, or a generic parameter of the enclosing function).
    func isBlob(_ type: String, generics: Set<String> = []) -> Bool {
        isStruct(type) || isEnum(type) || type.hasPrefix("Result<") || generics.contains(type)
    }

    /// Does the module need the erased machinery at all? (Interfaces always
    /// do — their method calls are ordinal-led blob dispatches.)
    func usesBlobs(_ module: FFIModule) -> Bool {
        !module.structs.isEmpty || !module.interfaces.isEmpty
            || module.functions.contains {
                !$0.genericParameters.isEmpty || $0.returnsLazy
                    || $0.parameters.contains { $0.closure != nil || $0.resultSuccess != nil }
            }
    }

    func usesClosures(_ module: FFIModule) -> Bool {
        module.functions.contains { $0.parameters.contains { $0.closure != nil } }
    }

    /// True when a function uses bridge-v2-only features (generics, closures,
    /// Lazy returns, Result-value parameters) that the wasm host paths don't
    /// carry yet.
    func usesV2Features(_ function: FFIFunction) -> Bool {
        !function.genericParameters.isEmpty || function.returnsLazy
            || function.parameters.contains { $0.closure != nil || $0.resultSuccess != nil }
    }

    func capitalizedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    func lowerFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }

    /// The call into the original Swift function, honoring argument labels.
    func callArguments(_ parameters: [FFIParameter], values: [String]) -> String {
        zip(parameters, values).map { parameter, value in
            parameter.label == "_" ? value : "\(parameter.label): \(value)"
        }.joined(separator: ", ")
    }

    /// Wraps a raw call expression with the function's effects: `.get()` for
    /// Result-returning declarations, and `await`/`try` prefixes.
    func effectfulCall(_ call: String, _ function: FFIFunction) -> String {
        var expression = call
        if function.wrapsResult { expression += ".get()" }
        if function.isAsync { expression = "await \(expression)" }
        if function.isThrowing { expression = "try \(expression)" }
        return expression
    }

    /// The C symbol of one export: `swift_ffi_[<namespace>_]<name>`, exactly
    /// as the macro expansion spells its `@c` attribute. The namespace is
    /// per-declaration (`@ExportedFunction(namespace:)`).
    func cSymbol(namespace: String?, _ name: String) -> String {
        "swift_ffi_\(namespace.map { "\($0)_" } ?? "")\(name)"
    }

    func symbol(_ function: FFIFunction) -> String {
        cSymbol(namespace: function.namespace, function.name)
    }

    /// The interface's `_invoke` / `_release` entries and `register` export.
    func invokeSymbol(_ interface: FFIInterface) -> String {
        cSymbol(namespace: interface.namespace, "\(interface.name)_invoke")
    }

    func releaseSymbol(_ interface: FFIInterface) -> String {
        cSymbol(namespace: interface.namespace, "\(interface.name)_release")
    }

    func registerSymbol(_ interface: FFIInterface) -> String {
        cSymbol(namespace: interface.namespace, "register_\(interface.name)")
    }

    /// The interface's dependency registry key (what `dependency_get` answers
    /// with and the guest's factory registry is keyed by).
    func registryKey(_ interface: FFIInterface) -> String {
        cSymbol(namespace: interface.namespace, interface.name)
    }

    /// Interfaces that appear as a parameter type anywhere in the exported
    /// surface: consumers can pass their own implementations of these, so the
    /// glue needs a foreign proxy for each.
    func foreignInterfaces(_ module: FFIModule) -> Set<String> {
        let names = module.interfaceNames
        var foreign: Set<String> = []
        for function in module.functions {
            for parameter in function.parameters where names.contains(parameter.type) {
                foreign.insert(parameter.type)
            }
        }
        for interface in module.interfaces {
            for method in interface.methods {
                for parameter in method.parameters where names.contains(parameter.type) {
                    foreign.insert(parameter.type)
                }
            }
        }
        return foreign
    }

    // MARK: - Swift glue (C ABI, used by wasm and C consumers)

    /// Per-struct C-buffer helpers: field-wise read (constructing the Swift value
}
