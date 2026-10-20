import SwiftFFIGeneratorLibrary
import SwiftFFIIRLibrary
import XCTest

/// Exercises every backend against one small module: a function over each
/// bridgeable value type, an interface (crossing both directions), a struct,
/// and an async + throwing function — asserting the load-bearing lines of
/// each artifact rather than full golden text (the examples are the goldens;
/// these pin the contract). The Swift-side C ABI is macro-expanded into the
/// annotated module itself (see the plugin tests); the backends here generate
/// only CONSUMER-side artifacts against the same symbol scheme.
final class GeneratorTests: XCTestCase {
    private let module = FFIModule(
        functions: [
            FFIFunction(
                name: "greet",
                parameters: [
                    FFIParameter(label: "name", type: "String"),
                    FFIParameter(label: "count", type: "Int"),
                ],
                returnType: "String"
            ),
            FFIFunction(
                name: "describe",
                parameters: [FFIParameter(label: "counter", type: "Counter")],
                returnType: "String"
            ),
            FFIFunction(
                name: "fetch",
                parameters: [FFIParameter(label: "url", type: "String")],
                returnType: "String",
                isAsync: true,
                isThrowing: true
            ),
            FFIFunction(
                name: "tagged",
                parameters: [FFIParameter(label: "value", type: "Int")],
                returnType: "Int",
                namespace: "greeter"
            ),
        ],
        interfaces: [
            FFIInterface(
                name: "Counter",
                methods: [
                    FFIMethod(
                        name: "increment",
                        parameters: [FFIParameter(label: "by", type: "Int")],
                        returnType: "Int"
                    )
                ]
            )
        ],
        structs: [
            FFIStruct(
                name: "Stats",
                fields: [
                    FFIField(name: "count", type: "Int"),
                    FFIField(name: "label", type: "String"),
                ]
            )
        ],
        sourceModules: ["Greeter"]
    )

    private func artifact(_ kind: GeneratorKind) throws -> String {
        try Generator(module: module).artifact(kind: kind, moduleName: "Greeter")
    }

    func testMergeSkipsDeclarationsAlreadyPresent() throws {
        // The same source analyzed under two Bazel configurations (a module
        // reached through two dependency paths) must contribute its exports once.
        var merged = FFIModule()
        merged.merge(module)
        merged.merge(module)
        XCTAssertEqual(merged, module)
        XCTAssertEqual(merged.functions.count, 4)
        XCTAssertEqual(merged.interfaces.count, 1)
        XCTAssertEqual(merged.structs.count, 1)

        // A genuinely different declaration with a colliding name is kept so
        // validation can still report it.
        var variant = module
        variant.structs[0].fields.removeLast()
        merged.merge(variant)
        XCTAssertEqual(merged.structs.count, 2)
    }

    func testValidatePassesForBridgeableModule() throws {
        try Generator(module: module).validate()
    }

    func testValidateRejectsUnknownHandleType() {
        var bad = module
        bad.functions.append(
            FFIFunction(
                name: "mystery",
                parameters: [FFIParameter(label: "value", type: "Mystery")],
                returnType: "Void"
            ))
        XCTAssertThrowsError(try Generator(module: bad).validate()) { error in
            XCTAssertTrue("\(error)".contains("Mystery"))
        }
    }

    func testCHeaderDeclaresSymbols() throws {
        let header = try artifact(.cHeader)
        // Bare exports carry no module segment; `namespace:` adds one.
        XCTAssertTrue(header.contains("swift_ffi_greet"))
        XCTAssertTrue(header.contains("swift_ffi_greeter_tagged"))
        // Interfaces are ordinal-dispatch entries, not per-method symbols.
        XCTAssertTrue(header.contains("void *swift_ffi_Counter_invoke(void *handle, int32_t ordinal, const void *args, int32_t args_len);"))
        XCTAssertTrue(header.contains("void swift_ffi_Counter_release(void *handle);"))
        XCTAssertFalse(header.contains("Counter_increment"))
        // The fixed runtime entry points live in swift_abi.h, not per module.
        XCTAssertFalse(header.contains("greeter_alloc"))
        XCTAssertTrue(header.contains("#ifndef"))
    }

