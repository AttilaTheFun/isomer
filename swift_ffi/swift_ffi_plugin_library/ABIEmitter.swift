import SwiftSyntax

// Emits the macro-expanded C ABI: `@c(swift_ffi_[<ns>_]<name>)` entry thunks
// for functions and the box/proxy/invoke/release/register peers for
// interfaces. The concrete ABI stays flat (scalars native, strings/bytes as
// (ptr, len) in / +1 box out, interfaces as dual-slot handles at function
// boundaries); everything erased — struct/enum copies, Result values, generic
// arguments, closure arguments, Lazy payloads, interface METHOD arguments —
// crosses as a self-describing blob (see swift_abi.h).
//
// Two flavors where the shapes differ, split by `#if os(WASI)` inside the
// expansion: on wasm, closures/foreign objects travel as foreign-registry ids
// dispatched through the fixed `swift_ffi.closure_invoke` import; natively
// they travel as `bridge_closure` vtable pointers (opaque `UnsafeRawPointer`
// in the expansion — macro expansions cannot import the SwiftABI clang
// module, so every C type stays behind the `SwiftFFI` API).
enum ABIEmitter {
    // MARK: - Parameter marshaling

    struct MarshaledParameter {
        var cParams: [String] = []
        var prelude: [String] = []
        var value: String
    }

    /// The typed Swift closure spelling of a closure parameter.
    static func closureSpelling(_ closure: ABIClosure) -> String {
        let params = closure.parameters.map { ABIModel.swiftSpelling($0.spelling) }
        let ret = closure.returnValue.kind == .void
            ? "Void" : ABIModel.swiftSpelling(closure.returnValue.spelling)
        return "(\(params.joined(separator: ", "))) -> \(ret)"
    }

    /// Emits the typed Swift closure wrapping a dispatcher (`dispatcherName`
    /// bound in scope). Usable both in concrete thunks and inside generic
    /// trampolines (where element types may name the bound type parameters).
    static func closureWrapper(
        valueName: String, dispatcherName: String, closure: ABIClosure
    ) -> [String] {
        var lines: [String] = []
        let elements = closure.parameters.enumerated().map { "a\($0.offset)" }
        let signature = elements.isEmpty ? "" : "\(elements.joined(separator: ", ")) in"
        lines.append("let \(valueName): \(closureSpelling(closure)) = { \(signature)")
        if closure.parameters.isEmpty {
            lines.append("    let args: [UInt8] = []")
        } else {
            lines.append("    var args: [UInt8] = []")
            for element in elements {
                lines.append("    args += IsomerFFI.SwiftFFIBlob.encode((\(element)).bridgeValue)")
            }
        }
        if closure.returnValue.kind == .void {
            lines.append("    _ = try! \(dispatcherName).invoke(args)")
        } else {
            lines.append("    let resultBytes = try! \(dispatcherName).invoke(args)")
            lines.append("    return try! \(closure.returnValue.decodeBytesExpr("resultBytes"))")
        }
        lines.append("}")
        return lines
    }

    /// Marshals one parameter into C-ABI parameter declarations, optional
    /// prelude statements, and the Swift value expression.
    static func marshal(_ parameter: ABIParameter, index: Int, wasm: Bool) -> MarshaledParameter {
        let p = "p\(index)"
        if let closure = parameter.closure {
            var m = MarshaledParameter(value: "v\(index)")
            if wasm {
                m.cParams = ["_ \(p): Int32"]
                m.prelude.append(
                    "let dispatcher\(index): any IsomerFFI.SwiftFFIDispatcher = IsomerFFI.SwiftFFIWasmDispatcher(id: \(p))")
            } else {
                m.cParams = ["_ \(p): UnsafeRawPointer?"]
                m.prelude.append(
                    "let dispatcher\(index): any IsomerFFI.SwiftFFIDispatcher = IsomerFFI.SwiftFFIClosureBox(copyingRaw: \(p)!)")
            }
            m.prelude.append(
                contentsOf: closureWrapper(
                    valueName: "v\(index)", dispatcherName: "dispatcher\(index)", closure: closure))
            return m
        }
        switch parameter.value.kind {
        case .scalar(let type):
            return MarshaledParameter(cParams: ["_ \(p): \(type)"], value: p)
        case .string:
            return MarshaledParameter(
                cParams: ["_ \(p): UnsafeRawPointer?", "_ \(p)_len: Int32"],
                value: "IsomerFFI.SwiftFFIBridge.string(\(p), \(p)_len)")
        case .bytes:
            return MarshaledParameter(
                cParams: ["_ \(p): UnsafeRawPointer?", "_ \(p)_len: Int32"],
                value: "IsomerFFI.SwiftFFIBridge.bytes(\(p), \(p)_len)")
        case .interface(let name):
            let foreignParam = wasm ? "_ \(p)_foreign: Int32" : "_ \(p)_foreign: UnsafeRawPointer?"
            return MarshaledParameter(
                cParams: ["_ \(p): UnsafeMutableRawPointer?", foreignParam],
                value: "swiftFFIResolve_\(name)(\(p), \(p)_foreign)")
        case .generic, .blob:
            return MarshaledParameter(
                cParams: ["_ \(p): UnsafeRawPointer?", "_ \(p)_len: Int32"],
                value: "try! \(ABIModel.swiftSpelling(parameter.value.spelling))(bridgeValue: IsomerFFI.SwiftFFIBlob.decode(\(p), \(p)_len))")
        case .void:
            return MarshaledParameter(value: p)
        }
    }

