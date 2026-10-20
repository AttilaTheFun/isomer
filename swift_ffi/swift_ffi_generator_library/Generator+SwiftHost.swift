import Foundation
import SwiftFFIIRLibrary

// The Swift-host backend: an idiomatic Swift facade over a wasm reactor
// running under a `SwiftFFIWasmEngine`. Interface method calls dispatch
// through the interface's `swift_ffi_[<ns>_]<P>_invoke` entry as ordinal-led
// blob calls; native implementations cross the other way as ordinal
// dispatchers through the fixed `closure_invoke` import.
extension Generator {
    static let swiftHostKeywords: Set<String> = [
        "associatedtype", "as", "break", "case", "catch", "class", "continue",
        "default", "defer", "deinit", "do", "else", "enum", "extension",
        "fallthrough", "false", "fileprivate", "for", "func", "guard", "if",
        "import", "in", "init", "inout", "internal", "is", "let", "nil",
        "operator", "private", "protocol", "public", "repeat", "rethrows",
        "return", "self", "static", "struct", "subscript", "super", "switch",
        "throw", "throws", "true", "try", "typealias", "var", "where", "while",
    ]

    func swiftLabelToken(_ label: String) -> String {
        Self.swiftHostKeywords.contains(label) ? "`\(label)`" : label
    }

    /// The declared parameter list for a facade/interface method: the original
    /// argument label (so call sites read like the source API) plus a synthesized
    /// internal name the body marshals.
    func hostDeclParams(_ parameters: [FFIParameter], interfaces: Set<String>) -> String {
        parameters.enumerated().map { index, parameter in
            let label = parameter.label == "_" ? "_" : swiftLabelToken(parameter.label)
            return "\(label) p\(index): \(hostType(parameter.type, interfaces: interfaces))"
        }.joined(separator: ", ")
    }

    /// The idiomatic Swift type of a bridged value on the host side.
    func hostType(_ swift: String, interfaces: Set<String>) -> String {
        switch swift {
        case "Int": return "Int"
        case "Int32": return "Int32"
        case "Double": return "Double"
        case "Bool": return "Bool"
        case "String": return "String"
        case "[UInt8]": return "[UInt8]"
        case "[String]": return "[String]"
        case "Void", "()": return "Void"
        default:
            if isStruct(swift) || isEnum(swift) { return swift }
            return interfaces.contains(swift) ? "any \(swift)" : "Int"
        }
    }

    /// `async` / `throws` on a host protocol method.
    func hostEffects(_ method: FFIMethod) -> String {
        (method.isAsync ? " async" : "") + (method.isThrowing ? " throws" : "")
    }

    /// Returns name the concrete Swift-owned wrapper (so `close()` is visible);
    /// parameters accept the interface contract, which callers may implement.
    func hostReturnType(_ swift: String, interfaces: Set<String>) -> String {
        interfaces.contains(swift) ? "Swift\(swift)" : hostType(swift, interfaces: interfaces)
    }

    /// Whether a type crosses the ordinal-dispatch channel on this host
    /// (dispatchers and interface methods hand-roll their codecs here).
    func hostDispatchable(_ type: String, allowInterfaces: Bool) -> Bool {
        switch type {
        case "Int", "Int32", "Double", "Bool", "String", "[UInt8]", "[String]", "Void", "()":
            return true
        default:
            if isStruct(type) || isEnum(type) { return true }
            return allowInterfaces && module.interfaceNames.contains(type)
        }
    }

    /// Stages one call's parameters: setup lines, C-ABI scalar argument
    /// expressions, and cleanup lines run after the call returns.
    func hostMarshalParameters(
        _ parameters: [FFIParameter], interfaces: Set<String>
    ) -> (lines: [String], args: [String], cleanup: [String]) {
        var lines: [String] = []
        var args: [String] = []
        var cleanup: [String] = []
        for (index, parameter) in parameters.enumerated() {
            let name = "p\(index)"
            switch parameter.type {
            case "String":
                lines.append("let b\(index) = runtime.stageString(\(name))")
                args.append(".i32(Int32(bitPattern: b\(index).ptr))")
                args.append(".i32(Int32(bitPattern: b\(index).len))")
                cleanup.append("runtime.dealloc(b\(index).ptr)")
            case "[UInt8]":
                lines.append("let b\(index) = runtime.stageBytes(\(name))")
                args.append(".i32(Int32(bitPattern: b\(index).ptr))")
                args.append(".i32(Int32(bitPattern: b\(index).len))")
                cleanup.append("runtime.dealloc(b\(index).ptr)")
            case "Bool":
                args.append(".i32(\(name) ? 1 : 0)")
            case "Int":
                args.append(".i32(Int32(truncatingIfNeeded: \(name)))")
            case "Int32":
                args.append(".i32(\(name))")
            case "Double":
                args.append(".f64(\(name))")
            default:
                if isStruct(parameter.type) || isEnum(parameter.type) {
                    let encode = isEnum(parameter.type) ? "encodeBlobEnum_" : "encodeBlob_"
                    lines.append("let s\(index) = runtime.stageBytes(\(encode)\(parameter.type)(\(name)))")
                    args.append(".i32(Int32(bitPattern: s\(index).ptr))")
                    args.append(".i32(Int32(bitPattern: s\(index).len))")
                    cleanup.append("runtime.dealloc(s\(index).ptr)")
                    continue
                }
                // Dual slot: a Swift-owned wrapper passes its handle (+0); any other
                // implementation is registered as an ordinal dispatcher Swift calls
                // back into (and releases via foreign_release when done).
                lines.append("let handle\(index): UInt32")
                lines.append("let foreign\(index): Int32")
                lines.append("if let wrapper\(index) = \(name) as? Swift\(parameter.type) {")
                lines.append("    handle\(index) = wrapper\(index).borrowHandle()")
                lines.append("    foreign\(index) = 0")
                lines.append("} else {")
                lines.append("    handle\(index) = 0")
                lines.append("    foreign\(index) = runtime.registerForeign(swiftFFIHostDispatcher_\(parameter.type)(runtime, \(name)))")
                lines.append("}")
                args.append(".i32(Int32(bitPattern: handle\(index)))")
                args.append(".i32(foreign\(index))")
            }
        }
        return (lines, args, cleanup)
    }

