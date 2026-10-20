import Foundation
import SwiftFFIIRLibrary

// The TypeScript backend: a typed ES-module wrapper over a wasm reactor's
// exports (docs/abi.md). Erased values (structs, enums, Result values,
// generic arguments, closure arguments, interface method arguments, Lazy
// payloads) cross as blobs staged into wasm memory; TypeScript generics are
// erased at runtime, so generic bridge calls take one runtime type token per
// type parameter (`Types.int`, a generated `<Struct>Type`,
// `Types.result(...)`).
//
// Interface method calls dispatch through the interface's single
// `swift_ffi_[<ns>_]<P>_invoke` entry as ordinal-led blob calls; consumer
// implementations cross the other way as ordinal DISPATCHERS through the
// fixed `swift_ffi.closure_invoke` import (closures, foreign objects, and
// injected dependencies share the one channel).
extension Generator {
    // MARK: - TypeScript

    func tsType(_ swift: String, generics: Set<String> = []) -> String {
        switch swift {
        case "Int", "Int32", "Double": return "number"
        case "Bool": return "boolean"
        case "String": return "string"
        case "[UInt8]": return "Uint8Array"
        case "[String]": return "string[]"
        case "Void", "()": return "void"
        default:
            if generics.contains(swift) { return swift }
            if isStruct(swift) || isEnum(swift) { return swift }
            if let success = resultSuccess(swift) {
                return "Result<\(tsType(success, generics: generics))>"
            }
            return module.interfaceNames.contains(swift) ? swift : "number"
        }
    }

    /// Declared return types name the concrete Swift-owned wrapper (so `close()`
    /// is visible); parameters accept the interface contract, which consumers may
    /// implement themselves.
    func tsReturnType(_ swift: String, generics: Set<String> = []) -> String {
        module.interfaceNames.contains(swift) ? "Swift\(swift)" : tsType(swift, generics: generics)
    }

    /// The runtime type-token expression for an erased position.
    func tsToken(_ swift: String, generics: Set<String> = []) -> String {
        switch swift {
        case "Int": return "Types.int"
        case "Int32": return "Types.int32"
        case "Double": return "Types.double"
        case "Bool": return "Types.bool"
        case "String": return "Types.string"
        case "[UInt8]": return "Types.bytes"
        case "[String]": return "Types.array(Types.string)"
        default:
            if generics.contains(swift) { return "\(swift)_type" }
            if isStruct(swift) || isEnum(swift) { return "\(swift)Type" }
            if let success = resultSuccess(swift) {
                return "Types.result(\(tsToken(success, generics: generics)))"
            }
            return "Types.int"
        }
    }

    /// The TS declaration of one closure parameter.
    func tsClosureDecl(_ closure: FFIClosureType, generics: Set<String>) -> String {
        let params = closure.parameters.enumerated()
            .map { "a\($0.offset): \(tsType($0.element, generics: generics))" }
            .joined(separator: ", ")
        return "(\(params)) => \(tsType(closure.returnType, generics: generics))"
    }

    /// JavaScript reserved words that cannot be used as parameter names.
    static let tsReservedWords: Set<String> = [
        "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "enum", "export", "extends", "false",
        "finally", "for", "function", "if", "import", "in", "instanceof", "new",
        "null", "return", "super", "switch", "this", "throw", "true", "try",
        "typeof", "var", "void", "while", "with", "yield",
    ]

    func tsParameterName(_ label: String, _ index: Int) -> String {
        if label == "_" { return "arg\(index)" }
        return Self.tsReservedWords.contains(label) ? label + "_" : label
    }

    /// The blob-encoded closure dispatcher wrapping a typed TS function.
    func tsClosureWrapper(
        _ name: String, _ closure: FFIClosureType, generics: Set<String>
    ) -> String {
        var body: [String] = []
        if !closure.parameters.isEmpty {
            body.append("const r = new BlobReader(args);")
        }
        var callArgs: [String] = []
        for (index, element) in closure.parameters.enumerated() {
            body.append("const a\(index) = \(tsToken(element, generics: generics)).decode(r);")
            callArgs.append("a\(index)")
        }
        let call = "\(name)(\(callArgs.joined(separator: ", ")))"
        if isVoid(closure.returnType) {
            body.append("\(call);")
            body.append("return new Uint8Array(0);")
        } else {
            body.append(
                "return encodeWith(\(tsToken(closure.returnType, generics: generics)), \(call));")
        }
        return "(args: Uint8Array): Uint8Array => { \(body.joined(separator: " ")) }"
    }