    /// Whether a function's C signature differs between wasm and native (it
    /// carries closures, interface dual slots, or an async entry).
    static func needsPlatformSplit(_ function: ABIFunction) -> Bool {
        if function.isAsync { return true }
        return function.parameters.contains { parameter in
            if parameter.closure != nil { return true }
            if case .interface = parameter.value.kind { return true }
            return false
        }
    }

    /// Wraps per-platform variants in `#if os(WASI)` when they differ.
    static func platformSplit(_ function: ABIFunction, _ emit: (Bool) -> String) -> String {
        guard needsPlatformSplit(function) else { return emit(false) }
        return """
            #if os(WASI)
            \(emit(true))
            #else
            \(emit(false))
            #endif
            """
    }

    // MARK: - Function entry thunks

    /// The peer declarations for one `@ExportedFunction`.
    static func functionPeers(_ function: ABIFunction, namespace: String?) throws -> [String] {
        if function.isAsync {
            return [platformSplit(function) { wasm in
                asyncEntry(function, namespace: namespace, wasm: wasm)
            }]
        }
        if !function.genericParameters.isEmpty {
            return [
                platformSplit(function) { wasm in
                    genericTrampoline(function, wasm: wasm)
                },
                platformSplit(function) { wasm in
                    genericEntry(function, namespace: namespace, wasm: wasm)
                },
            ]
        }
        return [platformSplit(function) { wasm in
            concreteEntry(function, namespace: namespace, wasm: wasm)
        }]
    }

    /// One concrete (non-generic, non-async) entry thunk.
    static func concreteEntry(_ function: ABIFunction, namespace: String?, wasm: Bool) -> String {
        var cParams: [String] = []
        var prelude: [String] = []
        var values: [String] = []
        for (index, parameter) in function.parameters.enumerated() {
            let m = marshal(parameter, index: index, wasm: wasm)
            cParams.append(contentsOf: m.cParams)
            prelude.append(contentsOf: m.prelude)
            values.append(m.value)
        }
        if function.isThrowing {
            cParams.append("_ error_out: UnsafeMutablePointer<UnsafeMutableRawPointer?>?")
        }

        let callExpr = function.call(function.name, values: values)
        let (cReturn, marshalled, zero) = returnMarshal(function, callExpr: callExpr)

        let preludeLines = prelude.map { "    \($0)\n" }.joined()
        let body: String
        if function.isThrowing {
            body = """
                do {
                        \(marshalled)
                    } catch {
                        error_out?.pointee = Unmanaged.passRetained(IsomerFFI.SwiftFFIStringBox(String(describing: error))).toOpaque()
                        \(zero)
                    }
                """
        } else {
            body = marshalled
        }

        return """
            @c(\(ABIModel.cSymbol(namespace: namespace, function.name)))
            public func swift_ffi_\(function.name)(\(cParams.joined(separator: ", ")))\(cReturn) {
            \(preludeLines)    \(body)
            }
            """
    }

