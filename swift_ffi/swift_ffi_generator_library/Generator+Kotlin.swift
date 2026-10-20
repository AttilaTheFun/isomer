import Foundation
import SwiftFFIIRLibrary

// The Kotlin backend: a facade object + interface wrapper classes calling the
// shared C ABI through the generated JNI adapter (docs/bridge_v2.md). Erased
// values (structs, Result values, generic arguments, closure arguments, Lazy
// payloads) cross as blob ByteArrays via the swiftffi.BridgeBlob codec;
// callback objects (closures, foreign interface dispatchers, async
// completions) cross as swiftffi.SwiftClosure.
extension Generator {
    func kotlinType(_ swift: String, generics: Set<String> = []) -> String {
        switch swift {
        case "Int": return "Long"
        case "Int32": return "Int"
        case "Double": return "Double"
        case "Bool": return "Boolean"
        case "String": return "String"
        case "[UInt8]": return "ByteArray"
        case "[String]": return "List<String>"
        case "Void", "()": return "Unit"
        default:
            if generics.contains(swift) { return swift }
            if isStruct(swift) || isEnum(swift) { return swift }
            if let success = resultSuccess(swift) {
                return "Result<\(kotlinType(success, generics: generics))>"
            }
            return module.interfaceNames.contains(swift) ? swift : "Long"
        }
    }

    /// The raw external's parameter type for one bridged value.
    func kotlinRawType(_ swift: String, generics: Set<String> = []) -> String {
        switch swift {
        case "Int": return "Long"
        case "Int32": return "Int"
        case "Double": return "Double"
        case "Bool": return "Boolean"
        case "String", "[UInt8]": return "ByteArray"
        case "Void", "()": return "Unit"
        default:
            if isBlob(swift, generics: generics) { return "ByteArray" }
            return "Long"
        }
    }

    /// Declared return types name the concrete Swift-owned wrapper (so `close()`
    /// and `use { }` are visible); parameters accept the interface contract,
    /// which consumers may implement themselves.
    func kotlinReturnType(_ swift: String, generics: Set<String> = []) -> String {
        module.interfaceNames.contains(swift) ? "Swift\(swift)" : kotlinType(swift, generics: generics)
    }

    /// Kotlin hard keywords that cannot be used bare as identifiers.
    static let kotlinKeywords: Set<String> = [
        "as", "break", "class", "continue", "do", "else", "false", "for", "fun",
        "if", "in", "interface", "is", "null", "object", "package", "return",
        "super", "this", "throw", "true", "try", "typealias", "typeof", "val",
        "var", "when", "while",
    ]

    func kotlinParameterName(_ label: String, _ index: Int) -> String {
        if label == "_" { return "arg\(index)" }
        return Self.kotlinKeywords.contains(label) ? "`\(label)`" : label
    }

    /// The Kotlin parameter declaration for one bridged parameter.
    func kotlinParamDecl(
        _ parameter: FFIParameter, index: Int, generics: Set<String>
    ) -> String {
        let name = kotlinParameterName(parameter.label, index)
        if let closure = parameter.closure {
            let elements = closure.parameters.map { kotlinType($0, generics: generics) }
            let ret = kotlinType(closure.returnType, generics: generics)
            return "\(name): (\(elements.joined(separator: ", "))) -> \(ret)"
        }
        return "\(name): \(kotlinType(parameter.type, generics: generics))"
    }

    /// The raw argument expression(s) for one idiomatic Kotlin value.
    func kotlinRawArgs(
        _ parameter: FFIParameter, index: Int, generics: Set<String>
    ) -> [String] {
        let name = kotlinParameterName(parameter.label, index)
        if let closure = parameter.closure {
            return [kotlinClosureWrapper(name, closure, generics: generics)]
        }
        switch parameter.type {
        case "String": return ["\(name).toByteArray(Charsets.UTF_8)"]
        case "Int", "Int32", "Double", "Bool", "[UInt8]": return [name]
        default:
            if isEnum(parameter.type) {
                return ["swiftffi.BridgeBlob.encode(\(name).rawValue)"]
            }
            if isBlob(parameter.type, generics: generics) {
                return ["swiftffi.BridgeBlob.encode(\(name))"]
            }
            if module.interfaceNames.contains(parameter.type) {
                return [
                    "(\(name) as? Swift\(parameter.type))?.borrowHandle() ?: 0L",
                    "if (\(name) is Swift\(parameter.type)) null else ForeignDispatcher_\(parameter.type)(\(name))",
                ]
            }
            return [name]
        }
    }