    /// Stages one call's parameters: setup lines, C-ABI argument expressions, and
    /// cleanup lines to run after the call returns.
    func tsMarshalParameters(
        _ parameters: [FFIParameter], generics: Set<String> = []
    ) -> (lines: [String], args: [String], cleanup: [String]) {
        var lines: [String] = []
        var args: [String] = []
        var cleanup: [String] = []
        for (index, parameter) in parameters.enumerated() {
            let name = tsParameterName(parameter.label, index)
            if let closure = parameter.closure {
                lines.append(
                    "const c\(index) = registerForeign(\(tsClosureWrapper(name, closure, generics: generics)));")
                args.append("c\(index)")
                continue
            }
            switch parameter.type {
            case "String":
                lines.append("const b\(index) = stageString(this.runtime, \(name));")
                args.append("b\(index).ptr")
                args.append("b\(index).len")
                cleanup.append("b\(index).drop();")
            case "[UInt8]":
                lines.append("const b\(index) = stageBytes(this.runtime, \(name));")
                args.append("b\(index).ptr")
                args.append("b\(index).len")
                cleanup.append("b\(index).drop();")
            case "Bool":
                args.append("\(name) ? 1 : 0")
            case "Int", "Int32", "Double":
                args.append(name)
            default:
                if isBlob(parameter.type, generics: generics) {
                    lines.append(
                        "const b\(index) = stageBytes(this.runtime, encodeWith(\(tsToken(parameter.type, generics: generics)), \(name)));")
                    args.append("b\(index).ptr")
                    args.append("b\(index).len")
                    cleanup.append("b\(index).drop();")
                    continue
                }
                // Dual slot: a Swift-owned wrapper passes its handle (+0); any
                // other implementation is registered as an ordinal dispatcher
                // Swift calls back into (and releases when done with it).
                lines.append(
                    "const f\(index): [number, number] = \(name) instanceof Swift\(parameter.type) "
                        + "? [\(name).borrowHandle(), 0] : [0, registerForeign(makeDispatcher_\(parameter.type)(\(name), () => this.runtime))];")
                args.append("f\(index)[0]")
                args.append("f\(index)[1]")
            }
        }
        return (lines, args, cleanup)
    }

    /// The expression converting a raw C-ABI return value `r` to its TS form.
    func tsUnmarshal(
        _ returnType: String, _ raw: String, runtime: String, generics: Set<String> = []
    ) -> String {
        switch returnType {
        case "Void", "()": return "undefined"
        case "Int", "Int32", "Double": return "\(raw) as number"
        case "Bool": return "(\(raw) as number) !== 0"
        case "String": return "takeString(\(runtime), \(raw) as number)"
        case "[UInt8]": return "takeBytes(\(runtime), \(raw) as number)"
        default:
            if isBlob(returnType, generics: generics) {
                return "decodeWith(\(tsToken(returnType, generics: generics)), takeBytes(\(runtime), \(raw) as number))"
            }
            return "new Swift\(returnType)(\(runtime), \(raw) as number)"
        }
    }

    /// Emits the marshalling body for one synchronous free-function call:
    /// stages parameters, invokes the export, and unmarshals the return.
    /// Throwing functions pass a 4-byte error slot; a non-zero slot after the
    /// call is a +1 string-box handle, surfaced as `{ ok: false, error }`.
    func tsCallBody(
        export: String,
        parameters: [FFIParameter],
        returnType: String,
        returnsLazy: Bool = false,
        generics: Set<String> = [],
        isThrowing: Bool = false,
        indent: String
    ) -> String {
        var (lines, args, cleanup) = tsMarshalParameters(parameters, generics: generics)
        if isThrowing {
            lines.append("const eSlot = this.runtime.call(\"swift_ffi_alloc\", 4) as number;")
            lines.append("new DataView(this.runtime.memory.buffer).setUint32(eSlot, 0, true);")
            args.append("eSlot")
        }

        let call = "this.runtime.call(\"\(export)\", \(args.isEmpty ? "" : args.joined(separator: ", ")))"
        if isVoid(returnType) && !returnsLazy && !isBlob(returnType, generics: generics) {
            lines.append("\(call);")
        } else {
            lines.append("const r = \(call);")
        }
        lines.append(contentsOf: cleanup)

        let unmarshalled: String
        if returnsLazy {
            unmarshalled = "new Lazy(this.runtime, r as number, \(tsToken(returnType, generics: generics)))"
        } else {
            unmarshalled = tsUnmarshal(returnType, "r", runtime: "this.runtime", generics: generics)
        }

        if isThrowing {
            lines.append("const eHandle = new DataView(this.runtime.memory.buffer).getUint32(eSlot, true);")
            lines.append("this.runtime.call(\"swift_ffi_dealloc\", eSlot);")
            lines.append("if (eHandle !== 0) {")
            lines.append("  return { ok: false, error: new SwiftError(takeString(this.runtime, eHandle)) };")
            lines.append("}")
            lines.append("return { ok: true, value: \(unmarshalled) };")
        } else if returnsLazy || !isVoid(returnType) {
            lines.append("return \(unmarshalled);")
        }

        return lines.map { indent + $0 }.joined(separator: "\n")
    }