    /// The C return type, the marshaled return statement, and the throwing
    /// zero-return for a concrete call.
    static func returnMarshal(
        _ function: ABIFunction, callExpr: String
    ) -> (cReturn: String, marshalled: String, zero: String) {
        let optional = function.isThrowing ? "?" : ""
        if function.returnsLazy {
            let encode = function.returnValue.encodeExpr("lazyResult.value")
            return (
                " -> UnsafeMutableRawPointer\(optional)",
                """
                let lazyResult = \(callExpr)
                        return Unmanaged.passRetained(IsomerFFI.SwiftFFILazyBox { \(encode) }).toOpaque()
                """,
                "return nil"
            )
        }
        switch function.returnValue.kind {
        case .void:
            return ("", callExpr, "return")
        case .scalar(let type):
            return (
                " -> \(type)", "return \(callExpr)",
                type == "Bool" ? "return false" : "return 0")
        case .string:
            return (
                " -> UnsafeMutableRawPointer\(optional)",
                "return Unmanaged.passRetained(IsomerFFI.SwiftFFIStringBox(\(callExpr))).toOpaque()",
                "return nil")
        case .bytes:
            return (
                " -> UnsafeMutableRawPointer\(optional)",
                "return Unmanaged.passRetained(IsomerFFI.SwiftFFIStringBox(bytes: \(callExpr))).toOpaque()",
                "return nil")
        case .interface(let name):
            return (
                " -> UnsafeMutableRawPointer\(optional)",
                "return Unmanaged.passRetained(SwiftFFIBox_\(name)(\(callExpr))).toOpaque()",
                "return nil")
        case .generic, .blob:
            return (
                " -> UnsafeMutableRawPointer\(optional)",
                "return Unmanaged.passRetained(IsomerFFI.SwiftFFIStringBox(bytes: \(function.returnValue.encodeExpr("(\(callExpr))")))).toOpaque()",
                "return nil")
        }
    }

    // MARK: - Generic functions

    /// The generic trampoline: re-types erased arguments via an
    /// implicitly-opened existential (the first occurrence of each type
    /// parameter binds it; later occurrences decode inside, where the
    /// archetype is in scope).
    static func genericTrampoline(_ function: ABIFunction, wasm: Bool) -> String {
        let generics = Set(function.genericParameters)
        var seen: Set<String> = []
        var trampolineParams: [String] = []
        var insideDecodes: [String] = []
        var callValues: [String] = []

        for (index, parameter) in function.parameters.enumerated() {
            let p = "p\(index)"
            if case .generic(let name) = parameter.value.kind {
                if seen.insert(name).inserted {
                    trampolineParams.append("_ \(p): \(name)")
                    callValues.append(p)
                } else {
                    trampolineParams.append("_ \(p): IsomerFFI.BridgeValue")
                    insideDecodes.append("let v\(index) = try \(name)(bridgeValue: \(p))")
                    callValues.append("v\(index)")
                }
                continue
            }
            if let closure = parameter.closure {
                trampolineParams.append("_ \(p): any IsomerFFI.SwiftFFIDispatcher")
                insideDecodes.append(
                    contentsOf: closureWrapper(
                        valueName: "v\(index)", dispatcherName: p, closure: closure))
                callValues.append("v\(index)")
                continue
            }
            trampolineParams.append("_ \(p): \(concreteSwiftType(parameter.value))")
            callValues.append(p)
        }
        _ = generics

        let genericClause = function.genericParameters
            .map { "\($0): IsomerFFI.Bridgeable" }.joined(separator: ", ")
        let call = function.call(function.name, values: callValues)

        let returnsErased: Bool
        if case .generic = function.returnValue.kind { returnsErased = true } else { returnsErased = false }
        let trampolineReturn: String
        var trampolineBody = insideDecodes
        if function.returnsLazy {
            trampolineReturn = " -> IsomerFFI.SwiftFFILazyBox"
            trampolineBody.append("let lazyResult = \(call)")
            trampolineBody.append(
                "return IsomerFFI.SwiftFFILazyBox { \(function.returnValue.encodeExpr("lazyResult.value")) }")
        } else if returnsErased || function.returnValue.isBlobLike {
            trampolineReturn = " -> [UInt8]"
            trampolineBody.append("let result = \(call)")
            trampolineBody.append("return \(function.returnValue.encodeExpr("result"))")
        } else if function.returnValue.kind == .void {
            trampolineReturn = ""
            trampolineBody.append(call)
        } else {
            trampolineReturn = " -> \(function.returnValue.spelling)"
            trampolineBody.append("return \(call)")
        }

        return """
            private func swiftFFIThunk_\(function.name)<\(genericClause)>(\(trampolineParams.joined(separator: ", "))) throws\(trampolineReturn) {
            \(trampolineBody.map { "    \($0)\n" }.joined())}
            """
    }