    /// The expression converting a raw C-ABI return scalar `raw` to its host form.
    func hostUnmarshal(_ returnType: String, _ raw: String) -> String {
        switch returnType {
        case "Void", "()": return ""
        case "Int": return "Int(\(raw).i32Value)"
        case "Int32": return "\(raw).i32Value"
        case "Double": return "\(raw).f64Value"
        case "Bool": return "\(raw).boolValue"
        case "String": return "runtime.takeString(\(raw).u32Value)"
        case "[UInt8]": return "runtime.takeBytes(\(raw).u32Value)"
        default: return "Swift\(returnType)(runtime: runtime, handle: \(raw).u32Value)"
        }
    }

    /// Emits the body of one synchronous free-function call: stages params,
    /// invokes the export, and unmarshals the return. Throwing functions pass a
    /// 4-byte error slot (a non-zero handle after the call is a +1 string box,
    /// surfaced as a thrown `SwiftFFIError`).
    func hostCallBody(
        export: String,
        parameters: [FFIParameter],
        returnType: String,
        interfaces: Set<String>,
        isThrowing: Bool = false,
        indent: String
    ) -> String {
        var (lines, marshalledArgs, cleanup) = hostMarshalParameters(parameters, interfaces: interfaces)
        var args = marshalledArgs
        let structReturn = isStruct(returnType)
        if isThrowing {
            lines.append("let errorSlot = runtime.alloc(4)")
            lines.append("runtime.writeU32(errorSlot, 0)")
            args.append(".i32(Int32(bitPattern: errorSlot))")
        }

        let call = "runtime.call(\"\(export)\", [\(args.joined(separator: ", "))])"
        if isVoid(returnType) {
            lines.append(call)
        } else {
            lines.append("let raw = \(call)!")
        }
        lines.append(contentsOf: cleanup)

        let unmarshalled: String
        if structReturn {
            unmarshalled = "decodeBlob_\(returnType)(runtime.takeBytes(raw.u32Value))"
        } else if isEnum(returnType) {
            unmarshalled = "decodeBlobEnum_\(returnType)(runtime.takeBytes(raw.u32Value))"
        } else {
            unmarshalled = hostUnmarshal(returnType, "raw")
        }

        if isThrowing {
            lines.append("let errorHandle = runtime.readU32(errorSlot)")
            lines.append("runtime.dealloc(errorSlot)")
            lines.append("if errorHandle != 0 {")
            lines.append("    throw SwiftFFIError(runtime.takeString(errorHandle))")
            lines.append("}")
            if !isVoid(returnType) || structReturn {
                lines.append("return \(unmarshalled)")
            }
        } else if !isVoid(returnType) {
            lines.append("return \(unmarshalled)")
        }

        return lines.map { indent + $0 }.joined(separator: "\n")
    }

    /// Per-struct blob encode/decode helpers (the wire encoding; structs are
    /// identified on the wire by NAME — see swift_abi.h).
    func emitHostStructHelpers(_ structure: FFIStruct) -> String {
        var encodes: [String] = []
        var decodes: [String] = []
        var fieldInits: [String] = []
        for (index, field) in structure.fields.enumerated() {
            switch field.type {
            case "Double":
                encodes.append("SwiftFFIMemory.appendI32(&bytes, 3); SwiftFFIMemory.appendI32(&bytes, 0)")
                encodes.append("SwiftFFIMemory.appendI64(&bytes, Int64(bitPattern: value.\(field.name).bitPattern))")
                decodes.append("_ = SwiftFFIMemory.readHeader(bytes, &cursor); let f\(index) = Double(bitPattern: UInt64(bitPattern: SwiftFFIMemory.readI64(bytes, &cursor)))")
            case "Int":
                encodes.append("SwiftFFIMemory.appendI32(&bytes, 1); SwiftFFIMemory.appendI32(&bytes, 0)")
                encodes.append("SwiftFFIMemory.appendI64(&bytes, Int64(value.\(field.name)))")
                decodes.append("_ = SwiftFFIMemory.readHeader(bytes, &cursor); let f\(index) = Int(SwiftFFIMemory.readI64(bytes, &cursor))")
            case "Int32":
                encodes.append("SwiftFFIMemory.appendI32(&bytes, 2); SwiftFFIMemory.appendI32(&bytes, 0)")
                encodes.append("SwiftFFIMemory.appendI64(&bytes, Int64(value.\(field.name)))")
                decodes.append("_ = SwiftFFIMemory.readHeader(bytes, &cursor); let f\(index) = Int32(truncatingIfNeeded: SwiftFFIMemory.readI64(bytes, &cursor))")
            case "Bool":
                encodes.append("SwiftFFIMemory.appendI32(&bytes, 4); SwiftFFIMemory.appendI32(&bytes, 0)")
                encodes.append("SwiftFFIMemory.appendI64(&bytes, value.\(field.name) ? 1 : 0)")
                decodes.append("_ = SwiftFFIMemory.readHeader(bytes, &cursor); let f\(index) = SwiftFFIMemory.readI64(bytes, &cursor) != 0")
            case "String":
                encodes.append("let u\(index) = Array(value.\(field.name).utf8)")
                encodes.append("SwiftFFIMemory.appendI32(&bytes, 5); SwiftFFIMemory.appendI32(&bytes, 0)")
                encodes.append("SwiftFFIMemory.appendI64(&bytes, Int64(u\(index).count)); bytes.append(contentsOf: u\(index))")
                decodes.append("_ = SwiftFFIMemory.readHeader(bytes, &cursor); let n\(index) = Int(SwiftFFIMemory.readI64(bytes, &cursor))")
                decodes.append("let f\(index) = String(decoding: SwiftFFIMemory.readSlice(bytes, &cursor, n\(index)), as: UTF8.self)")
            default: // [UInt8]
                encodes.append("SwiftFFIMemory.appendI32(&bytes, 6); SwiftFFIMemory.appendI32(&bytes, 0)")
                encodes.append("SwiftFFIMemory.appendI64(&bytes, Int64(value.\(field.name).count)); bytes.append(contentsOf: value.\(field.name))")
                decodes.append("_ = SwiftFFIMemory.readHeader(bytes, &cursor); let n\(index) = Int(SwiftFFIMemory.readI64(bytes, &cursor))")
                decodes.append("let f\(index) = SwiftFFIMemory.readSlice(bytes, &cursor, n\(index))")
            }
            fieldInits.append("\(field.name): f\(index)")
        }
        let encodeBody = encodes.map { "    \($0)\n" }.joined()
        let decodeBody = decodes.map { "    \($0)\n" }.joined()
        return """

            func encodeBlob_\(structure.name)(_ value: \(structure.name)) -> [UInt8] {
                var bytes: [UInt8] = []
                SwiftFFIMemory.appendTypeHeader(&bytes, 7, "\(structure.name)")
                SwiftFFIMemory.appendI64(&bytes, \(structure.fields.count))
            \(encodeBody)    return bytes
            }

            func decodeBlob_\(structure.name)(_ bytes: [UInt8]) -> \(structure.name) {
                var cursor = 0
                _ = SwiftFFIMemory.readHeader(bytes, &cursor)
                _ = SwiftFFIMemory.readI64(bytes, &cursor)
            \(decodeBody)    return \(structure.name)(\(fieldInits.joined(separator: ", ")))
            }

            """
    }

