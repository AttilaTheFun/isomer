import SwiftSyntax

// The interface half of the expanded ABI: the box class, the ordinal-dispatch
// `_invoke` / `_release` entries consumers call Swift-owned instances
// through, the dispatcher-backed foreign proxy for CONSUMER-implemented
// instances (one class serves the native `bridge_closure` channel, the wasm
// foreign-registry channel, and injected dependencies alike), the dual-slot
// resolver function thunks marshal interface parameters with, and the
// `register` export that makes the interface injectable as a wasm dependency.
extension ABIEmitter {
    /// The peer declarations for one `@ExportedInterface`. A `@MainActor`
    /// protocol's foreign proxy is a nonisolated class (made anywhere, its
    /// methods witnessing the main-actor requirements) and its Swift-owned
    /// instances are called on the main actor.
    static func interfacePeers(
        protocolName name: String, methods: [ABIFunction], namespace: String?, mainActor: Bool = false
    ) -> [String] {
        [
            boxClass(name),
            foreignProxy(name, methods: methods, mainActor: mainActor),
            resolveDualSlot(name),
            resolveValue(name),
            invokeEntry(name, methods: methods, namespace: namespace, mainActor: mainActor),
            releaseEntry(name, namespace: namespace),
            registerEntry(name, namespace: namespace),
        ]
    }

    /// Boxes `any P` behind a retained opaque pointer. Public: expansions in
    /// OTHER modules reference it when they marshal this interface.
    static func boxClass(_ name: String) -> String {
        """
        public final class SwiftFFIBox_\(name) {
            public let value: any \(name)
            public init(_ value: any \(name)) { self.value = value }
        }
        """
    }

    /// The method signature of a proxy method satisfying the protocol
    /// requirement: original external labels, synthesized internal names.
    static func proxyMethodSignature(_ method: ABIFunction) -> (decl: String, valueNames: [String]) {
        var declParams: [String] = []
        var valueNames: [String] = []
        for (index, parameter) in method.parameters.enumerated() {
            let internalName = "arg\(index)"
            let type = concreteSwiftType(parameter.value)
            if parameter.label == "_" {
                declParams.append("_ \(internalName): \(type)")
            } else {
                declParams.append("\(parameter.label) \(internalName): \(type)")
            }
            valueNames.append(internalName)
        }
        let ret = method.returnValue.kind == .void
            ? "" : " -> \(concreteSwiftType(method.returnValue))"
        var effects = ""
        if method.isAsync { effects += " async" }
        if method.isThrowing { effects += " throws" }
        return ("(\(declParams.joined(separator: ", ")))\(effects)\(ret)", valueNames)
    }

    /// Wraps a consumer-implemented `P` behind any dispatcher (a native
    /// `bridge_closure`, a wasm foreign-registry id, or an injected
    /// dependency): method calls lead with the method ordinal and
    /// blob-encode their arguments.
    static func foreignProxy(_ name: String, methods: [ABIFunction], mainActor: Bool = false) -> String {
        var members: [String] = []
        for (ordinal, method) in methods.enumerated() {
            let (signature, valueNames) = proxyMethodSignature(method)
            // Throwing methods propagate the dispatcher's ERROR blob; the
            // others keep the historical force-try (a failing host is a bug).
            let tryWord = method.isThrowing ? "try" : "try!"
            var body: [String] = []
            body.append(
                "\(method.parameters.isEmpty && !method.isAsync ? "let" : "var") args = IsomerFFI.SwiftFFIBlob.encode(.int32(\(ordinal)))")
            if method.isAsync {
                // Async: a call id leads the arguments; the host answers later
                // through `swift_ffi_async_resume` (or immediately, by
                // returning the result blob from the dispatch itself).
                body.append("let callId = IsomerFFI.SwiftFFIAsyncCalls.next()")
                body.append("args += IsomerFFI.SwiftFFIBlob.encode(.int32(callId))")
            }
            for (index, parameter) in method.parameters.enumerated() {
                body.append("args += \(parameter.value.encodeExpr(valueNames[index]))")
            }
            if method.isAsync {
                body.append("let immediate = \(tryWord) dispatcher.invoke(args)")
                body.append("let resultBytes = \(tryWord) await IsomerFFI.SwiftFFIAsyncCalls.wait(callId, immediate: immediate)")
                if method.returnValue.kind == .void {
                    body.append("_ = resultBytes")
                } else {
                    body.append("return \(tryWord) \(method.returnValue.decodeBytesExpr("resultBytes"))")
                }
            } else if method.returnValue.kind == .void {
                body.append("_ = \(tryWord) dispatcher.invoke(args)")
            } else {
                body.append("let resultBytes = \(tryWord) dispatcher.invoke(args)")
                body.append("return \(tryWord) \(method.returnValue.decodeBytesExpr("resultBytes"))")
            }
            members.append(
                "    func \(method.name)\(signature) {\n"
                    + body.map { "        \($0)\n" }.joined()
                    + "    }")
        }
        return """
            /// Wraps a consumer-implemented `\(name)` (a dispatcher). Released
            /// when ARC drops the proxy.
            \(mainActor ? "nonisolated " : "")final class SwiftFFIForeign_\(name): \(name) {
                let dispatcher: any IsomerFFI.SwiftFFIDispatcher
                init(dispatcher: any IsomerFFI.SwiftFFIDispatcher) { self.dispatcher = dispatcher }

            \(members.joined(separator: "\n\n"))
            }
            """
    }