    /// The typed Swift spelling of a concrete parameter inside a generic
    /// function's trampoline.
    static func concreteSwiftType(_ value: ABIValue) -> String {
        switch value.kind {
        case .interface(let name): return "any \(name)"
        default: return ABIModel.swiftSpelling(value.spelling)
        }
    }

    /// The generic C entry: decode/open, call the trampoline, marshal.
    static func genericEntry(_ function: ABIFunction, namespace: String?, wasm: Bool) -> String {
        var seen: Set<String> = []
        var cParams: [String] = []
        var entryPrelude: [String] = []
        var trampolineArgs: [String] = []

        for (index, parameter) in function.parameters.enumerated() {
            let p = "p\(index)"
            if case .generic = parameter.value.kind {
                cParams.append("_ \(p): UnsafeRawPointer?")
                cParams.append("_ \(p)_len: Int32")
                if case .generic(let name) = parameter.value.kind, seen.insert(name).inserted {
                    entryPrelude.append(
                        "let opened\(index) = try IsomerFFI.SwiftFFIBlob.bindAny(IsomerFFI.SwiftFFIBlob.decode(\(p), \(p)_len))")
                    trampolineArgs.append("opened\(index)")
                } else {
                    entryPrelude.append(
                        "let erased\(index) = try IsomerFFI.SwiftFFIBlob.decode(\(p), \(p)_len)")
                    trampolineArgs.append("erased\(index)")
                }
                continue
            }
            if parameter.closure != nil {
                if wasm {
                    cParams.append("_ \(p): Int32")
                    entryPrelude.append(
                        "let dispatcher\(index): any IsomerFFI.SwiftFFIDispatcher = IsomerFFI.SwiftFFIWasmDispatcher(id: \(p))")
                } else {
                    cParams.append("_ \(p): UnsafeRawPointer?")
                    entryPrelude.append(
                        "let dispatcher\(index): any IsomerFFI.SwiftFFIDispatcher = IsomerFFI.SwiftFFIClosureBox(copyingRaw: \(p)!)")
                }
                trampolineArgs.append("dispatcher\(index)")
                continue
            }
            let m = marshal(parameter, index: index, wasm: wasm)
            cParams.append(contentsOf: m.cParams)
            entryPrelude.append(contentsOf: m.prelude)
            entryPrelude.append("let concrete\(index): \(concreteSwiftType(parameter.value)) = \(m.value)")
            trampolineArgs.append("concrete\(index)")
        }

        let trampolineCall = "try swiftFFIThunk_\(function.name)(\(trampolineArgs.joined(separator: ", ")))"
        let returnsErased: Bool
        if case .generic = function.returnValue.kind { returnsErased = true } else { returnsErased = false }
        let cReturn: String
        let marshalled: String
        let zero: String
        let optional = function.isThrowing ? "?" : ""
        if function.returnsLazy {
            cReturn = " -> UnsafeMutableRawPointer\(optional)"
            marshalled = "return Unmanaged.passRetained(\(trampolineCall)).toOpaque()"
            zero = "return nil"
        } else if returnsErased || function.returnValue.isBlobLike {
            cReturn = " -> UnsafeMutableRawPointer\(optional)"
            marshalled = "return Unmanaged.passRetained(IsomerFFI.SwiftFFIStringBox(bytes: \(trampolineCall))).toOpaque()"
            zero = "return nil"
        } else {
            switch function.returnValue.kind {
            case .void:
                cReturn = ""
                marshalled = trampolineCall
                zero = "return"
            case .scalar(let type):
                cReturn = " -> \(type)"
                marshalled = "return \(trampolineCall)"
                zero = type == "Bool" ? "return false" : "return 0"
            case .string:
                cReturn = " -> UnsafeMutableRawPointer\(optional)"
                marshalled = "return Unmanaged.passRetained(IsomerFFI.SwiftFFIStringBox(\(trampolineCall))).toOpaque()"
                zero = "return nil"
            case .bytes:
                cReturn = " -> UnsafeMutableRawPointer\(optional)"
                marshalled = "return Unmanaged.passRetained(IsomerFFI.SwiftFFIStringBox(bytes: \(trampolineCall))).toOpaque()"
                zero = "return nil"
            case .interface(let name):
                cReturn = " -> UnsafeMutableRawPointer\(optional)"
                marshalled = "return Unmanaged.passRetained(SwiftFFIBox_\(name)(\(trampolineCall))).toOpaque()"
                zero = "return nil"
            case .generic, .blob:
                cReturn = " -> UnsafeMutableRawPointer\(optional)"
                marshalled = "return Unmanaged.passRetained(IsomerFFI.SwiftFFIStringBox(bytes: \(trampolineCall))).toOpaque()"
                zero = "return nil"
            }
        }

        if function.isThrowing {
            cParams.append("_ error_out: UnsafeMutablePointer<UnsafeMutableRawPointer?>?")
        }
        // The entry always wraps in do/catch: decode/open can throw even for
        // non-throwing functions (a contract violation surfaces as a trap).
        let catchBody: String
        if function.isThrowing {
            catchBody = """
                    error_out?.pointee = Unmanaged.passRetained(IsomerFFI.SwiftFFIStringBox(String(describing: error))).toOpaque()
                        \(zero)
                """
        } else {
            catchBody = "        fatalError(\"swift_ffi bridge contract violation: \\(error)\")"
        }
        return """
            @c(\(ABIModel.cSymbol(namespace: namespace, function.name)))
            public func swift_ffi_\(function.name)(\(cParams.joined(separator: ", ")))\(cReturn) {
                do {
            \(entryPrelude.map { "        \($0)\n" }.joined())        \(marshalled)
                } catch {
            \(catchBody)
                }
            }
            """
    }