    /// One decoded method argument inside a dispatcher (ordinal-led blob).
    private func hostDispatchDecode(_ type: String, _ index: Int) -> [String] {
        var lines: [String] = []
        switch type {
        case "Int":
            lines.append("_ = SwiftFFIMemory.readHeader(blob, &cursor)")
            lines.append("let a\(index) = Int(SwiftFFIMemory.readI64(blob, &cursor))")
        case "Int32":
            lines.append("_ = SwiftFFIMemory.readHeader(blob, &cursor)")
            lines.append("let a\(index) = Int32(truncatingIfNeeded: SwiftFFIMemory.readI64(blob, &cursor))")
        case "Double":
            lines.append("_ = SwiftFFIMemory.readHeader(blob, &cursor)")
            lines.append("let a\(index) = Double(bitPattern: UInt64(bitPattern: SwiftFFIMemory.readI64(blob, &cursor)))")
        case "Bool":
            lines.append("_ = SwiftFFIMemory.readHeader(blob, &cursor)")
            lines.append("let a\(index) = SwiftFFIMemory.readI64(blob, &cursor) != 0")
        case "String":
            lines.append("_ = SwiftFFIMemory.readHeader(blob, &cursor)")
            lines.append("let n\(index) = Int(SwiftFFIMemory.readI64(blob, &cursor))")
            lines.append("let a\(index) = String(decoding: SwiftFFIMemory.readSlice(blob, &cursor, n\(index)), as: UTF8.self)")
        case "[UInt8]":
            lines.append("_ = SwiftFFIMemory.readHeader(blob, &cursor)")
            lines.append("let n\(index) = Int(SwiftFFIMemory.readI64(blob, &cursor))")
            lines.append("let a\(index) = SwiftFFIMemory.readSlice(blob, &cursor, n\(index))")
        case "[String]":
            lines.append("let a\(index) = SwiftFFIMemory.readStringList(blob, &cursor)")
        default:
            if let enumeration = module.enums.first(where: { $0.name == type }) {
                lines.append("_ = SwiftFFIMemory.readHeader(blob, &cursor)")
                if enumeration.rawType == "String" {
                    lines.append("let n\(index) = Int(SwiftFFIMemory.readI64(blob, &cursor))")
                    lines.append("let a\(index) = \(type)(rawValue: String(decoding: SwiftFFIMemory.readSlice(blob, &cursor, n\(index)), as: UTF8.self))!")
                } else {
                    lines.append("let a\(index) = \(type)(rawValue: Int(SwiftFFIMemory.readI64(blob, &cursor)))!")
                }
            } else if isStruct(type) {
                // Structs re-decode from the remaining slice; decodeBlob_
                // consumes exactly one struct, so re-encode to find the length.
                lines.append("let a\(index) = decodeBlob_\(type)(SwiftFFIMemory.readSlice(blob, &cursor, blob.count - cursor))")
                lines.append("cursor += encodeBlob_\(type)(a\(index)).count")
            } else {
                // An interface: a +1 HANDLE (the wrapper takes ownership).
                lines.append("_ = SwiftFFIMemory.readHeader(blob, &cursor)")
                lines.append("guard let runtime else { preconditionFailure(\"swift_ffi: interface arguments need a runtime-bound dispatcher\") }")
                lines.append("let a\(index) = Swift\(type)(runtime: runtime, handle: UInt32(truncatingIfNeeded: SwiftFFIMemory.readI64(blob, &cursor)))")
            }
        }
        return lines
    }