    func testTypeScriptWrapsExports() throws {
        let ts = try artifact(.ts)
        XCTAssertTrue(ts.contains("export"))
        XCTAssertTrue(ts.contains("greet"))
        XCTAssertTrue(ts.contains("Counter"))
        // Wrapper methods dispatch through the interface's invoke entry.
        XCTAssertTrue(ts.contains("swift_ffi_Counter_invoke"))
        // The fixed five-entry import table is always bound.
        XCTAssertTrue(ts.contains("closure_invoke"))
        XCTAssertTrue(ts.contains("dependency_get"))
        XCTAssertTrue(ts.contains("task_enqueue"))
        XCTAssertTrue(ts.contains("async_complete"))
        // The loader registers the dependency-proxy factories.
        XCTAssertTrue(ts.contains("swift_ffi_register_Counter"))
        // Runtime staging uses the fixed allocator names.
        XCTAssertTrue(ts.contains("swift_ffi_alloc"))
    }

    func testTypeScriptWrapperReleasesBesideAnInterfaceClose() throws {
        // A connection-like interface with a `close` of its own: the
        // TypeScript wrapper's release takes another name, since a class
        // cannot overload `close()` with it.
        var connection = module
        connection.interfaces.append(
            FFIInterface(
                name: "Connection",
                methods: [
                    FFIMethod(
                        name: "close",
                        parameters: [FFIParameter(label: "code", type: "Int32")],
                        returnType: "Void"
                    )
                ]
            ))
        let ts = try Generator(module: connection).artifact(kind: .ts, moduleName: "Greeter")
        XCTAssertTrue(ts.contains("  close(code: number): void {"))
        XCTAssertTrue(ts.contains("  release(): void {"))
        XCTAssertTrue(ts.contains("Connection used after release()"))
        // Other wrappers keep `close()`.
        XCTAssertTrue(ts.contains("Counter used after close()"))
    }

    func testKotlinEmitsFacadeAndWrapper() throws {
        let kotlin = try Generator(module: module).artifact(
            kind: .kotlin, moduleName: "Greeter",
            javaPackage: "dev.example.greeter", javaClass: "Greeter", libraryName: "greeter")
        XCTAssertTrue(kotlin.contains("package dev.example.greeter"))
        XCTAssertTrue(kotlin.contains("System.loadLibrary(\"greeter\")"))
        XCTAssertTrue(kotlin.contains("Counter"))
        // One ordinal-dispatch external per interface.
        XCTAssertTrue(kotlin.contains("external fun counterInvokeRaw(handle: Long, ordinal: Int, args: ByteArray): ByteArray"))
    }

    func testJNIAdapterExportsJavaSymbols() throws {
        let adapter = try Generator(module: module).artifact(
            kind: .jniAdapter, moduleName: "Greeter",
            javaPackage: "dev.example.greeter", javaClass: "Greeter")
        XCTAssertTrue(adapter.contains("Java_dev_example_greeter_GreeterNative_greetRaw"))
        // The adapter calls the macro-expanded C ABI, never bespoke glue.
        XCTAssertTrue(adapter.contains("swift_ffi_greet"))
        XCTAssertTrue(adapter.contains("swift_ffi_greeter_tagged"))
        XCTAssertTrue(adapter.contains("Java_dev_example_greeter_GreeterNative_counterInvokeRaw"))
        XCTAssertTrue(adapter.contains("swift_ffi_Counter_invoke"))
        // Byte boxes drain through the fixed runtime entry points.
        XCTAssertTrue(adapter.contains("swift_ffi_string_len"))
        XCTAssertTrue(adapter.contains("#include \"greeter.h\""))
    }

    func testSwiftHostEmitsFacadeAndEngineLoad() throws {
        let host = try artifact(.swiftHostWasm)
        XCTAssertTrue(host.contains("public static func load("))
        XCTAssertTrue(host.contains("engine: any SwiftFFIWasmEngine, wasm: [UInt8]"))
        XCTAssertTrue(host.contains("Stats"))
        // Method calls go through the invoke entry; register exports run at load.
        XCTAssertTrue(host.contains("swift_ffi_Counter_invoke"))
        XCTAssertTrue(host.contains("swift_ffi_register_Counter"))
        XCTAssertTrue(host.contains("runtime.standardImports()"))
    }

    func testCHostEmitsDispatchTable() throws {
        let cHost = try artifact(.cHostWasm)
        XCTAssertTrue(cHost.contains("swift_ffi_greet"))
        XCTAssertTrue(cHost.contains("swift_ffi_host_standard_imports"))
        XCTAssertTrue(cHost.contains("swift_ffi_register_Counter"))
        // The interface registry key backs dependency injection.
        XCTAssertTrue(cHost.contains("GREETER_KEY_Counter \"swift_ffi_Counter\""))
    }