    // MARK: - Async entries

    /// One async entry: marshals eagerly (pointers are only valid for the
    /// call), starts a `Task`, and completes with a blob — through the fixed
    /// `swift_ffi.async_complete` import on wasm, or a trailing
    /// `bridge_closure` completion dispatcher natively.
    static func asyncEntry(_ function: ABIFunction, namespace: String?, wasm: Bool) -> String {
        var cParams: [String] = wasm ? ["_ callId: Int32"] : []
        var bindings: [String] = []
        var values: [String] = []
        for (index, parameter) in function.parameters.enumerated() {
            let m = marshal(parameter, index: index, wasm: wasm)
            cParams.append(contentsOf: m.cParams)
            bindings.append(contentsOf: m.prelude)
            bindings.append("let bound\(index) = \(m.value)")
            values.append("bound\(index)")
        }
        if !wasm {
            cParams.append("_ completion: UnsafeRawPointer?")
            bindings.append("let completionBox = IsomerFFI.SwiftFFIClosureBox(copyingRaw: completion!)")
        }

        let call = function.call(function.name, values: values)
        let successBlob: String
        if function.returnValue.kind == .void {
            successBlob = "IsomerFFI.SwiftFFIBlob.encode(.void)"
        } else {
            successBlob = function.returnValue.encodeExpr("result")
        }
        let invoke = function.returnValue.kind == .void ? call : "let result = \(call)"
        let deliver = wasm
            ? { (blob: String) in "IsomerFFI.swiftFFIAsyncComplete(callId, \(blob))" }
            : { (blob: String) in "_ = try? completionBox.invoke(\(blob))" }

        let taskBody: String
        if function.isThrowing {
            taskBody = """
                    do {
                            \(invoke)
                            \(deliver(successBlob))
                        } catch {
                            \(deliver("IsomerFFI.SwiftFFIBlob.encodeError(String(describing: error))"))
                        }
            """
        } else {
            taskBody = """
                    \(invoke)
                        \(deliver(successBlob))
            """
        }

        let installExecutor = wasm ? "    IsomerFFI.swiftFFIInstallExecutor()\n" : ""
        return """
            @c(\(ABIModel.cSymbol(namespace: namespace, function.name)))
            public func swift_ffi_\(function.name)(\(cParams.joined(separator: ", "))) {
            \(installExecutor)\(bindings.map { "    \($0)\n" }.joined())    Task {
                \(taskBody)
                }
            }
            """
    }
}