    /// One dispatcher case: decode the method's blob arguments, call the
    /// implementation, encode the blob result.
    private func hostDispatchCase(_ method: FFIMethod, ordinal: Int) -> String {
        var lines: [String] = []
        var values: [String] = []
        if method.isAsync {
            // The call id leads the arguments; the answer goes back through
            // `resumeAsync` from a Task (the runtime hops it to its thread).
            lines.append("_ = SwiftFFIMemory.readHeader(blob, &cursor)")
            lines.append("let callId = Int32(truncatingIfNeeded: SwiftFFIMemory.readI64(blob, &cursor))")
        }
        for (index, parameter) in method.parameters.enumerated() {
            lines.append(contentsOf: hostDispatchDecode(parameter.type, index))
            values.append("a\(index)")
        }
        let bareInvocation = "impl.\(method.name)(\(callArguments(method.parameters, values: values)))"
        if method.isAsync {
            let awaited = (method.isThrowing ? "try " : "") + "await " + bareInvocation
            lines.append("guard let runtime else { preconditionFailure(\"swift_ffi: async interface methods need a runtime-bound dispatcher\") }")
            lines.append("Task {")
            lines.append("    do {")
            if isVoid(method.returnType) {
                lines.append("        \(awaited)")
                lines.append("        runtime.resumeAsync(callId, blob: [0, 0, 0, 0, 0, 0, 0, 0])")
            } else {
                lines.append("        let value = \(awaited)")
                lines.append("        runtime.resumeAsync(callId, blob: \(hostEncodeExpr(method.returnType, "value")))")
            }
            lines.append("    } catch {")
            lines.append("        runtime.resumeAsync(callId, blob: SwiftFFIMemory.errorBlob(String(describing: error)))")
            lines.append("    }")
            lines.append("}")
            lines.append("return []")
            return "        case \(ordinal):\n" + lines.map { "            \($0)\n" }.joined()
        }
        let invocation = (method.isThrowing ? "try " : "") + bareInvocation
        if method.isThrowing {
            // Errors answer as an ERROR blob (the guest proxy rethrows).
            var inner: [String] = []
            if isVoid(method.returnType) {
                inner.append("\(invocation)")
                inner.append("return []")
            } else {
                inner.append("let value = \(invocation)")
                inner.append("return \(hostEncodeExpr(method.returnType, "value"))")
            }
            lines.append("do {")
            lines.append(contentsOf: inner.map { "    \($0)" })
            lines.append("} catch {")
            lines.append("    return SwiftFFIMemory.errorBlob(String(describing: error))")
            lines.append("}")
            return "        case \(ordinal):\n" + lines.map { "            \($0)\n" }.joined()
        }
        switch method.returnType {
        case "Void", "()":
            lines.append(invocation)
            lines.append("return []")
        case "Int":
            lines.append("var out: [UInt8] = []")
            lines.append("SwiftFFIMemory.appendI32(&out, 1); SwiftFFIMemory.appendI32(&out, 0)")
            lines.append("SwiftFFIMemory.appendI64(&out, Int64(\(invocation)))")
            lines.append("return out")
        case "Int32":
            lines.append("var out: [UInt8] = []")
            lines.append("SwiftFFIMemory.appendI32(&out, 2); SwiftFFIMemory.appendI32(&out, 0)")
            lines.append("SwiftFFIMemory.appendI64(&out, Int64(\(invocation)))")
            lines.append("return out")
        case "Double":
            lines.append("var out: [UInt8] = []")
            lines.append("SwiftFFIMemory.appendI32(&out, 3); SwiftFFIMemory.appendI32(&out, 0)")
            lines.append("SwiftFFIMemory.appendI64(&out, Int64(bitPattern: \(invocation).bitPattern))")
            lines.append("return out")
        case "Bool":
            lines.append("var out: [UInt8] = []")
            lines.append("SwiftFFIMemory.appendI32(&out, 4); SwiftFFIMemory.appendI32(&out, 0)")
            lines.append("SwiftFFIMemory.appendI64(&out, \(invocation) ? 1 : 0)")
            lines.append("return out")
        case "String":
            lines.append("let u = Array(\(invocation).utf8)")
            lines.append("var out: [UInt8] = []")
            lines.append("SwiftFFIMemory.appendI32(&out, 5); SwiftFFIMemory.appendI32(&out, 0)")
            lines.append("SwiftFFIMemory.appendI64(&out, Int64(u.count)); out.append(contentsOf: u)")
            lines.append("return out")
        case "[UInt8]":
            lines.append("let u = \(invocation)")
            lines.append("var out: [UInt8] = []")
            lines.append("SwiftFFIMemory.appendI32(&out, 6); SwiftFFIMemory.appendI32(&out, 0)")
            lines.append("SwiftFFIMemory.appendI64(&out, Int64(u.count)); out.append(contentsOf: u)")
            lines.append("return out")
        case "[String]":
            lines.append("var out: [UInt8] = []")
            lines.append("SwiftFFIMemory.appendStringList(&out, \(invocation))")
            lines.append("return out")
        default:
            if isEnum(method.returnType) {
                lines.append("return encodeBlobEnum_\(method.returnType)(\(invocation))")
            } else {
                lines.append("return encodeBlob_\(method.returnType)(\(invocation))")
            }
        }
        return "        case \(ordinal):\n"
            + lines.map { "            \($0)\n" }.joined()
    }

