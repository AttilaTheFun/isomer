import Foundation
import SwiftFFIIRLibrary

// The C-host backend: a C header + dispatch table for embedding a reactor
// from C (a host driving a C WebAssembly engine).
extension Generator {
    func cHostParamType(_ swift: String) throws -> String {
        switch swift {
        case "String": return "const char *"
        case "[UInt8]": return "const uint8_t *"
        case "Bool": return "int"
        case "Int", "Int32": return "int32_t"
        case "Double": return "double"
        default:
            throw GeneratorError(
                "c-host-wasm: unsupported foreign parameter type '\(swift)' "
                    + "(supported: String, [UInt8], Bool, Int, Int32, Double)")
        }
    }

    func cHostReturnType(_ swift: String) throws -> String {
        switch swift {
        case "Void", "()": return "void"
        case "Bool", "Int", "Int32": return swift == "Double" ? "double" : "int32_t"
        case "Double": return "double"
        case "String": return "char *"
        default:
            throw GeneratorError(
                "c-host-wasm: unsupported foreign return type '\(swift)' "
                    + "(supported: Void, Bool, Int, Int32, Double, String)")
        }
    }

    /// C reserved words that can't be used bare as an identifier — a Swift argument
    /// label like `for` or `default` would otherwise produce uncompilable C.
    static let cKeywords: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do",
        "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline",
        "int", "long", "register", "restrict", "return", "short", "signed",
        "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned",
        "void", "volatile", "while", "_Bool", "_Complex", "_Imaginary",
    ]

    /// The C identifier for an argument label: unlabeled ⇒ positional `argN`, a
    /// keyword ⇒ suffixed with `_` (`for` → `for_`), otherwise the label verbatim.
    /// Return types the vtable method writes into a `SwiftFFIBlobWriter *out`
    /// parameter instead of returning (byte buffers, string lists).
    func cHostWritesReturn(_ swift: String) -> Bool { swift == "[UInt8]" || swift == "[String]" }

    func cHostParamName(_ label: String, _ index: Int) -> String {
        if label == "_" { return "arg\(index)" }
        return Self.cKeywords.contains(label) ? "\(label)_" : label
    }

    /// The native-C host bindings for a swift_ffi module compiled to a wasm reactor
    /// — the C peer of `emitSwiftHostWasm`. Emits a single self-contained header:
    /// per hostable-interface impl vtables, the ordinal-led blob dispatchers
    /// bridging them into the runtime's ONE `closure_invoke` channel, and thin
    /// wrappers for the module's exported functions. It covers the synchronous
    /// scalar/string/bytes subset a plain C host (a C engine, no compiled
    /// Swift) needs; async / @ExportedStruct / generics / closures /
    /// interface-returning functions are skipped and listed in a header comment
    /// (reach them via the Swift host, the browser, or the compiled C ABI).
    func emitCHostWasm(_ module: FFIModule, moduleName: String) throws -> String {
        // The generated identifiers' prefix (types/helpers in this header) —
        // distinct from the reactor's export symbols, which are the full
        // per-declaration `swift_ffi_[<ns>_]<name>` names.
        let cid = "\(moduleName.lowercased())_"
        let guardMacro = "SWIFT_FFI_\(moduleName.uppercased())_C_HOST_H"

        func cHostScalar(_ type: String) -> Bool {
            ["String", "[UInt8]", "Bool", "Int", "Int32", "Double"].contains(type)
        }
        // An interface is host-implementable only if every method's params and
        // return cross the c-host dispatch subset (no struct/interface either
        // way, no async).
        func hostableInterface(_ interface: FFIInterface) -> Bool {
            interface.methods.allSatisfy { method in
                method.parameters.allSatisfy { (try? cHostParamType($0.type)) != nil }
                    && (method.isAsync || cHostWritesReturn(method.returnType)
                        || (try? cHostReturnType(method.returnType)) != nil)
            }
        }
        let hostable = Set(module.interfaces.filter(hostableInterface).map(\.name))
        let foreign = foreignInterfaces(module)

        // Why an exported function can't be emitted (nil ⇒ emittable). Result and
        // throwing bridge identically here (both carry `isThrowing`).
        func functionSkip(_ function: FFIFunction) -> String? {
            if function.isAsync { return "async" }
            if function.returnsLazy { return "returns Lazy" }
            if !function.genericParameters.isEmpty { return "generic" }
            if function.isThrowing { return function.wrapsResult ? "returns Result" : "throwing" }
            if !["Void", "()", "Bool", "Int", "Int32", "Double", "String"].contains(function.returnType) {
                if isStruct(function.returnType) { return "returns @ExportedStruct \(function.returnType)" }
                if module.interfaceNames.contains(function.returnType) {
                    return "returns Swift-owned interface \(function.returnType)"
                }
                return "unsupported return type \(function.returnType)"
            }
            for parameter in function.parameters {
                if module.interfaceNames.contains(parameter.type) {
                    if !hostable.contains(parameter.type) {
                        return "takes interface \(parameter.type), whose methods aren't c-host-representable"
                    }
                } else if isStruct(parameter.type) {
                    return "takes @ExportedStruct \(parameter.type)"
                } else if !cHostScalar(parameter.type) {
                    return "unsupported parameter type \(parameter.type)"
                }
            }
            return nil
        }

        var emittableFunctions: [FFIFunction] = []
        var skipped: [String] = []
        for function in module.functions {
            if let reason = functionSkip(function) {
                skipped.append("\(function.name)(): \(reason)")
            } else {
                emittableFunctions.append(function)
            }
        }
        for interface in module.interfaces
        where foreign.contains(interface.name) && !hostable.contains(interface.name) {
            skipped.append("interface \(interface.name): a method isn't c-host-representable")
        }
        if !module.structs.isEmpty {
            skipped.append(
                "structs \(module.structs.map(\.name).sorted().joined(separator: ", ")): @ExportedStruct is Swift/browser-host only")
        }

        var out = """
            // Generated by swift_ffi. Do not edit.
            //
            // Native-C host bindings for the `\(moduleName)` Swift module compiled to a
            // WebAssembly reactor — the C peer of the generated swift-host-wasm bindings,
            // for a host with NO compiled Swift (a C engine). The host supplies a
            // `SwiftFFIEngine` (call/read/write), binds the FIXED five-entry import table
            // (\(cid)host_imports), runs `_initialize`, then activates dependencies.
            //
            // Include from exactly one translation unit (the functions are `static`).

            #ifndef \(guardMacro)
            #define \(guardMacro)

            #include <stdint.h>
            #include <stdlib.h>
            #include <string.h>

            #include "swift_ffi_host.h"


            """

        if !skipped.isEmpty {
            out += "// Not part of this c-host surface (reach them via the Swift host, the\n"
            out += "// browser, or the compiled C ABI):\n"
            for entry in skipped.sorted() { out += "//   - \(entry)\n" }
            out += "\n"
        }

        // The registry key of each hostable interface (what `dependency_get`
        // answers with; matched to the guest's macro-registered proxy factory)
        // and its register export (called at activation).
        for interface in module.interfaces where hostable.contains(interface.name) {
            out += "#define \(cid.uppercased())KEY_\(interface.name) \"\(registryKey(interface))\"\n"
            out += "#define \(cid.uppercased())REGISTER_\(interface.name) \"\(registerSymbol(interface))\"\n"
        }
        out += "\n"

        // Per hostable interface: the native impl vtable the host fills in.
        for interface in module.interfaces where hostable.contains(interface.name) {
            out += "// A native `\(interface.name)`, implemented by the host and passed into the reactor.\n"
            out += "typedef struct {\n    void *ctx;\n"
            for method in interface.methods {
                // Async methods take the call id and answer later through
                // swift_ffi_host_async_resume (or write the result into `out`
                // synchronously — a non-NULL `out` write completes at once);
                // types outside the C subset leave a NULL slot the dispatcher
                // answers with an ERROR blob.
                let writesOut = method.isAsync || cHostWritesReturn(method.returnType)
                guard let ret = try? (writesOut ? "void" : cHostReturnType(method.returnType)),
                      let paramTypes = try? method.parameters.map({ try cHostParamType($0.type) })
                else {
                    out += "    void *\(method.name); /* unsupported in the C host subset */\n"
                    continue
                }
                var params = ["void *ctx"]
                if method.isAsync { params.append("int32_t call_id") }
                for (index, parameter) in method.parameters.enumerated() {
                    let pname = cHostParamName(parameter.label, index)
                    params.append("\(paramTypes[index]) \(pname)")
                    if isBytes(parameter.type) { params.append("size_t \(pname)_len") }
                }
                // Byte / string-list results (and async answers) are written
                // into `out` with the swift_ffi_blob_w_* helpers — an ERROR
                // blob there makes a throwing method throw in the guest.
                if writesOut { params.append("SwiftFFIBlobWriter *out") }
                out += "    \(ret) (*\(method.name))(\(params.joined(separator: ", ")));\n"
            }
            out += "} \(cid)\(interface.name);\n\n"
        }

        // The facade: the runtime + the bound fixed import table.
        out += """
            // A host-injected dependency (docs/wasm_di.md): `vtable` points at the
            // matching `\(cid)<Interface>` for `key`. A typed convenience over the
            // runtime's generic `SwiftFFIHostDependency`.
            typedef struct {
                const char *key;             /* the guest's dictionary key */
                const char *registry_key;    /* \(cid.uppercased())KEY_<Interface> */
                const char *register_symbol; /* \(cid.uppercased())REGISTER_<Interface> */
                int lazy;
                const void *vtable;
            } \(cid)dependency;

            typedef struct {
                SwiftFFIHostRuntime *rt;
                SwiftFFIHostImport imports[SWIFT_FFI_HOST_STANDARD_IMPORT_COUNT];
                size_t import_count;
            } \(cid)host;


            """

        // The ordinal-led blob dispatchers, one per hostable interface — the
        // ONE shape serving foreign parameters and injected dependencies.
        for interface in module.interfaces where hostable.contains(interface.name) {
            var cases: [String] = []
            for (ordinal, method) in interface.methods.enumerated() {
                let writesOut = method.isAsync || cHostWritesReturn(method.returnType)
                let representable = (try? method.parameters.map({ try cHostParamType($0.type) })) != nil
                    && (writesOut || (try? cHostReturnType(method.returnType)) != nil)
                guard representable else {
                    cases.append(
                        "    case \(ordinal): {\n        swift_ffi_blob_w_error(w, \"\(interface.name).\(method.name) is outside the C host subset\");\n        break;\n    }")
                    continue
                }
                var body: [String] = []
                var callArgs = ["(void *)impl->ctx"]
                var frees: [String] = []
                if method.isAsync {
                    body.append("swift_ffi_blob_header(&r, NULL);")
                    body.append("int32_t call_id = (int32_t)swift_ffi_blob_i64(&r);")
                    callArgs.append("call_id")
                }
                for (index, parameter) in method.parameters.enumerated() {
                    switch parameter.type {
                    case "String":
                        body.append("swift_ffi_blob_header(&r, NULL);")
                        body.append("char *a\(index) = swift_ffi_blob_bytes(&r, NULL);")
                        callArgs.append("a\(index)")
                        frees.append("free(a\(index));")
                    case "[UInt8]":
                        body.append("swift_ffi_blob_header(&r, NULL);")
                        body.append("size_t a\(index)_len = 0;")
                        body.append("char *a\(index) = swift_ffi_blob_bytes(&r, &a\(index)_len);")
                        callArgs.append("(const uint8_t *)a\(index)")
                        callArgs.append("a\(index)_len")
                        frees.append("free(a\(index));")
                    case "Bool", "Int", "Int32":
                        body.append("swift_ffi_blob_header(&r, NULL);")
                        body.append("int32_t a\(index) = (int32_t)swift_ffi_blob_i64(&r);")
                        callArgs.append("a\(index)")
                    case "Double":
                        body.append("swift_ffi_blob_header(&r, NULL);")
                        body.append("int64_t a\(index)_bits = swift_ffi_blob_i64(&r);")
                        body.append("double a\(index); memcpy(&a\(index), &a\(index)_bits, 8);")
                        callArgs.append("a\(index)")
                    default:
                        throw GeneratorError("c-host-wasm: unsupported dispatch param '\(parameter.type)'")
                    }
                }
                if writesOut { callArgs.append("w") }
                let invoke = "impl->\(method.name)(\(callArgs.joined(separator: ", ")))"
                var tail: [String] = []
                switch writesOut ? "Void" : method.returnType {
                case "Void", "()":
                    if writesOut {
                        // The implementation wrote its answer (or nothing yet,
                        // for an async method answering later).
                        tail.append("{ size_t before = w->len; \(invoke); if (w->len == before) swift_ffi_blob_w_void(w); }")
                    } else {
                        tail.append("\(invoke);")
                        tail.append("swift_ffi_blob_w_void(w);")
                    }
                case "Bool":
                    tail.append("swift_ffi_blob_w_bool(w, \(invoke) ? 1 : 0);")
                case "Int":
                    tail.append("swift_ffi_blob_w_int(w, (int64_t)\(invoke));")
                case "Int32":
                    tail.append("swift_ffi_blob_w_int32v(w, \(invoke));")
                case "Double":
                    tail.append("swift_ffi_blob_w_double(w, \(invoke));")
                case "String":
                    tail.append("char *rr = \(invoke);")
                    tail.append("swift_ffi_blob_w_string(w, rr);")
                    tail.append("free(rr);")
                default:
                    throw GeneratorError("c-host-wasm: unsupported dispatch return '\(method.returnType)'")
                }
                let caseBody = body + tail + frees
                cases.append(
                    "    case \(ordinal): {\n"
                        + caseBody.map { "        \($0)\n" }.joined()
                        + "        break;\n    }")
            }
            out += """
                // Dispatches an ordinal-led blob call into a native `\(interface.name)`.
                static inline void \(cid)_dispatch_\(interface.name)(void *ctx, const uint8_t *args, size_t args_len, SwiftFFIBlobWriter *w) {
                    const \(cid)\(interface.name) *impl = (const \(cid)\(interface.name) *)ctx;
                    SwiftFFIBlobReader r; r.data = args; r.len = args_len; r.off = 0;
                    swift_ffi_blob_header(&r, NULL);
                    int32_t method_ordinal = (int32_t)swift_ffi_blob_i64(&r);
                    switch (method_ordinal) {
                \(cases.joined(separator: "\n"))
                    default:
                        swift_ffi_blob_w_void(w);
                        break;
                    }
                }

                """
        }

        // Typed adapters bridging each interface's vtable into the runtime's
        // generic dependency table.
        if module.interfaces.contains(where: { hostable.contains($0.name) }) {
            var adapterCases: [String] = []
            for interface in module.interfaces where hostable.contains(interface.name) {
                adapterCases.append(
                    "        if (strcmp(deps[i].registry_key, \(cid.uppercased())KEY_\(interface.name)) == 0) generic[i].dispatch = \(cid)_dispatch_\(interface.name);")
            }
            out += """
                // Register the host-injected dependencies with the runtime (typed
                // entries are adapted to the generic table, which copies them).
                static inline void \(cid)host_set_dependencies(\(cid)host *h, const \(cid)dependency *deps, size_t count) {
                    SwiftFFIHostDependency generic[16];
                    if (count > 16) count = 16;
                    for (size_t i = 0; i < count; i++) {
                        generic[i].key = deps[i].key;
                        generic[i].registry_key = deps[i].registry_key;
                        generic[i].register_symbol = deps[i].register_symbol;
                        generic[i].lazy = deps[i].lazy;
                        generic[i].ctx = (void *)deps[i].vtable;
                        generic[i].dispatch = NULL;
                \(adapterCases.joined(separator: "\n"))
                    }
                    swift_ffi_host_set_dependencies(h->rt, generic, count);
                }

                """
        }

        out += """
            // Activate dependency injection: registers the guest-side proxy
            // factories by calling the installed entries' register exports. Call
            // once AFTER instantiation; a no-op for hosts that inject nothing.
            static inline void \(cid)host_activate_dependencies(\(cid)host *h) {
                swift_ffi_host_activate_dependencies(h->rt);
            }

            // Create the host facade for one reactor. Bind the import table (via
            // \(cid)host_imports) into the `swift_ffi` module before instantiation.
            static inline \(cid)host *\(cid)host_create(const SwiftFFIEngine *engine) {
                \(cid)host *h = (\(cid)host *)calloc(1, sizeof(*h));
                if (!h) return NULL;
                h->rt = swift_ffi_host_create(engine);
                if (!h->rt) { free(h); return NULL; }
                h->import_count = swift_ffi_host_standard_imports(h->rt, h->imports);
                return h;
            }

            // The imports to bind into the `swift_ffi` module before instantiation.
            static inline size_t \(cid)host_imports(\(cid)host *h, const SwiftFFIHostImport **out) {
                *out = h->imports;
                return h->import_count;
            }

            static inline void \(cid)host_destroy(\(cid)host *h) {
                if (!h) return;
                swift_ffi_host_destroy(h->rt);
                free(h);
            }


            """

        // Wrappers for the module's exported functions (call after instantiation).
        for function in emittableFunctions {
            // A String return crosses as a +1 box handle the caller drains; the
            // wrapper hands back a malloc'd C string (caller frees).
            let ret = function.returnType == "String" ? "char *" : try cHostReturnType(function.returnType)
            var params: [String] = ["\(cid)host *h"]
            var pre: [String] = []
            var callArgs: [String] = []
            var frees: [String] = []
            for (index, parameter) in function.parameters.enumerated() {
                let pname = cHostParamName(parameter.label, index)
                if module.interfaceNames.contains(parameter.type) {
                    // Foreign-interface param (a consumer-implemented protocol passed
                    // into Swift): register the native vtable as a dispatcher and
                    // pass the dual slot (handle=0, foreign=id).
                    params.append("const \(cid)\(parameter.type) *\(pname)")
                    pre.append("int32_t \(pname)_id = swift_ffi_host_register_foreign(h->rt, (void *)\(pname), \(cid)_dispatch_\(parameter.type));")
                    callArgs.append("swift_ffi_i32(0)")
                    callArgs.append("swift_ffi_i32(\(pname)_id)")
                    continue
                }
                switch parameter.type {
                case "String":
                    params.append("const char *\(pname)")
                    pre.append("uint32_t \(pname)_len = 0; uint32_t \(pname)_ptr = swift_ffi_host_stage_bytes(h->rt, (const uint8_t *)\(pname), \(pname) ? strlen(\(pname)) : 0, &\(pname)_len);")
                    callArgs.append("swift_ffi_i32((int32_t)\(pname)_ptr)")
                    callArgs.append("swift_ffi_i32((int32_t)\(pname)_len)")
                    frees.append("swift_ffi_host_dealloc(h->rt, \(pname)_ptr);")
                case "[UInt8]":
                    params.append("const uint8_t *\(pname)")
                    params.append("size_t \(pname)_count")
                    pre.append("uint32_t \(pname)_len = 0; uint32_t \(pname)_ptr = swift_ffi_host_stage_bytes(h->rt, \(pname), \(pname)_count, &\(pname)_len);")
                    callArgs.append("swift_ffi_i32((int32_t)\(pname)_ptr)")
                    callArgs.append("swift_ffi_i32((int32_t)\(pname)_len)")
                    frees.append("swift_ffi_host_dealloc(h->rt, \(pname)_ptr);")
                case "Bool", "Int", "Int32":
                    params.append("int32_t \(pname)")
                    callArgs.append("swift_ffi_i32(\(pname))")
                case "Double":
                    params.append("double \(pname)")
                    callArgs.append("({ SwiftFFIScalar s; s.kind = SWIFT_FFI_F64; s.value.f64 = \(pname); s; })")
                default:
                    throw GeneratorError("c-host-wasm: unsupported exported-function param '\(parameter.type)'")
                }
            }
            out += "static inline \(ret) \(cid)\(function.name)(\(params.joined(separator: ", "))) {\n"
            for line in pre { out += "    \(line)\n" }
            let argsArray = callArgs.isEmpty ? "NULL" : "args"
            if !callArgs.isEmpty {
                out += "    SwiftFFIScalar args[\(callArgs.count)] = { \(callArgs.joined(separator: ", ")) };\n"
            }
            let callExpr = "swift_ffi_host_call(h->rt, \"\(symbol(function))\", \(argsArray), \(callArgs.count), &result)"
            switch function.returnType {
            case "Void", "()":
                out += "    SwiftFFIScalar result;\n    (void)\(callExpr);\n"
                for f in frees { out += "    \(f)\n" }
            case "String":
                out += "    SwiftFFIScalar result; result = swift_ffi_i32(0);\n    \(callExpr);\n"
                for f in frees { out += "    \(f)\n" }
                out += "    return swift_ffi_host_take_string(h->rt, swift_ffi_scalar_u32(result));\n"
            case "Bool":
                out += "    SwiftFFIScalar result; result = swift_ffi_i32(0);\n    \(callExpr);\n"
                for f in frees { out += "    \(f)\n" }
                out += "    return result.value.i32 != 0;\n"
            case "Int", "Int32":
                out += "    SwiftFFIScalar result; result = swift_ffi_i32(0);\n    \(callExpr);\n"
                for f in frees { out += "    \(f)\n" }
                out += "    return result.value.i32;\n"
            case "Double":
                out += "    SwiftFFIScalar result;\n    \(callExpr);\n"
                for f in frees { out += "    \(f)\n" }
                out += "    return result.value.f64;\n"
            default:
                throw GeneratorError("c-host-wasm: unsupported exported-function return '\(function.returnType)'")
            }
            out += "}\n\n"
        }

        out += "#endif  // \(guardMacro)\n"
        return out
    }

    // MARK: - Kotlin
}