    /// The dual-slot resolver function thunks marshal interface parameters
    /// with: exactly one of (Swift box handle, foreign ref) is set.
    static func resolveDualSlot(_ name: String) -> String {
        """
        #if os(WASI)
        public func swiftFFIResolve_\(name)(_ handle: UnsafeMutableRawPointer?, _ foreign: Int32) -> any \(name) {
            if let handle {
                return Unmanaged<SwiftFFIBox_\(name)>.fromOpaque(handle).takeUnretainedValue().value
            }
            return SwiftFFIForeign_\(name)(dispatcher: IsomerFFI.SwiftFFIWasmDispatcher(id: foreign))
        }
        #else
        public func swiftFFIResolve_\(name)(_ handle: UnsafeMutableRawPointer?, _ foreign: UnsafeRawPointer?) -> any \(name) {
            if let handle {
                return Unmanaged<SwiftFFIBox_\(name)>.fromOpaque(handle).takeUnretainedValue().value
            }
            return SwiftFFIForeign_\(name)(dispatcher: IsomerFFI.SwiftFFIClosureBox(copyingRaw: foreign!))
        }
        #endif
        """
    }

    /// The erased-position resolver: HANDLE (a Swift box, borrowed) or
    /// FOREIGN (a consumer implementation) inside a blob → `any P`.
    static func resolveValue(_ name: String) -> String {
        """
        public func swiftFFIResolve_\(name)(_ value: IsomerFFI.BridgeValue) throws -> any \(name) {
            switch value {
            case .handle(let bits, _):
                guard let pointer = UnsafeMutableRawPointer(bitPattern: UInt(bits)) else {
                    throw IsomerFFI.BridgeDecodingError("nil \(name) handle")
                }
                return Unmanaged<SwiftFFIBox_\(name)>.fromOpaque(pointer).takeUnretainedValue().value
            case .foreign(let bits, _):
                #if os(WASI)
                return SwiftFFIForeign_\(name)(dispatcher: IsomerFFI.SwiftFFIWasmDispatcher(id: Int32(truncatingIfNeeded: bits)))
                #else
                guard let pointer = UnsafeRawPointer(bitPattern: UInt(bits)) else {
                    throw IsomerFFI.BridgeDecodingError("nil \(name) foreign ref")
                }
                return SwiftFFIForeign_\(name)(dispatcher: IsomerFFI.SwiftFFIClosureBox(copyingRaw: pointer))
                #endif
            default:
                throw IsomerFFI.BridgeDecodingError("expected \(name), got \\(value)")
            }
        }
        """
    }