    /// The blob-encode expression of a host value of a bridged type.
    private func hostEncodeExpr(_ type: String, _ expr: String) -> String {
        switch type {
        case "Int": return "{ var o: [UInt8] = []; SwiftFFIMemory.appendI32(&o, 1); SwiftFFIMemory.appendI32(&o, 0); SwiftFFIMemory.appendI64(&o, Int64(\(expr))); return o }()"
        case "Int32": return "{ var o: [UInt8] = []; SwiftFFIMemory.appendI32(&o, 2); SwiftFFIMemory.appendI32(&o, 0); SwiftFFIMemory.appendI64(&o, Int64(\(expr))); return o }()"
        case "Double": return "{ var o: [UInt8] = []; SwiftFFIMemory.appendI32(&o, 3); SwiftFFIMemory.appendI32(&o, 0); SwiftFFIMemory.appendI64(&o, Int64(bitPattern: (\(expr)).bitPattern)); return o }()"
        case "Bool": return "{ var o: [UInt8] = []; SwiftFFIMemory.appendI32(&o, 4); SwiftFFIMemory.appendI32(&o, 0); SwiftFFIMemory.appendI64(&o, (\(expr)) ? 1 : 0); return o }()"
        case "String": return "{ let u = Array((\(expr)).utf8); var o: [UInt8] = []; SwiftFFIMemory.appendI32(&o, 5); SwiftFFIMemory.appendI32(&o, 0); SwiftFFIMemory.appendI64(&o, Int64(u.count)); o.append(contentsOf: u); return o }()"
        case "[UInt8]": return "{ let u = \(expr); var o: [UInt8] = []; SwiftFFIMemory.appendI32(&o, 6); SwiftFFIMemory.appendI32(&o, 0); SwiftFFIMemory.appendI64(&o, Int64(u.count)); o.append(contentsOf: u); return o }()"
        case "[String]": return "{ var o: [UInt8] = []; SwiftFFIMemory.appendStringList(&o, \(expr)); return o }()"
        default:
            return isEnum(type) ? "encodeBlobEnum_\(type)(\(expr))" : "encodeBlob_\(type)(\(expr))"
        }
    }

    /// One Swift-owned wrapper method: ordinal-led blob dispatch through the
    /// interface's `_invoke` entry.
    private func hostInvokeMethod(
        _ interface: FFIInterface, _ method: FFIMethod, ordinal: Int, interfaces: Set<String>
    ) -> String {
        if method.isAsync {
            // Swift-owned instances' async methods complete through the guest's
            // async_complete import — not wired for host-side callers yet. The
            // stub must still carry the method's own signature: a protocol that
            // does not throw cannot be satisfied by a stub that does, so the
            // non-throwing shape traps instead.
            let message = "async interface methods on guest-owned instances are not callable from the host yet"
            let signature = "    public func \(method.name)(\(hostDeclParams(method.parameters, interfaces: interfaces))) async\(method.isThrowing ? " throws" : "") -> \(hostType(method.returnType, interfaces: interfaces)) {\n"
            let body = method.isThrowing
                ? "        throw SwiftFFIError(\"\(message)\")\n"
                : "        fatalError(\"\(message)\")\n"
            return signature + body + "    }\n"
        }
        var body: [String] = []
        body.append("let handle = borrowHandle()")
        body.append("\(method.parameters.isEmpty ? "let" : "var") args: [UInt8] = []")
        for (index, parameter) in method.parameters.enumerated() {
            let name = "p\(index)"
            switch parameter.type {
            case "Int":
                body.append("SwiftFFIMemory.appendI32(&args, 1); SwiftFFIMemory.appendI32(&args, 0); SwiftFFIMemory.appendI64(&args, Int64(\(name)))")
            case "Int32":
                body.append("SwiftFFIMemory.appendI32(&args, 2); SwiftFFIMemory.appendI32(&args, 0); SwiftFFIMemory.appendI64(&args, Int64(\(name)))")
            case "Double":
                body.append("SwiftFFIMemory.appendI32(&args, 3); SwiftFFIMemory.appendI32(&args, 0); SwiftFFIMemory.appendI64(&args, Int64(bitPattern: \(name).bitPattern))")
            case "Bool":
                body.append("SwiftFFIMemory.appendI32(&args, 4); SwiftFFIMemory.appendI32(&args, 0); SwiftFFIMemory.appendI64(&args, \(name) ? 1 : 0)")
            case "String":
                body.append("let u\(index) = Array(\(name).utf8)")
                body.append("SwiftFFIMemory.appendI32(&args, 5); SwiftFFIMemory.appendI32(&args, 0); SwiftFFIMemory.appendI64(&args, Int64(u\(index).count)); args.append(contentsOf: u\(index))")
            case "[UInt8]":
                body.append("SwiftFFIMemory.appendI32(&args, 6); SwiftFFIMemory.appendI32(&args, 0); SwiftFFIMemory.appendI64(&args, Int64(\(name).count)); args.append(contentsOf: \(name))")
            case "[String]":
                body.append("SwiftFFIMemory.appendStringList(&args, \(name))")
            default:
                if isEnum(parameter.type) {
                    body.append("args.append(contentsOf: encodeBlobEnum_\(parameter.type)(\(name)))")
                } else if isStruct(parameter.type) {
                    body.append("args.append(contentsOf: encodeBlob_\(parameter.type)(\(name)))")
                } else {
                    // Borrowed for the call: a Swift wrapper crosses by handle,
                    // any other implementation as a dispatcher id.
                    body.append("if let wrapper\(index) = \(name) as? Swift\(parameter.type) {")
                    body.append("    SwiftFFIMemory.appendTypeHeader(&args, 9, \"\(parameter.type)\")")
                    body.append("    SwiftFFIMemory.appendI64(&args, Int64(wrapper\(index).borrowHandle()))")
                    body.append("} else {")
                    body.append("    SwiftFFIMemory.appendTypeHeader(&args, 11, \"\(parameter.type)\")")
                    body.append("    SwiftFFIMemory.appendI64(&args, Int64(runtime.registerForeign(swiftFFIHostDispatcher_\(parameter.type)(runtime, \(name)))))")
                    body.append("}")
                }
            }
        }
        body.append("let staged = runtime.stageBytes(args)")
        body.append(
            "let box = runtime.call(\"\(invokeSymbol(interface))\", [.i32(Int32(bitPattern: handle)), .i32(\(ordinal)), .i32(Int32(bitPattern: staged.ptr)), .i32(Int32(bitPattern: staged.len))])!")
        body.append("runtime.dealloc(staged.ptr)")
        body.append("let result = runtime.takeBytes(box.u32Value)")
        body.append("if let failure = SwiftFFIMemory.errorMessage(of: result) {")
        if method.isThrowing {
            body.append("    throw SwiftFFIError(failure)")
        } else {
            body.append("    preconditionFailure(\"swift_ffi: \(interface.name).\(method.name) failed: \\(failure)\")")
        }
        body.append("}")
        switch method.returnType {
        case "Void", "()":
            body.append("_ = result")
        case "[String]":
            body.append("var cursor = 0")
            body.append("return SwiftFFIMemory.readStringList(result, &cursor)")
        case "Int":
            body.append("var cursor = 0; _ = SwiftFFIMemory.readHeader(result, &cursor)")
            body.append("return Int(SwiftFFIMemory.readI64(result, &cursor))")
        case "Int32":
            body.append("var cursor = 0; _ = SwiftFFIMemory.readHeader(result, &cursor)")
            body.append("return Int32(truncatingIfNeeded: SwiftFFIMemory.readI64(result, &cursor))")
        case "Double":
            body.append("var cursor = 0; _ = SwiftFFIMemory.readHeader(result, &cursor)")
            body.append("return Double(bitPattern: UInt64(bitPattern: SwiftFFIMemory.readI64(result, &cursor)))")
        case "Bool":
            body.append("var cursor = 0; _ = SwiftFFIMemory.readHeader(result, &cursor)")
            body.append("return SwiftFFIMemory.readI64(result, &cursor) != 0")
        case "String":
            body.append("var cursor = 0; _ = SwiftFFIMemory.readHeader(result, &cursor)")
            body.append("let n = Int(SwiftFFIMemory.readI64(result, &cursor))")
            body.append("return String(decoding: SwiftFFIMemory.readSlice(result, &cursor, n), as: UTF8.self)")
        case "[UInt8]":
            body.append("var cursor = 0; _ = SwiftFFIMemory.readHeader(result, &cursor)")
            body.append("let n = Int(SwiftFFIMemory.readI64(result, &cursor))")
            body.append("return SwiftFFIMemory.readSlice(result, &cursor, n)")
        default:
            if isEnum(method.returnType) {
                body.append("return decodeBlobEnum_\(method.returnType)(result)")
            } else if isStruct(method.returnType) {
                body.append("return decodeBlob_\(method.returnType)(result)")
            } else {
                body.append("var cursor = 0; _ = SwiftFFIMemory.readHeader(result, &cursor)")
                body.append("return Swift\(method.returnType)(runtime: runtime, handle: UInt32(truncatingIfNeeded: SwiftFFIMemory.readI64(result, &cursor)))")
            }
        }
        let ret = hostReturnType(method.returnType, interfaces: interfaces)
        let retClause = isVoid(method.returnType) ? "" : " -> \(ret)"
        let effects = method.isThrowing ? " throws" : ""
        return "    public func \(method.name)(\(hostDeclParams(method.parameters, interfaces: interfaces)))\(effects)\(retClause) {\n"
            + body.map { "        \($0)\n" }.joined() + "    }\n"
    }