    /// The blob-encode statements for one interface-method argument into a
    /// `BlobWriter` bound as `w`.
    func tsMethodArgumentEncode(_ parameter: FFIParameter, _ name: String) -> [String] {
        if module.interfaceNames.contains(parameter.type) {
            // Borrowed for the call: a Swift wrapper crosses by handle, any
            // other implementation as a dispatcher id.
            return [
                "if (\(name) instanceof Swift\(parameter.type)) { writeHandle(w, \"\(parameter.type)\", \(name).borrowHandle()); }",
                "else { writeForeign(w, \"\(parameter.type)\", registerForeign(makeDispatcher_\(parameter.type)(\(name), () => this.runtime))); }",
            ]
        }
        return ["\(tsToken(parameter.type)).encode(w, \(name));"]
    }

    /// The body of one Swift-owned wrapper method: ordinal-led blob dispatch
    /// through the interface's `_invoke` entry.
    func tsInvokeBody(
        _ interface: FFIInterface, _ method: FFIMethod, ordinal: Int, indent: String
    ) -> String {
        var lines: [String] = []
        lines.append("const w = new BlobWriter();")
        if method.isAsync {
            // A call id leads the arguments; the guest's Task completes the
            // pending promise through the fixed async_complete import.
            lines.append("const callId = nextCallId();")
            lines.append("Types.int32.encode(w, callId);")
        }
        for (index, parameter) in method.parameters.enumerated() {
            lines.append(contentsOf: tsMethodArgumentEncode(parameter, tsParameterName(parameter.label, index)))
        }
        if method.isAsync {
            let decodeValue: String
            if isVoid(method.returnType) {
                decodeValue = "undefined"
            } else if module.interfaceNames.contains(method.returnType) {
                decodeValue = "new Swift\(method.returnType)(this.runtime, readHandleBits(new BlobReader(blob), \"\(method.returnType)\"))"
            } else {
                decodeValue = "decodeWith(\(tsToken(method.returnType)), blob)"
            }
            lines.append("const promise = new Promise<\(tsReturnType(method.returnType))>((resolve, reject) => {")
            lines.append("  pendingCalls.set(callId, {")
            lines.append("    resolve: resolve as (value: unknown) => void,")
            lines.append("    decode: (blob: Uint8Array) => {")
            lines.append("      const failure = errorMessageOf(blob);")
            lines.append("      if (failure !== null) { reject(new SwiftError(failure)); return undefined; }")
            lines.append("      return \(decodeValue);")
            lines.append("    },")
            lines.append("  });")
            lines.append("});")
        }
        lines.append("const staged = stageBytes(this.runtime, w.data());")
        lines.append(
            "const box = this.runtime.call(\"\(invokeSymbol(interface))\", handle, \(ordinal), staged.ptr, staged.len);")
        lines.append("staged.drop();")
        lines.append("const result = takeBytes(this.runtime, box as number);")
        lines.append("const failure = errorMessageOf(result);")
        lines.append("if (failure !== null) throw new SwiftError(failure);")
        if method.isAsync {
            lines.append("return promise;")
            return lines.map { indent + $0 }.joined(separator: "\n")
        }
        switch method.returnType {
        case "Void", "()":
            break
        default:
            if module.interfaceNames.contains(method.returnType) {
                lines.append(
                    "return new Swift\(method.returnType)(this.runtime, readHandleBits(new BlobReader(result), \"\(method.returnType)\"));")
            } else {
                lines.append("return decodeWith(\(tsToken(method.returnType)), result);")
            }
        }
        return lines.map { indent + $0 }.joined(separator: "\n")
    }