    // MARK: - Erased shapes across the consumer backends

    private var v2Module: FFIModule {
        var extended = module
        extended.functions.append(
            FFIFunction(
                name: "echo",
                parameters: [
                    FFIParameter(label: "_", type: "T"),
                    FFIParameter(label: "fallback", type: "T"),
                ],
                returnType: "T",
                genericParameters: ["T"]
            ))
        extended.functions.append(
            FFIFunction(
                name: "transform",
                parameters: [
                    FFIParameter(label: "_", type: "Int"),
                    FFIParameter(
                        label: "using", type: "(Int) -> Int",
                        closure: FFIClosureType(parameters: ["Int"], returnType: "Int")),
                ],
                returnType: "Int"
            ))
        extended.functions.append(
            FFIFunction(
                name: "expensive",
                parameters: [FFIParameter(label: "for", type: "String")],
                returnType: "String",
                returnsLazy: true
            ))
        extended.functions.append(
            FFIFunction(
                name: "describeResult",
                parameters: [
                    FFIParameter(
                        label: "_", type: "Result<Int, Error>", resultSuccess: "Int")
                ],
                returnType: "String"
            ))
        return extended
    }

    func testValidatePassesForV2Module() throws {
        try Generator(module: v2Module).validate()
    }

    func testCppEmitsIdiomaticBindings() throws {
        let cpp = try Generator(module: v2Module).artifact(kind: .cpp, moduleName: "Greeter")
        XCTAssertTrue(cpp.contains("namespace greeter"))
        XCTAssertTrue(cpp.contains("template <typename T>"))
        XCTAssertTrue(cpp.contains("std::function<int64_t(int64_t)>"))
        XCTAssertTrue(cpp.contains("swiftffi::Lazy<std::string>"))
        XCTAssertTrue(cpp.contains("struct traits<greeter::Stats>"))
        // Structs are identified on the wire by NAME.
        XCTAssertTrue(cpp.contains("w.type_header(blob::kStruct, \"Stats\")"))
        XCTAssertTrue(cpp.contains("class SwiftCounter final : public Counter"))
        // Wrapper methods dispatch through the invoke entry.
        XCTAssertTrue(cpp.contains("swift_ffi_Counter_invoke"))
        // The fixed runtime entry points replace per-module boxes.
        XCTAssertTrue(cpp.contains("swift_ffi_string_len"))
        XCTAssertTrue(cpp.contains("swift_ffi_lazy_get"))
    }

    func testKotlinEmitsV2Shapes() throws {
        let kotlin = try Generator(module: v2Module).artifact(
            kind: .kotlin, moduleName: "Greeter",
            javaPackage: "dev.example.greeter", javaClass: "Greeter", libraryName: "greeter")
        XCTAssertTrue(kotlin.contains("inline fun <reified T : Any> echo"))
        XCTAssertTrue(kotlin.contains("swiftffi.SwiftLazy"))
        XCTAssertTrue(kotlin.contains("swiftffi.SwiftClosure"))
        XCTAssertTrue(kotlin.contains("data class Stats"))
        XCTAssertTrue(kotlin.contains("StatsCodec"))
        // Struct codecs key on the wire NAME, not an ordinal.
        XCTAssertTrue(kotlin.contains("override val name = \"Stats\""))
    }

    func testTypeScriptEmitsV2Shapes() throws {
        let ts = try Generator(module: v2Module).artifact(kind: .ts, moduleName: "Greeter")
        XCTAssertTrue(ts.contains("echo<T>(T_type: BridgeType<T>"))
        XCTAssertTrue(ts.contains("StatsType"))
        XCTAssertTrue(ts.contains("typeHeader(Tags.struct, \"Stats\")"))
        XCTAssertTrue(ts.contains("closure_invoke"))
        XCTAssertTrue(ts.contains("Lazy<string>"))
        // The lazy_get/lazy_release calls live in the shared runtime file.
        XCTAssertTrue(ts.contains("new Lazy("))
    }

    func testRustEmitsConsumerBindings() throws {
        let rust = try Generator(module: v2Module).artifact(kind: .rust, moduleName: "Greeter")
        XCTAssertTrue(rust.contains("fn swift_ffi_greet("))
        XCTAssertTrue(rust.contains("fn swift_ffi_string_len(b: *mut c_void) -> i32;"))
        XCTAssertTrue(rust.contains("w.type_header(7, \"Stats\");"))
    }
}