    /// Wraps a Kotlin lambda in the SwiftClosure dispatcher shape.
    func kotlinClosureWrapper(
        _ name: String, _ closure: FFIClosureType, generics: Set<String>
    ) -> String {
        var body: [String] = []
        if !closure.parameters.isEmpty {
            body.append("val r = swiftffi.BlobReader(args)")
        }
        var callArgs: [String] = []
        for (index, element) in closure.parameters.enumerated() {
            if element.hasPrefix("Result<") {
                body.append(
                    "val a\(index) = swiftffi.BridgeBlob.asResult(swiftffi.BridgeBlob.decodeValue(r)) as \(kotlinType(element, generics: generics))")
            } else {
                body.append(
                    "val a\(index) = swiftffi.BridgeBlob.decodeValue(r) as \(kotlinType(element, generics: generics))")
            }
            callArgs.append("a\(index)")
        }
        let call = "\(name)(\(callArgs.joined(separator: ", ")))"
        if isVoid(closure.returnType) {
            body.append("\(call)")
            body.append("ByteArray(0)")
        } else {
            body.append("swiftffi.BridgeBlob.encode(\(call))")
        }
        return "swiftffi.SwiftClosure { args -> \(body.joined(separator: "; ")) }"
    }

    /// Converts a raw return value to its idiomatic Kotlin form.
    func rawToKotlin(
        _ swift: String, _ expr: String, generics: Set<String> = []
    ) -> String {
        switch swift {
        case "String": return "String(\(expr), Charsets.UTF_8)"
        case "Int", "Int32", "Double", "Bool", "[UInt8]": return expr
        default:
            if isEnum(swift) {
                return "\(swift).fromRaw(swiftffi.BridgeBlob.decode(\(expr))!!)"
            }
            if isBlob(swift, generics: generics) {
                if swift.hasPrefix("Result<") {
                    return "swiftffi.BridgeBlob.asResult(swiftffi.BridgeBlob.decode(\(expr))) as \(kotlinType(swift, generics: generics))"
                }
                return "swiftffi.BridgeBlob.decode(\(expr)) as \(kotlinType(swift, generics: generics))"
            }
            if module.interfaceNames.contains(swift) { return "Swift\(swift)(\(expr))" }
            return expr
        }
    }