    /// The body of an async facade method: make a call id, kick off the async
    /// export, pump the cooperative executor until it completes, then decode
    /// the completion blob (an ERROR blob throws for throwing functions).
    func hostAsyncBody(
        _ function: FFIFunction, interfaces: Set<String>, indent: String
    ) -> String {
        var (lines, marshalledArgs, cleanup) = hostMarshalParameters(function.parameters, interfaces: interfaces)
        lines.insert("let callId = runtime.makeCallId()", at: 0)
        let callArgs = ([".i32(callId)"] + marshalledArgs).joined(separator: ", ")
        lines.append("runtime.call(\"\(symbol(function))\", [\(callArgs)])")
        lines.append("runtime.pump(untilCallId: callId)")
        lines.append(contentsOf: cleanup)
        lines.append("let blob = runtime.finishAsync(callId)")
        lines.append("if let failure = SwiftFFIMemory.errorMessage(of: blob) {")
        if function.isThrowing {
            lines.append("    throw SwiftFFIError(failure)")
        } else {
            lines.append("    preconditionFailure(\"swift_ffi: \(function.name) failed: \\(failure)\")")
        }
        lines.append("}")
        switch function.returnType {
        case "Void", "()":
            lines.append("_ = blob")
        case "Int":
            lines.append("var cursor = 0; _ = SwiftFFIMemory.readHeader(blob, &cursor)")
            lines.append("return Int(SwiftFFIMemory.readI64(blob, &cursor))")
        case "Int32":
            lines.append("var cursor = 0; _ = SwiftFFIMemory.readHeader(blob, &cursor)")
            lines.append("return Int32(truncatingIfNeeded: SwiftFFIMemory.readI64(blob, &cursor))")
        case "Double":
            lines.append("var cursor = 0; _ = SwiftFFIMemory.readHeader(blob, &cursor)")
            lines.append("return Double(bitPattern: UInt64(bitPattern: SwiftFFIMemory.readI64(blob, &cursor)))")
        case "Bool":
            lines.append("var cursor = 0; _ = SwiftFFIMemory.readHeader(blob, &cursor)")
            lines.append("return SwiftFFIMemory.readI64(blob, &cursor) != 0")
        case "String":
            lines.append("var cursor = 0; _ = SwiftFFIMemory.readHeader(blob, &cursor)")
            lines.append("let n = Int(SwiftFFIMemory.readI64(blob, &cursor))")
            lines.append("return String(decoding: SwiftFFIMemory.readSlice(blob, &cursor, n), as: UTF8.self)")
        case "[UInt8]":
            lines.append("var cursor = 0; _ = SwiftFFIMemory.readHeader(blob, &cursor)")
            lines.append("let n = Int(SwiftFFIMemory.readI64(blob, &cursor))")
            lines.append("return SwiftFFIMemory.readSlice(blob, &cursor, n)")
        default:
            if interfaces.contains(function.returnType) {
                lines.append("var cursor = 0; _ = SwiftFFIMemory.readHeader(blob, &cursor)")
                lines.append("return Swift\(function.returnType)(runtime: runtime, handle: UInt32(truncatingIfNeeded: SwiftFFIMemory.readI64(blob, &cursor)))")
            } else if isEnum(function.returnType) {
                lines.append("return decodeBlobEnum_\(function.returnType)(blob)")
            } else {
                lines.append("return decodeBlob_\(function.returnType)(blob)")
            }
        }
        return lines.map { indent + $0 }.joined(separator: "\n")
    }