    /// Emits the body of an async facade method: registers a pending call
    /// (with its blob decoder), invokes the export with the call id, and
    /// returns the promise the fixed `async_complete` import resolves.
    func tsAsyncBody(
        _ function: FFIFunction, indent: String
    ) -> String {
        var lines: [String] = []
        let resolved = tsFacadeResolvedType(function)

        // The completion decoder: an ERROR blob fails, anything else decodes
        // by the declared return type.
        var decode: [String] = []
        decode.append("const failure = errorMessageOf(blob);")
        if function.isThrowing {
            decode.append("if (failure !== null) return { ok: false, error: new SwiftError(failure) };")
        } else {
            decode.append("if (failure !== null) throw new SwiftError(failure);")
        }
        let value: String
        switch function.returnType {
        case "Void", "()":
            value = "undefined"
        default:
            if module.interfaceNames.contains(function.returnType) {
                value = "new Swift\(function.returnType)(this.runtime, readHandleBits(new BlobReader(blob), \"\(function.returnType)\"))"
            } else {
                value = "decodeWith(\(tsToken(function.returnType)), blob)"
            }
        }
        decode.append(function.isThrowing ? "return { ok: true, value: \(value) };" : "return \(value);")

        lines.append("const callId = nextCallId();")
        lines.append("const promise = new Promise<\(resolved)>((resolve) => {")
        lines.append("  pendingCalls.set(callId, {")
        lines.append("    resolve: resolve as (value: unknown) => void,")
        lines.append("    decode: (blob: Uint8Array) => {")
        lines.append(contentsOf: decode.map { "      \($0)" })
        lines.append("    },")
        lines.append("  });")
        lines.append("});")
        let (marshal, args, cleanup) = tsMarshalParameters(function.parameters)
        lines.append(contentsOf: marshal)
        lines.append("this.runtime.call(\"\(symbol(function))\", \((["callId"] + args).joined(separator: ", ")));")
        lines.append(contentsOf: cleanup)
        lines.append("return promise;")
        return lines.map { indent + $0 }.joined(separator: "\n")
    }

    /// The type an async function's promise resolves to (`Result<T>` when
    /// failable), and the full declared facade return type.
    func tsFacadeResolvedType(_ function: FFIFunction) -> String {
        let base = tsReturnType(function.returnType)
        return function.isThrowing ? "Result<\(base)>" : base
    }

    func tsFacadeReturnType(_ function: FFIFunction, generics: Set<String> = []) -> String {
        if function.returnsLazy {
            return "Lazy<\(tsType(function.returnType, generics: generics))>"
        }
        let base = tsReturnType(function.returnType, generics: generics)
        let resolved = function.isThrowing ? "Result<\(base)>" : base
        return function.isAsync ? "Promise<\(resolved)>" : resolved
    }

    /// The `dependency_get` import body: answers a guest key with a packed
    /// blob of (lazy, registry key, dispatcher id) — or 0n when the host
    /// injected nothing (including modules with no interfaces at all).
    func dependencyGetBody(hasDI: Bool) -> String {
        guard hasDI else {
            return """
                      void keyPtr;
                      void keyLen;
                      return 0n;
            """
        }
        return """
                  const dep = options?.dependencies?.[foreignString(keyPtr, keyLen)];
                  if (!dep) return 0n;
                  const w = new BlobWriter();
                  w.header(Tags.list, 0);
                  w.i64(3n);
                  Types.bool.encode(w, dep.lazy);
                  Types.string.encode(w, dep.key);
                  Types.int32.encode(w, registerForeign((args) => dep.dispatcher(args, () => runtime as Runtime)));
                  return packForeignBytes(w.data());
        """
    }

    /// The `async_complete` import body: resolves the pending call with its
    /// per-call blob decoder.
    func asyncCompleteBody(hasAsync: Bool) -> String {
        guard hasAsync else {
            return """
                      void callId;
                      void blobPtr;
                      void blobLen;
            """
        }
        return """
                  const pending = pendingCalls.get(callId)!;
                  pendingCalls.delete(callId);
                  pending.resolve(pending.decode(foreignBytes(blobPtr, blobLen)));
        """
    }