    func emitKotlin(
        _ module: FFIModule, package: String, className: String, libraryName: String
    ) -> String {
        let interfaces = module.interfaceNames
        let foreign = foreignInterfaces(module)
        let hasThrowing = module.functions.contains { $0.isThrowing && !$0.isAsync }
            || module.interfaces.contains { $0.methods.contains(where: \.isThrowing) }
        let hasAsync = module.functions.contains(where: \.isAsync)
        let hasAsyncMethods = module.interfaces.contains { $0.methods.contains(where: \.isAsync) }
        let hasLazy = module.functions.contains(where: \.returnsLazy)

        var imports = ""
        if hasThrowing || hasAsync {
            imports += "\nimport swiftffi.SwiftError"
        }
        if hasAsync {
            imports += "\nimport kotlin.coroutines.resume"
            imports += "\nimport kotlin.coroutines.resumeWithException"
            imports += "\nimport kotlin.coroutines.suspendCoroutine"
        }
        if hasAsyncMethods {
            imports += "\nimport kotlin.coroutines.Continuation"
            imports += "\nimport kotlin.coroutines.EmptyCoroutineContext"
            imports += "\nimport kotlin.coroutines.startCoroutine"
        }

        var registrations = ""
        for structure in module.structs {
            registrations +=
                "\n    swiftffi.BridgeCodecs.register(\(structure.name)::class, \(structure.name)Codec)"
        }

        var out = """
            // Generated by swift_ffi. Do not edit.
            //
            // Kotlin bindings for the Swift module in lib\(libraryName).so, over its
            // shared C ABI (via the generated JNI adapter). Ownership follows the
            // swift-java model: wrapper objects own a +1 handle to the Swift
            // instance. Release deterministically with `close()` (or `use { }`);
            // a finalizer backstop releases leaked wrappers when they are collected.
            package \(package)
            \(imports)
            // The raw JNI surface. The object is internal but its members are public:
            // Kotlin mangles the JVM names of `internal` members, which would break
            // the Java_* symbol match. @PublishedApi so inline (reified) facade
            // functions may reach it.
            @PublishedApi
            internal object \(className)Native {
              init {
                System.loadLibrary("\(libraryName)")\(registrations)
              }

            """

        func rawSignature(
            _ name: String, _ parameters: [FFIParameter], _ returnType: String,
            generics: Set<String>, returnsLazy: Bool, handle: Bool, trailing: String? = nil
        ) -> String {
            var params: [String] = handle ? ["handle: Long"] : []
            for (index, parameter) in parameters.enumerated() {
                if parameter.closure != nil {
                    params.append("p\(index): swiftffi.SwiftClosure")
                } else if interfaces.contains(parameter.type) {
                    // Dual slot: exactly one of (Swift handle, foreign dispatcher).
                    params.append("p\(index): Long")
                    params.append("p\(index)f: swiftffi.SwiftClosure?")
                } else {
                    params.append("p\(index): \(kotlinRawType(parameter.type, generics: generics))")
                }
            }
            if let trailing {
                params.append(trailing)
            }
            let ret: String
            if returnsLazy || interfaces.contains(returnType) {
                ret = ": Long"
            } else if isVoid(returnType) {
                ret = ""
            } else {
                ret = ": \(kotlinRawType(returnType, generics: generics))"
            }
            return "  external fun \(name)(\(params.joined(separator: ", ")))\(ret)\n"
        }

        // Raw externals (bound to the JNI adapter symbols). Async functions take
        // a completion dispatcher; throwing ones surface a pending SwiftError.
        for function in module.functions {
            let generics = Set(function.genericParameters)
            if function.isAsync {
                out += rawSignature(
                    jniFunctionName(function.name), function.parameters, "Void",
                    generics: generics, returnsLazy: false, handle: false,
                    trailing: "completion: swiftffi.SwiftClosure")
            } else {
                out += rawSignature(
                    jniFunctionName(function.name), function.parameters, function.returnType,
                    generics: generics, returnsLazy: function.returnsLazy, handle: false)
            }
        }
        for interface in module.interfaces {
            out += rawSignature(
                jniReleaseName(interface.name), [], "Void",
                generics: [], returnsLazy: false, handle: true)
            // Method calls are ordinal-led blob dispatches through the
            // interface's single `_invoke` entry.
            out += "  external fun \(jniInvokeName(interface.name))(handle: Long, ordinal: Int, args: ByteArray): ByteArray\n"
        }
        if hasLazy {
            out += "  external fun \(jniLazyGetName())(handle: Long): ByteArray\n"
            out += "  external fun \(jniLazyReleaseName())(handle: Long)\n"
        }
        if hasAsyncMethods {
            // The host's answer to an in-flight async interface call.
            out += "  external fun asyncResumeRaw(callId: Int, blob: ByteArray)\n"
        }

        out += "}\n\nobject \(className) {\n"

        // Idiomatic facade functions. `throws` / `Result` returns become
        // kotlin.Result; async becomes suspend (resumed by the completion
        // dispatcher from Swift's executor thread); Lazy<T> returns become
        // SwiftLazy<T>; generic functions are inline+reified over the blob
        // codec.
        for function in module.functions {
            let generics = Set(function.genericParameters)
            let params = function.parameters.enumerated()
                .map { kotlinParamDecl($0.element, index: $0.offset, generics: generics) }
                .joined(separator: ", ")
            let args = function.parameters.enumerated()
                .flatMap { kotlinRawArgs($0.element, index: $0.offset, generics: generics) }
                .joined(separator: ", ")
            let base = kotlinReturnType(function.returnType, generics: generics)
            let genericClause = function.genericParameters.isEmpty
                ? ""
                : "<\(function.genericParameters.map { "reified \($0) : Any" }.joined(separator: ", "))> "
            let funPrefix = function.genericParameters.isEmpty ? "fun" : "inline fun"

            if function.isAsync {
                let declared = function.isThrowing ? "Result<\(base)>" : base
                let valueExpr: String
                if isVoid(function.returnType) {
                    valueExpr = "Unit"
                } else if interfaces.contains(function.returnType) {
                    valueExpr = "Swift\(function.returnType)((v as swiftffi.SwiftHandle).bits)"
                } else {
                    valueExpr = "v as \(kotlinType(function.returnType))"
                }
                let resume = function.isThrowing
                    ? "cont.resume(Result.success(\(valueExpr)))"
                    : "cont.resume(\(valueExpr))"
                let fail = function.isThrowing
                    ? "cont.resume(Result.failure(SwiftError(v.message)))"
                    : "cont.resumeWithException(SwiftError(v.message))"
                let completionArgs = args.isEmpty ? "" : args + ", "
                out += """

                      suspend fun \(function.name)(\(params)): \(declared) = suspendCoroutine { cont ->
                        \(className)Native.\(jniFunctionName(function.name))(\(completionArgs)swiftffi.SwiftClosure { bytes ->
                          val v = swiftffi.BridgeBlob.decode(bytes)
                          if (v is swiftffi.SwiftErrorMessage) {
                            \(fail)
                          } else {
                            \(resume)
                          }
                          ByteArray(0)
                        })
                      }

                    """
                continue
            }

            let rawCall = "\(className)Native.\(jniFunctionName(function.name))(\(args))"
            if function.returnsLazy {
                out += """

                      \(funPrefix) \(genericClause)\(function.name)(\(params)): swiftffi.SwiftLazy<\(base)> =
                        swiftffi.SwiftLazy(\(rawCall), \(className)Native::\(jniLazyGetName()), \(className)Native::\(jniLazyReleaseName())) { bytes ->
                          swiftffi.BridgeBlob.decode(bytes) as \(base)
                        }

                    """
            } else if function.isThrowing {
                let success = isVoid(function.returnType)
                    ? "{\n      \(rawCall)\n      Result.success(Unit)\n    }"
                    : "{\n      Result.success(\(rawToKotlin(function.returnType, rawCall, generics: generics)))\n    }"
                out += """

                      \(funPrefix) \(genericClause)\(function.name)(\(params)): Result<\(base)> =
                        try \(success) catch (e: SwiftError) {
                          Result.failure(e)
                        }

                    """
            } else if isVoid(function.returnType) {
                out += "\n  \(funPrefix) \(genericClause)\(function.name)(\(params)) {\n    \(rawCall)\n  }\n"
            } else {
                out += "\n  \(funPrefix) \(genericClause)\(function.name)(\(params)): \(base) =\n    \(rawToKotlin(function.returnType, rawCall, generics: generics))\n"
            }
        }

        out += "}\n"

        // Exported enums: raw-value copies as enum classes.
        for enumeration in module.enums {
            let rawKotlin = enumeration.rawType == "String" ? "String" : "Long"
            let cases = enumeration.cases.enumerated().map { index, c -> String in
                let raw = c.rawValue.isEmpty
                    ? (enumeration.rawType == "String" ? "\"\(c.name)\"" : "\(index)L")
                    : (enumeration.rawType == "String" ? c.rawValue : c.rawValue + "L")
                return "  \(c.name)(\(raw)),"
            }.joined(separator: "\n")
            out += """

                /** A raw-value copy of the Swift `\(enumeration.name)` enum. */
                enum class \(enumeration.name)(val rawValue: \(rawKotlin)) {
                \(cases)
                  ;

                  companion object {
                    fun fromRaw(raw: Any): \(enumeration.name) =
                      entries.first { it.rawValue == raw }
                  }
                }

                """
        }

        // Exported structs: flat value copies as data classes, with their blob
        // codecs (registered by the Native object's init).
        for structure in module.structs {
            let fields = structure.fields
                .map { "val \($0.name): \(kotlinType($0.type))" }
                .joined(separator: ", ")
            let encodes = structure.fields
                .map { "    swiftffi.BridgeBlob.encodeValue(writer, value.\($0.name))" }
                .joined(separator: "\n")
            let decodes = structure.fields
                .map { "      \($0.name) = swiftffi.BridgeBlob.decodeValue(reader) as \(kotlinType($0.type))," }
                .joined(separator: "\n")
            out += """

                /** A field-wise copy of the Swift `\(structure.name)` value. */
                data class \(structure.name)(\(fields))

                internal object \(structure.name)Codec : swiftffi.StructCodec<\(structure.name)> {
                  override val name = "\(structure.name)"

                  override fun encode(writer: swiftffi.BlobWriter, value: \(structure.name)) {
                    writer.typeHeader(swiftffi.BridgeTags.STRUCT, name)
                    writer.i64(\(structure.fields.count))
                \(encodes)
                  }

                  override fun decodeFields(reader: swiftffi.BlobReader): \(structure.name) =
                    \(structure.name)(
                \(decodes)
                    )
                }

                """
        }

        // Interface contracts + Swift-owned wrapper classes + foreign
        // dispatchers. Consumers may implement the interface themselves and
        // pass it into Swift; Swift calls back through the dispatcher (method
        // ordinal leads the arguments).
        for interface in module.interfaces {
            out += "\ninterface \(interface.name) {\n"
            for method in interface.methods {
                let params = method.parameters.enumerated()
                    .map { "\(kotlinParameterName($0.element.label, $0.offset)): \(kotlinReturnType($0.element.type))" }
                    .joined(separator: ", ")
                let ret = isVoid(method.returnType) ? "" : ": \(kotlinType(method.returnType))"
                // async → suspend (a consumer implementation completes when its
                // coroutine returns; throwing methods throw).
                out += "  \(method.isAsync ? "suspend " : "")fun \(method.name)(\(params))\(ret)\n"
            }
            out += "}\n"

            out += """

                /** Wraps a Swift `\(interface.name)` instance. Owns a +1 handle. */
                class Swift\(interface.name) internal constructor(private var handle: Long) : \(interface.name), AutoCloseable {

                  internal fun borrowHandle(): Long {
                    check(handle != 0L) { "\(interface.name) used after close()" }
                    return handle
                  }

                  /** Releases the underlying Swift instance. Idempotent. */
                  override fun close() {
                    if (handle != 0L) {
                      \(className)Native.\(jniReleaseName(interface.name))(handle)
                      handle = 0L
                    }
                  }

                  @Suppress("removal", "deprecation")
                  protected fun finalize() {
                    close()
                  }

                """
            for (ordinal, method) in interface.methods.enumerated() {
                let params = method.parameters.enumerated()
                    .map { "\(kotlinParameterName($0.element.label, $0.offset)): \(kotlinReturnType($0.element.type))" }
                    .joined(separator: ", ")
                if method.isAsync {
                    let ret = isVoid(method.returnType) ? "" : ": \(kotlinType(method.returnType))"
                    out += "\n  override suspend fun \(method.name)(\(params))\(ret) {\n    throw swiftffi.SwiftError(\"async interface methods on Swift-owned instances are not callable from Kotlin yet\")\n  }\n"
                    continue
                }
                var body: [String] = ["val w = swiftffi.BlobWriter()"]
                for (index, parameter) in method.parameters.enumerated() {
                    let name = kotlinParameterName(parameter.label, index)
                    if interfaces.contains(parameter.type) {
                        // Borrowed for the call. Consumer implementations as
                        // METHOD arguments would need a native closure wrap;
                        // pass them at function boundaries instead.
                        body.append(
                            "check(\(name) is Swift\(parameter.type)) { \"pass a Swift-owned \(parameter.type) (consumer implementations cross at function boundaries on Kotlin)\" }")
                        body.append(
                            "w.typeHeader(swiftffi.BridgeTags.HANDLE, \"\(parameter.type)\").i64(\(name).borrowHandle())")
                    } else if isEnum(parameter.type) {
                        body.append("swiftffi.BridgeBlob.encodeValue(w, \(name).rawValue)")
                    } else {
                        body.append("swiftffi.BridgeBlob.encodeValue(w, \(name))")
                    }
                }
                body.append(
                    "val decoded = swiftffi.BridgeBlob.decode(\(className)Native.\(jniInvokeName(interface.name))(borrowHandle(), \(ordinal), w.toByteArray()))")
                body.append("if (decoded is swiftffi.SwiftErrorMessage) throw swiftffi.SwiftError(decoded.message)")
                let ret: String
                if isVoid(method.returnType) {
                    ret = ""
                } else if interfaces.contains(method.returnType) {
                    ret = ": \(kotlinReturnType(method.returnType))"
                    body.append("return Swift\(method.returnType)((decoded as swiftffi.SwiftHandle).bits)")
                } else if isEnum(method.returnType) {
                    ret = ": \(kotlinType(method.returnType))"
                    body.append("return \(method.returnType).fromRaw(decoded!!)")
                } else if method.returnType.hasPrefix("Result<") {
                    ret = ": \(kotlinType(method.returnType))"
                    body.append("@Suppress(\"UNCHECKED_CAST\")")
                    body.append("return swiftffi.BridgeBlob.asResult(decoded) as \(kotlinType(method.returnType))")
                } else if method.returnType == "[String]" {
                    ret = ": List<String>"
                    body.append("@Suppress(\"UNCHECKED_CAST\")")
                    body.append("return (decoded as swiftffi.BridgeList).items as List<String>")
                } else {
                    ret = ": \(kotlinType(method.returnType))"
                    body.append("return decoded as \(kotlinType(method.returnType))")
                }
                out += "\n  override fun \(method.name)(\(params))\(ret) {\n"
                    + body.map { "    \($0)\n" }.joined() + "  }\n"
            }
            out += "}\n"

            if foreign.contains(interface.name) {
                var cases: [String] = []
                for (ordinal, method) in interface.methods.enumerated() {
                    var caseBody: [String] = []
                    var callArgs: [String] = []
                    if method.isAsync {
                        caseBody.append("val callId = swiftffi.BridgeBlob.decodeValue(r) as Int")
                    }
                    for (index, parameter) in method.parameters.enumerated() {
                        if interfaces.contains(parameter.type) {
                            caseBody.append(
                                "val a\(index) = Swift\(parameter.type)((swiftffi.BridgeBlob.decodeValue(r) as swiftffi.SwiftHandle).bits)")
                        } else if parameter.type == "[String]" {
                            caseBody.append("@Suppress(\"UNCHECKED_CAST\")")
                            caseBody.append("val a\(index) = (swiftffi.BridgeBlob.decodeValue(r) as swiftffi.BridgeList).items as List<String>")
                        } else {
                            caseBody.append(
                                "val a\(index) = swiftffi.BridgeBlob.decodeValue(r) as \(kotlinType(parameter.type))")
                        }
                        callArgs.append("a\(index)")
                    }
                    let call = "impl.\(method.name)(\(callArgs.joined(separator: ", ")))"
                    if method.isAsync {
                        // Run the suspend implementation as a coroutine; its
                        // completion answers the guest through asyncResumeRaw.
                        caseBody.append("val block: suspend () -> Any? = { \(call) }")
                        caseBody.append("block.startCoroutine(object : Continuation<Any?> {")
                        caseBody.append("  override val context = EmptyCoroutineContext")
                        caseBody.append("  override fun resumeWith(result: kotlin.Result<Any?>) {")
                        caseBody.append("    val blob = result.fold({ swiftffi.BridgeBlob.encode(it) }, { swiftffi.BridgeBlob.encodeError(it.message ?: it.toString()) })")
                        caseBody.append("    \(className)Native.asyncResumeRaw(callId, blob)")
                        caseBody.append("  }")
                        caseBody.append("})")
                        caseBody.append("ByteArray(0)")
                    } else if method.isThrowing {
                        caseBody.append("try {")
                        if isVoid(method.returnType) {
                            caseBody.append("  \(call)")
                            caseBody.append("  ByteArray(0)")
                        } else {
                            caseBody.append("  swiftffi.BridgeBlob.encode(\(call))")
                        }
                        caseBody.append("} catch (error: Throwable) {")
                        caseBody.append("  swiftffi.BridgeBlob.encodeError(error.message ?: error.toString())")
                        caseBody.append("}")
                    } else if isVoid(method.returnType) {
                        caseBody.append("\(call)")
                        caseBody.append("ByteArray(0)")
                    } else {
                        caseBody.append("swiftffi.BridgeBlob.encode(\(call))")
                    }
                    cases.append(
                        "      \(ordinal) -> {\n"
                            + caseBody.map { "        \($0)\n" }.joined()
                            + "      }")
                }
                out += """

                    /** Dispatches Swift's calls into a consumer-implemented
                     * `\(interface.name)` (method ordinal leads the arguments). */
                    internal class ForeignDispatcher_\(interface.name)(private val impl: \(interface.name)) : swiftffi.SwiftClosure {
                      override fun invoke(args: ByteArray): ByteArray {
                        val r = swiftffi.BlobReader(args)
                        return when (swiftffi.BridgeBlob.decodeValue(r) as Int) {
                    \(cases.joined(separator: "\n"))
                          else -> throw swiftffi.SwiftError("unknown method ordinal")
                        }
                      }
                    }

                    """
            }
        }

        return out
    }

    // MARK: - Entry point
}
