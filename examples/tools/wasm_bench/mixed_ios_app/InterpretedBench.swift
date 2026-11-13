// The interpreted runs of the 2048 drag benchmark: a self-contained reactor,
// or a runtime module and side modules (WasmDynamicLinker), on WasmKit.
import Foundation
@_spi(OnlyForCLI) import WasmKit
import WasmKitWASI
import IsomerWasmKitRuntime

func runInterpretedBench(main mainBytes: [UInt8], sides: [[UInt8]]) throws -> [String] {
    stream = []
    let engine = Engine(configuration: EngineConfiguration(stackSize: 2 << 20))
    let store = Store(engine: engine)
    let wasi = try WASIBridgeToHost(args: ["app"])
    // WasmKit requires a bridge closed before it goes.
    defer { try? wasi.close() }
    let module = try parseWasm(bytes: mainBytes)
    var imports = Imports()
    wasi.link(to: &imports, store: store)
    hostImports(for: module, into: &imports, store: store)
    let main = try module.instantiate(store: store, imports: imports)
    try wasi.initialize(main)
    linkerForLate = nil
    if !sides.isEmpty {
        let linker = try WasmDynamicLinker(main: main, store: store)
        linkerForLate = linker
        for side in sides { try linker.load(side) }
    }
    final class StackBox { var stack: ExecutionStack; init(engine: Engine) { stack = ExecutionStack(engine: engine) } }
    let box = StackBox(engine: engine)
    let memory = main.exports[memory: "memory"]!
    return [try DragBench.run(
        call: { name, args in try main.exports[function: name]!.invoke(args, on: &box.stack) },
        write: { address, bytes in
            memory.withUnsafeMutableBufferPointer(offset: UInt(address), count: bytes.count) { d in bytes.withUnsafeBytes { d.copyMemory(from: $0) } }
        },
        stream: { stream }, clearStream: { stream.removeAll(keepingCapacity: true) },
        takeWantsRender: { defer { wantsRender = false }; return wantsRender })]
}