    /// The ordinal-dispatch entry consumers call Swift-owned instances
    /// through: `args` is a borrowed blob sequence, the return is a +1 box of
    /// the result blob (a VOID blob for void; an ERROR blob on failure).
    static func invokeEntry(_ name: String, methods: [ABIFunction], namespace: String?, mainActor: Bool = false) -> String {
        var cases: [String] = []
        for (ordinal, method) in methods.enumerated() {
            var body: [String] = []
            // Async methods take a leading call id (the consumer completes
            // through `async_complete` on wasm).
            let argumentCount = method.parameters.count + (method.isAsync ? 1 : 0)
            body.append("guard arguments.count == \(argumentCount) else {")
            body.append(
                "    throw IsomerFFI.BridgeDecodingError(\"\(name).\(method.name) expects \(argumentCount) arguments, got \\(arguments.count)\")")
            body.append("}")
            var values: [String] = []
            let offset = method.isAsync ? 1 : 0
            if method.isAsync {
                body.append("let callId = try Int32(bridgeValue: arguments[0])")
            }
            for (index, parameter) in method.parameters.enumerated() {
                body.append("let a\(index) = try \(parameter.value.decodeValueExpr("arguments[\(index + offset)]"))")
                values.append("a\(index)")
            }
            let rawCall = method.call("value.\(method.name)", values: values)
            // `call` already leads with its `try` and `await`.
            let call = rawCall
            let resultBlob: String
            if method.isAsync {
                let successBlob = method.returnValue.kind == .void
                    ? "IsomerFFI.SwiftFFIBlob.encode(.void)" : method.returnValue.encodeExpr("result")
                let invoke = method.returnValue.kind == .void ? call : "let result = \(call)"
                body.append("#if os(WASI)")
                body.append("IsomerFFI.swiftFFIInstallExecutor()")
                body.append(mainActor ? "Task { @MainActor in" : "Task {")
                body.append("    do {")
                body.append("        \(invoke)")
                body.append("        IsomerFFI.swiftFFIAsyncComplete(callId, \(successBlob))")
                body.append("    } catch {")
                body.append("        IsomerFFI.swiftFFIAsyncComplete(callId, IsomerFFI.SwiftFFIBlob.encodeError(String(describing: error)))")
                body.append("    }")
                body.append("}")
                // The return inside the wasm branch: after the other's throw
                // it would never run (a warning, an error where warnings are).
                body.append(
                    "return Unmanaged.passRetained(IsomerFFI.SwiftFFIStringBox(bytes: IsomerFFI.SwiftFFIBlob.encode(.void))).toOpaque()")
                body.append("#else")
                body.append("_ = callId")
                body.append("throw IsomerFFI.BridgeDecodingError(\"async interface methods on Swift-owned instances complete through the wasm async_complete import only\")")
                body.append("#endif")
                resultBlob = ""
            } else if method.returnValue.kind == .void {
                body.append(call)
                resultBlob = "IsomerFFI.SwiftFFIBlob.encode(.void)"
            } else {
                body.append("let result = \(call)")
                resultBlob = method.returnValue.encodeExpr("result")
            }
            if !method.isAsync {
                body.append(
                    "return Unmanaged.passRetained(IsomerFFI.SwiftFFIStringBox(bytes: \(resultBlob))).toOpaque()")
            }
            cases.append(
                "        case \(ordinal):\n"
                    + body.map { "            \($0)\n" }.joined())
        }
        let dispatch = """
                do {
                    let arguments = try IsomerFFI.SwiftFFIBlob.decodeSequence(bytes)
                    switch ordinal {
            \(cases.joined(separator: "\n"))
                    default:
                        throw IsomerFFI.BridgeDecodingError("unknown \(name) method ordinal \\(ordinal)")
                    }
                } catch {
                    return Unmanaged.passRetained(IsomerFFI.SwiftFFIStringBox(bytes: IsomerFFI.SwiftFFIBlob.encodeError(String(describing: error)))).toOpaque()
                }
            """
        let entry = "@c(\(ABIModel.cSymbol(namespace: namespace, "\(name)_invoke")))\n"
            + "public func swiftFFIInvoke_\(name)(_ handle: UnsafeMutableRawPointer, _ ordinal: Int32, _ args: UnsafeRawPointer?, _ args_len: Int32) -> UnsafeMutableRawPointer {\n"
        guard mainActor else {
            return entry + """
                    let value = Unmanaged<SwiftFFIBox_\(name)>.fromOpaque(handle).takeUnretainedValue().value
                    let bytes = IsomerFFI.SwiftFFIBridge.bytes(args, args_len)
                \(dispatch)
                }
                """
        }
        // A main-actor protocol's instance is called on the main actor (the
        // entry is reached on the main thread, as the host's calls are):
        // only Sendable values (the handle's and the result's bits, the
        // argument bytes) cross into the isolated dispatch.
        return entry + """
                let handleBits = UInt(bitPattern: handle)
                let bytes = IsomerFFI.SwiftFFIBridge.bytes(args, args_len)
                let resultBits = MainActor.assumeIsolated {
                    UInt(bitPattern: swiftFFIInvokeIsolated_\(name)(handleBits, ordinal, bytes))
                }
                return UnsafeMutableRawPointer(bitPattern: resultBits)!
            }

            @MainActor
            private func swiftFFIInvokeIsolated_\(name)(_ handleBits: UInt, _ ordinal: Int32, _ bytes: [UInt8]) -> UnsafeMutableRawPointer {
                let value = Unmanaged<SwiftFFIBox_\(name)>.fromOpaque(UnsafeMutableRawPointer(bitPattern: handleBits)!).takeUnretainedValue().value
            \(dispatch)
            }
            """
    }

    static func releaseEntry(_ name: String, namespace: String?) -> String {
        """
        @c(\(ABIModel.cSymbol(namespace: namespace, "\(name)_release")))
        public func swiftFFIRelease_\(name)(_ handle: UnsafeMutableRawPointer) {
            Unmanaged<SwiftFFIBox_\(name)>.fromOpaque(handle).release()
        }
        """
    }

    /// Registers the interface's dependency-proxy factory (docs/wasm_di.md).
    /// Hosts that inject dependencies call this export at setup; the guest's
    /// `dependencies` dictionary then resolves `dependency_get` answers whose
    /// registry key matches into typed proxies.
    static func registerEntry(_ name: String, namespace: String?) -> String {
        let key = ABIModel.cSymbol(namespace: namespace, name)
        return """
            @c(\(ABIModel.cSymbol(namespace: namespace, "register_\(name)")))
            public func swiftFFIRegister_\(name)() {
                #if os(WASI)
                // A registered interface may be awaited: make sure Swift
                // concurrency jobs reach the host's pump from the start.
                IsomerFFI.swiftFFIInstallExecutor()
                #endif
                IsomerFFI.swiftFFIRegisterDependencyFactory(
                    key: "\(key)",
                    factory: IsomerFFI.SwiftFFIDependencyFactory(
                        direct: { dispatcher in
                            SwiftFFIForeign_\(name)(dispatcher: dispatcher) as (any \(name))
                        },
                        lazy: { dispatcher in
                            IsomerFFI.Lazy<any \(name)> { SwiftFFIForeign_\(name)(dispatcher: dispatcher) }
                        }))
            }
            """
    }
}