    func emitTypeScript(_ module: FFIModule, moduleName: String) -> String {
        let interfaces = module.interfaceNames
        let hasThrowing = module.functions.contains { $0.isThrowing && !$0.isAsync }
            || module.functions.contains { $0.isAsync && $0.isThrowing }
        let hasAsync = module.functions.contains(where: \.isAsync)
            || module.interfaces.contains { $0.methods.contains(where: \.isAsync) }
        let hasLazy = module.functions.contains(where: \.returnsLazy)
        let needsBlobs = usesBlobs(module)
        let hasDI = !module.interfaces.isEmpty

        var runtimeImports = [
            "Runtime",
            "type WasmValue",
            "decoder",
            "encoder",
            "registry",
            "stageBytes",
            "stageString",
            "takeBytes",
            "takeString",
            "wasiShim",
            "type WasiOverrides",
            "type WasiOverridesFactory",
            "foreignObjects",
            "registerForeign",
            "resumeAsync",
            "encodeError",
            "encodeErrorBlob",
            "errorMessageOf",
        ]
        if hasThrowing || needsBlobs {
            runtimeImports += ["SwiftError"]
        }
        if hasThrowing {
            runtimeImports += ["type Result"]
        }
        if hasAsync {
            runtimeImports += ["nextCallId", "pendingCalls"]
        }
        if needsBlobs {
            runtimeImports += [
                "BlobReader", "BlobWriter", "Tags", "type BridgeType", "Types",
                "decodeWith", "encodeWith",
            ]
        }
        if hasDI {
            runtimeImports += ["readHandleBits", "writeHandle", "writeForeign"]
        }
        if hasLazy {
            runtimeImports += ["Lazy"]
        }
        let importList = runtimeImports.sorted()
            .map { "  \($0)," }
            .joined(separator: "\n")
        var reexportNames: [String] = []
        if hasThrowing { reexportNames += ["SwiftError", "type Result"] }
        if hasLazy { reexportNames += ["Lazy"] }
        if needsBlobs { reexportNames += ["Types", "type BridgeType"] }
        let reexports = reexportNames.isEmpty
            ? ""
            : "\n\n// Re-exported so consumers keep importing them from this module.\nexport { \(reexportNames.joined(separator: ", ")) } from \"./swift_ffi_runtime.js\";"

        var out = """
            // Generated by swift_ffi. Do not edit.
            //
            // TypeScript bindings for the `\(moduleName)` Swift module compiled to a
            // WebAssembly reactor. Load with:
            //
            //   const bridge = await load(wasmBytesOrModule);
            //
            // Ownership follows the swift-java model: wrapper objects own a +1 handle
            // to the Swift instance. Release deterministically with `close()` (or a
            // `using` declaration); a FinalizationRegistry backstop releases leaked
            // wrappers after they are garbage collected.
            //
            // The shared runtime (swift_ffi/runtime/ts) is staged next to this file
            // by the wasm library macro; bridges in one directory share the one copy.
            import {
            \(importList)
            } from "./swift_ffi_runtime.js";\(reexports)

            """

        // Struct objects: a plain interface (consumers build object literals) +
        // a blob type token. Structs are identified on the wire by NAME.
        for structure in module.structs {
            out += "\nexport interface \(structure.name) {\n"
            for field in structure.fields {
                out += "  \(field.name): \(tsType(field.type));\n"
            }
            out += "}\n"
            let encodes = structure.fields
                .map { "    \(tsToken($0.type)).encode(w, v.\($0.name));" }
                .joined(separator: "\n")
            let decodes = structure.fields
                .map { "    const \($0.name) = \(tsToken($0.type)).decode(r);" }
                .joined(separator: "\n")
            let names = structure.fields.map(\.name).joined(separator: ", ")
            out += """

                /** The runtime type token for `\(structure.name)` (generic calls). */
                export const \(structure.name)Type: BridgeType<\(structure.name)> = {
                  encode(w: BlobWriter, v: \(structure.name)): void {
                    w.typeHeader(Tags.struct, "\(structure.name)");
                    w.i64(\(structure.fields.count)n);
                \(encodes)
                  },
                  decode(r: BlobReader): \(structure.name) {
                    const tag = r.i32();
                    const aux = r.i32();
                    if (tag !== Tags.struct) throw new SwiftError("expected \(structure.name)");
                    if (aux > 0) r.bytes(aux);
                    r.i64();
                \(decodes)
                    return { \(names) };
                  },
                };

                """
        }

        // Exported enums: raw-value literal unions with a type token.
        for enumeration in module.enums {
            let rawToken = enumeration.rawType == "String" ? "Types.string" : "Types.int"
            let literals = enumeration.cases.enumerated().map { index, c -> String in
                c.rawValue.isEmpty
                    ? (enumeration.rawType == "String" ? "\"\(c.name)\"" : "\(index)")
                    : c.rawValue
            }
            out += """

                /** A raw-value copy of the Swift `\(enumeration.name)` enum. */
                export type \(enumeration.name) = \(literals.joined(separator: " | "));

                export const \(enumeration.name)Type: BridgeType<\(enumeration.name)> = {
                  encode(w: BlobWriter, v: \(enumeration.name)): void {
                    \(rawToken).encode(w, v as never);
                  },
                  decode(r: BlobReader): \(enumeration.name) {
                    return \(rawToken).decode(r) as \(enumeration.name);
                  },
                };

                """
        }

        // Interface contracts + Swift-owned wrapper classes + ordinal
        // dispatchers. Interface-typed method parameters are declared as the
        // Swift-owned wrapper type: that is what a callback implementation is
        // handed (an owned +1 wrapper), and callers of Swift-owned instances
        // hold wrappers anyway.
        for interface in module.interfaces {
            out += "\nexport interface \(interface.name) {\n"
            for method in interface.methods {
                let params = method.parameters.enumerated()
                    .map { "\(tsParameterName($0.element.label, $0.offset)): \(tsReturnType($0.element.type))" }
                    .joined(separator: ", ")
                // Async methods are Promises (a host implementation may also
                // return the value directly); throwing ones throw.
                let ret = method.isAsync ? "Promise<\(tsType(method.returnType))> | \(tsType(method.returnType))" : tsType(method.returnType)
                out += "  \(method.name)(\(params)): \(ret);\n"
            }
            out += "}\n"

            // The wrapper releases its instance with `close()`, unless the
            // interface has a `close` of its own (a connection's): a
            // TypeScript class has one implementation per name, so the
            // release is `release()` there.
            let release = interface.methods.contains { $0.name == "close" } ? "release" : "close"
            out += """

                export class Swift\(interface.name) implements \(interface.name) {
                  private handle: number;
                  private readonly runtime: Runtime;

                  /** @internal Takes ownership of a +1 handle. */
                  constructor(runtime: Runtime, handle: number) {
                    this.runtime = runtime;
                    this.handle = handle;
                    registry.register(this, () => runtime.call("\(releaseSymbol(interface))", handle), this);
                  }

                  /** @internal */
                  borrowHandle(): number {
                    if (this.handle === 0) throw new Error("\(interface.name) used after \(release)()");
                    return this.handle;
                  }

                  /** Releases the underlying Swift instance. Idempotent. */
                  \(release)(): void {
                    if (this.handle !== 0) {
                      registry.unregister(this);
                      this.runtime.call("\(releaseSymbol(interface))", this.handle);
                      this.handle = 0;
                    }
                  }

                  [Symbol.dispose](): void {
                    this.\(release)();
                  }

                """
            for (ordinal, method) in interface.methods.enumerated() {
                let params = method.parameters.enumerated()
                    .map { "\(tsParameterName($0.element.label, $0.offset)): \(tsReturnType($0.element.type))" }
                    .joined(separator: ", ")
                let declaredReturn = method.isAsync
                    ? "Promise<\(tsReturnType(method.returnType))>" : tsReturnType(method.returnType)
                out += """
                      \(method.name)(\(params)): \(declaredReturn) {
                        const handle = this.borrowHandle();
                    \(tsInvokeBody(interface, method, ordinal: ordinal, indent: "    "))
                      }

                    """
            }
            out += "}\n"

            // The ordinal dispatcher wrapping a consumer implementation — the
            // one shape serving foreign parameters and injected dependencies.
            var cases: [String] = []
            for (ordinal, method) in interface.methods.enumerated() {
                var body: [String] = []
                var callArgs: [String] = []
                for (index, parameter) in method.parameters.enumerated() {
                    if interfaces.contains(parameter.type) {
                        // A +1 box handle; the wrapper takes ownership. Needs a
                        // runtime-bound dispatcher (facade marshaling provides
                        // one; injected dependencies never carry interface args).
                        body.append(
                            "if (!runtime) throw new SwiftError(\"\(interface.name).\(method.name) needs a runtime-bound dispatcher\");")
                        body.append(
                            "const a\(index) = new Swift\(parameter.type)(runtime(), readHandleBits(r, \"\(parameter.type)\"));")
                    } else {
                        body.append("const a\(index) = \(tsToken(parameter.type)).decode(r);")
                    }
                    callArgs.append("a\(index)")
                }
                let call = "impl.\(method.name)(\(callArgs.joined(separator: ", ")))"
                if method.isAsync {
                    // The call id leads the arguments; resolve later through
                    // the guest's fixed `swift_ffi_async_resume` export.
                    body.insert("const callId = Types.int32.decode(r);", at: 0)
                    let encodeValue = isVoid(method.returnType)
                        ? "new Uint8Array([0, 0, 0, 0, 0, 0, 0, 0])"
                        : "encodeWith(\(tsToken(method.returnType)), value as \(tsType(method.returnType)))"
                    body.append("if (!runtime) throw new SwiftError(\"\(interface.name).\(method.name) is async and needs a runtime-bound dispatcher\");")
                    body.append("const rt = runtime;")
                    body.append("Promise.resolve().then(() => \(call)).then(")
                    body.append("  (value) => resumeAsync(rt(), callId, \(encodeValue)),")
                    body.append("  (error) => resumeAsync(rt(), callId, encodeError(error instanceof Error ? error.message : String(error))),")
                    body.append(");")
                    body.append("return new Uint8Array(0);")
                } else if method.isThrowing {
                    let encodeValue = isVoid(method.returnType)
                        ? "new Uint8Array(0)"
                        : "encodeWith(\(tsToken(method.returnType)), \(call))"
                    body.append("try {")
                    if isVoid(method.returnType) { body.append("  \(call);") }
                    body.append("  return \(encodeValue);")
                    body.append("} catch (error) {")
                    body.append("  return encodeError(error instanceof Error ? error.message : String(error));")
                    body.append("}")
                } else if isVoid(method.returnType) {
                    body.append("\(call);")
                    body.append("return new Uint8Array(0);")
                } else if interfaces.contains(method.returnType) {
                    body.append("const returned = \(call);")
                    body.append("const w = new BlobWriter();")
                    body.append("if (!(returned instanceof Swift\(method.returnType))) throw new SwiftError(\"\(interface.name).\(method.name) must return a Swift-owned \(method.returnType)\");")
                    body.append("writeHandle(w, \"\(method.returnType)\", returned.borrowHandle());")
                    body.append("return w.data();")
                } else {
                    body.append("return encodeWith(\(tsToken(method.returnType)), \(call));")
                }
                cases.append(
                    "    case \(ordinal): {\n"
                        + body.map { "      \($0)\n" }.joined()
                        + "    }")
            }
            out += """

                /** Wraps a consumer-implemented `\(interface.name)` as the ordinal
                 * dispatcher Swift's foreign proxy calls (method ordinal leads the
                 * arguments). */
                export function makeDispatcher_\(interface.name)(impl: \(interface.name), runtime?: () => Runtime): (args: Uint8Array) => Uint8Array {
                  return (args) => {
                    const r = new BlobReader(args);
                    switch (Types.int32.decode(r)) {
                \(cases.joined(separator: "\n"))
                    }
                    throw new SwiftError("unknown \(interface.name) method ordinal");
                  };
                }

                """
        }

        // Dependency injection (docs/wasm_di.md): typed builders pairing an
        // implementation (or lazy factory) with the interface's registry key.
        if hasDI {
            let entries = module.interfaces.map { interface in
                """
                  \(lowerFirst(interface.name)): (provide: () => \(interface.name), lazy = true): \(moduleName)Dependency => {
                    let impl: \(interface.name) | undefined;
                    return {
                      key: "\(registryKey(interface))",
                      lazy,
                      dispatcher: (args, runtime) => {
                        if (!impl) impl = provide();
                        return makeDispatcher_\(interface.name)(impl, runtime)(args);
                      },
                    };
                  },
                """
            }
            out += """

                /** A host-injected dependency (docs/wasm_di.md): `key` is the
                 * interface's registry key (matched to the guest's proxy factory). */
                export type \(moduleName)Dependency = {
                  key: string;
                  lazy: boolean;
                  dispatcher: (args: Uint8Array, runtime: () => Runtime) => Uint8Array;
                };

                /** Builders wrapping host implementations for injection. */
                export const Dependencies = {
                \(entries.joined(separator: "\n"))
                };

                """
        }

        // The module facade.
        out += """

            export class \(moduleName) {
              private readonly runtime: Runtime;

              /** @internal */
              constructor(runtime: Runtime) {
                this.runtime = runtime;
              }

            """
        for function in module.functions {
            let generics = Set(function.genericParameters)
            // One token parameter per type parameter leads the list.
            var params = function.genericParameters.map { "\($0)_type: BridgeType<\($0)>" }
            params += function.parameters.enumerated().map { index, parameter in
                if let closure = parameter.closure {
                    return "\(tsParameterName(parameter.label, index)): \(tsClosureDecl(closure, generics: generics))"
                }
                return "\(tsParameterName(parameter.label, index)): \(tsType(parameter.type, generics: generics))"
            }
            let typeClause = function.genericParameters.isEmpty
                ? "" : "<\(function.genericParameters.joined(separator: ", "))>"
            let body: String
            if function.isAsync {
                body = tsAsyncBody(function, indent: "    ")
            } else {
                body = tsCallBody(
                    export: symbol(function),
                    parameters: function.parameters,
                    returnType: function.returnType,
                    returnsLazy: function.returnsLazy,
                    generics: generics,
                    isThrowing: function.isThrowing,
                    indent: "    ")
            }
            out += """
                  \(function.name)\(typeClause)(\(params.joined(separator: ", "))): \(tsFacadeReturnType(function, generics: generics)) {
                \(body)
                  }

                """
        }
        out += "}\n"

        // The fixed `swift_ffi` import table: the SwiftFFI runtime references
        // all five imports unconditionally (reactors link --no-gc-sections),
        // so every host binds the full set.
        let registerCalls = module.interfaces
            .map { "  runtime.call(\"\(registerSymbol($0))\");" }
            .joined(separator: "\n")
        out += """

            /** Instantiates the reactor and returns the bridged API. `wasi`
             * merges over the built-in WASI shim, so a host can extend or
             * replace individual calls (clocks, fds, …) without forking; a
             * factory gets the memory accessor and the built-ins. */
            export async function load(
              wasm: BufferSource | WebAssembly.Module,
              options?: {
                dependencies?: Record<string, \(hasDI ? "\(moduleName)Dependency" : "never")>,
                wasi?: WasiOverrides | WasiOverridesFactory,
              },
            ): Promise<\(moduleName)> {
              let memory: WebAssembly.Memory | undefined;
              let runtime: Runtime | undefined;

              // Buffer helpers for the dispatch channel: buffers arrive as
              // (ptr, len) borrowed and return packed as (len << 32) | ptr with
              // bytes from swift_ffi_alloc, ownership transferred to the guest.
              const foreignBytes = (ptr: number, len: number): Uint8Array =>
                len === 0 ? new Uint8Array(0) : new Uint8Array(memory!.buffer, ptr, len).slice();
              const foreignString = (ptr: number, len: number): string =>
                len === 0 ? "" : decoder.decode(new Uint8Array(memory!.buffer, ptr, len));
              const packForeignBytes = (bytes: Uint8Array): bigint => {
                if (bytes.length === 0) return 0n;
                const ptr = runtime!.call("swift_ffi_alloc", bytes.length) as number;
                new Uint8Array(memory!.buffer, ptr, bytes.length).set(bytes);
                return (BigInt(bytes.length) << 32n) | BigInt(ptr >>> 0);
              };

              const swiftFFIImports = {
                closure_invoke: (id: number, argsPtr: number, argsLen: number): bigint => {
                  const dispatcher = foreignObjects.get(id);
                  let result: Uint8Array;
                  try {
                    if (!dispatcher) throw new Error(`no foreign object ${id}`);
                    result = dispatcher(foreignBytes(argsPtr, argsLen));
                  } catch (error) {
                    result = encodeErrorBlob(error instanceof Error ? error.message : String(error));
                  }
                  return packForeignBytes(result);
                },
                foreign_release: (id: number): void => {
                  foreignObjects.delete(id);
                },
                dependency_get: (keyPtr: number, keyLen: number): bigint => {
            \(dependencyGetBody(hasDI: hasDI))
                },
                task_enqueue: (job: number): void => {
                  queueMicrotask(() => {
                    runtime!.call("swift_ffi_task_run", job);
                  });
                },
                // A timed job (Task.sleep): run it once the delay is up.
                task_enqueue_after: (job: number, delayMs: number): void => {
                  setTimeout(() => {
                    runtime!.call("swift_ffi_task_run", job);
                  }, Math.max(0, delayMs));
                },
                async_complete: (callId: number, blobPtr: number, blobLen: number): void => {
            \(asyncCompleteBody(hasAsync: hasAsync))
                },
              };

              const imports = {
                wasi_snapshot_preview1: wasiShim(() => {
                  if (!memory) throw new Error("wasm memory accessed before instantiation");
                  return memory;
                }, options?.wasi),
                swift_ffi: swiftFFIImports,
              };
              const module = wasm instanceof WebAssembly.Module ? wasm : await WebAssembly.compile(wasm as BufferSource);
              const instance = await WebAssembly.instantiate(module, imports);
              memory = instance.exports.memory as WebAssembly.Memory;
              (instance.exports._initialize as () => void)();
              runtime = new Runtime(instance.exports);
            \(registerCalls.isEmpty ? "" : "\n  // Register the interfaces' dependency-proxy factories (docs/wasm_di.md).\n" + registerCalls)
              return new \(moduleName)(runtime);
            }

            """

        return out
    }

    // MARK: - Swift native host (WebAssembly)

    /// Swift hard keywords that need backticking as an argument label.
}