    func emitSwiftHostWasm(_ module: FFIModule, moduleName: String) -> String {
        let interfaces = module.interfaceNames

        // Interfaces whose whole method surface crosses the dispatch channel
        // without a runtime in scope can be injected as dependencies
        // (docs/wasm_di.md) — the same subset rule as the C host, so every
        // native host offers the same dictionary.
        let diInterfaces = module.interfaces.filter { interface in
            interface.methods.allSatisfy { method in
                (isVoid(method.returnType) || hostDispatchable(method.returnType, allowInterfaces: false))
                    && method.parameters.allSatisfy { hostDispatchable($0.type, allowInterfaces: false) }
            }
        }

        var out = """
            // Generated by swift_ffi. Do not edit.
            //
            // Native-Swift host bindings for the `\(moduleName)` Swift module compiled to
            // a WebAssembly reactor — the peer of the generated TypeScript bindings. A
            // native process supplies a `SwiftFFIWasmEngine` (e.g. a WasmKit adapter) and
            // loads the reactor:
            //
            //   let bridge = try \(moduleName).load(engine: engine, wasm: bytes)
            //
            // Ownership follows the swift-java model: a `Swift<Proto>` wrapper owns a +1
            // handle to the Swift instance and releases it on `close()` (or when the
            // wrapper is deinited). Native implementations passed into wasm are parked in
            // the runtime's foreign registry as ordinal dispatchers; the guest proxy
            // releases its entry via the `foreign_release` import when ARC drops it.

            import SwiftFFIWasmHost

            """

        // Exported enums: raw-value copies of the Swift enums, crossing the
        // boundary as erased blobs of their raw value.
        for enumeration in module.enums {
            out += "\npublic enum \(enumeration.name): \(enumeration.rawType) {\n"
            for enumCase in enumeration.cases {
                if enumCase.rawValue.isEmpty {
                    out += "    case \(enumCase.name)\n"
                } else {
                    out += "    case \(enumCase.name) = \(enumCase.rawValue)\n"
                }
            }
            out += "}\n"
            if enumeration.rawType == "String" {
                out += """

                    func encodeBlobEnum_\(enumeration.name)(_ value: \(enumeration.name)) -> [UInt8] {
                        let u = Array(value.rawValue.utf8)
                        var bytes: [UInt8] = []
                        SwiftFFIMemory.appendI32(&bytes, 5); SwiftFFIMemory.appendI32(&bytes, 0)
                        SwiftFFIMemory.appendI64(&bytes, Int64(u.count)); bytes.append(contentsOf: u)
                        return bytes
                    }

                    func decodeBlobEnum_\(enumeration.name)(_ bytes: [UInt8]) -> \(enumeration.name) {
                        var cursor = 8
                        let count = Int(SwiftFFIMemory.readI64(bytes, &cursor))
                        let raw = String(decoding: SwiftFFIMemory.readSlice(bytes, &cursor, count), as: UTF8.self)
                        return \(enumeration.name)(rawValue: raw)!
                    }

                    """
            } else {
                out += """

                    func encodeBlobEnum_\(enumeration.name)(_ value: \(enumeration.name)) -> [UInt8] {
                        var bytes: [UInt8] = []
                        SwiftFFIMemory.appendI32(&bytes, 1); SwiftFFIMemory.appendI32(&bytes, 0)
                        SwiftFFIMemory.appendI64(&bytes, Int64(value.rawValue))
                        return bytes
                    }

                    func decodeBlobEnum_\(enumeration.name)(_ bytes: [UInt8]) -> \(enumeration.name) {
                        var cursor = 8
                        return \(enumeration.name)(rawValue: Int(SwiftFFIMemory.readI64(bytes, &cursor)))!
                    }

                    """
            }
        }

        // Structs: a plain value type + blob encode/decode helpers.
        for structure in module.structs {
            out += "\npublic struct \(structure.name) {\n"
            for field in structure.fields {
                out += "    public var \(field.name): \(hostType(field.type, interfaces: interfaces))\n"
            }
            let initParams = structure.fields
                .map { "\($0.name): \(hostType($0.type, interfaces: interfaces))" }
                .joined(separator: ", ")
            out += "    public init(\(initParams)) {\n"
            for field in structure.fields {
                out += "        self.\(field.name) = \(field.name)\n"
            }
            out += "    }\n}\n"
            out += emitHostStructHelpers(structure)
        }

        // Interface contracts + Swift-owned wrapper classes + dispatchers.
        for interface in module.interfaces {
            out += "\npublic protocol \(interface.name) {\n"
            for method in interface.methods {
                out += "    func \(method.name)(\(hostDeclParams(method.parameters, interfaces: interfaces)))\(hostEffects(method)) -> \(hostType(method.returnType, interfaces: interfaces))\n"
            }
            out += "}\n"

            out += """

                public final class Swift\(interface.name): \(interface.name) {
                    private var handle: UInt32
                    private let runtime: SwiftFFIHostRuntime

                    /// Takes ownership of a +1 handle.
                    init(runtime: SwiftFFIHostRuntime, handle: UInt32) {
                        self.runtime = runtime
                        self.handle = handle
                    }

                    func borrowHandle() -> UInt32 {
                        precondition(handle != 0, "\(interface.name) used after close()")
                        return handle
                    }

                    /// Releases the underlying Swift instance. Idempotent.
                    public func close() {
                        if handle != 0 {
                            runtime.call("\(releaseSymbol(interface))", [.i32(Int32(bitPattern: handle))])
                            handle = 0
                        }
                    }

                    deinit { close() }

                """
            for (ordinal, method) in interface.methods.enumerated() {
                out += hostInvokeMethod(interface, method, ordinal: ordinal, interfaces: interfaces)
                out += "\n"
            }
            out += "}\n"

            // The ordinal dispatcher wrapping a native implementation — the one
            // shape serving foreign parameters and injected dependencies (the
            // latter pass a nil runtime; their method surface never needs one).
            var cases: [String] = []
            for (ordinal, method) in interface.methods.enumerated() {
                cases.append(hostDispatchCase(method, ordinal: ordinal))
            }
            out += """

                /// Dispatches an ordinal-led blob call into a native `\(interface.name)`.
                func swiftFFIHostDispatcher_\(interface.name)(
                    _ runtime: SwiftFFIHostRuntime?, _ impl: any \(interface.name)
                ) -> ([UInt8]) -> [UInt8] {
                    return { blob in
                        var cursor = 0
                        _ = SwiftFFIMemory.readHeader(blob, &cursor)
                        let methodOrdinal = Int32(truncatingIfNeeded: SwiftFFIMemory.readI64(blob, &cursor))
                        switch methodOrdinal {
                \(cases.joined())default:
                            return []
                        }
                    }
                }

                """
        }

        // Dependency injection: builders pairing an implementation (or lazy
        // factory) with the interface's registry key — the Swift peer of the
        // TS `Dependencies` builders and the C host's dependency table.
        if !diInterfaces.isEmpty {
            out += """

                /// Builders wrapping host implementations for injection into the guest's
                /// `dependencies` dictionary (docs/wasm_di.md), as the runtime-generic
                /// `SwiftFFIDependency`. `provide` runs on the first dispatched call,
                /// deferring host-side construction to the guest's first use.
                public enum Dependencies {

                """
            for interface in diInterfaces {
                out += """
                        public static func \(lowerFirst(interface.name))(
                            lazy: Bool = true, _ provide: @escaping () -> any \(interface.name)
                        ) -> SwiftFFIDependency {
                            var impl: (any \(interface.name))?
                            return SwiftFFIDependency(
                                key: "\(registryKey(interface))",
                                registerSymbol: "\(registerSymbol(interface))",
                                lazy: lazy
                            ) { runtime, blob in
                                if impl == nil { impl = provide() }
                                return swiftFFIHostDispatcher_\(interface.name)(runtime, impl!)(blob)
                            }
                        }

                    """
            }
            out += "}\n"
        }

        // The module facade.
        out += """

            public final class \(moduleName) {
                public let runtime: SwiftFFIHostRuntime

                init(runtime: SwiftFFIHostRuntime) {
                    self.runtime = runtime
                }

            """
        for function in module.functions {
            if usesV2Features(function) {
                out += "    // \(function.name): generics/closures/Lazy/Result-params are not bridged to the Swift host yet.\n\n"
                continue
            }
            let asyncKeyword = function.isAsync ? "async " : ""
            let throwsKeyword = function.isThrowing ? "throws " : ""
            let effects = asyncKeyword + throwsKeyword
            let body: String
            if function.isAsync {
                body = hostAsyncBody(function, interfaces: interfaces, indent: "        ")
            } else {
                body = hostCallBody(
                    export: symbol(function),
                    parameters: function.parameters,
                    returnType: function.returnType,
                    interfaces: interfaces,
                    isThrowing: function.isThrowing,
                    indent: "        ")
            }
            out += """
                    public func \(function.name)(\(hostDeclParams(function.parameters, interfaces: interfaces))) \(effects)-> \(hostReturnType(function.returnType, interfaces: interfaces)) {
                \(body)
                    }

                """
        }

        // The loader: binds the fixed `swift_ffi` import set (every reactor
        // declares all five) and registers the interfaces' dependency-proxy
        // factories.
        let registerCalls = module.interfaces
            .map { "        runtime.call(\"\(registerSymbol($0))\", [])" }
            .joined(separator: "\n")
        let dependenciesParam = ",\n        dependencies: [String: SwiftFFIDependency] = [:]"
        out += """
                public static func load(
                    engine: any SwiftFFIWasmEngine, wasm: [UInt8]\(dependenciesParam)
                ) throws -> \(moduleName) {
                    let runtime = SwiftFFIHostRuntime(engine: engine)
                    runtime.dependencies = dependencies
                    try engine.instantiate(wasm: wasm, swiftFFIImports: runtime.standardImports())
            \(registerCalls.isEmpty ? "" : registerCalls + "\n")        return \(moduleName)(runtime: runtime)
                }
            }

            """

        return out
    }
}
