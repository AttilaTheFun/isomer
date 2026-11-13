// Runs a runtime module (+ side modules) under WasmKit with the iso_hot
// bridge stubbed, taps every tap id of the first frame, and writes the
// render stream: the WasmKit twin of tools/mixed/node/drive_all.mjs.
// BENCH=drag instead measures event → frame for a drag (see DragBench.swift),
// as tests/wasm_engines' testBenchmarkDrag does. NO_LINKER builds it without
// WasmDynamicLinker, against a WasmKit without the API it needs.
import Foundation
@_spi(OnlyForCLI) import WasmKit
import WasmKitWASI

setvbuf(stdout, nil, _IONBF, 0)
let arguments = CommandLine.arguments
guard arguments.count >= 3 else { print("usage: SideloadCheck <out> <runtime.wasm> [side.wasm…]"); exit(2) }
let out = arguments[1]
let engine = Engine(configuration: EngineConfiguration(stackSize: 2 << 20))
let store = Store(engine: engine)
let mainModule = try parseWasm(bytes: Array(try Data(contentsOf: URL(fileURLWithPath: arguments[2]))))
let wasi = try WASIBridgeToHost(args: ["app"])

var stream: [UInt8] = []
#if !NO_LINKER
var linker: WasmDynamicLinker?
#endif
let benchmarking = ProcessInfo.processInfo.environment["BENCH"] != nil
nonisolated(unsafe) var wantsRender = false
var imports = Imports()
wasi.link(to: &imports, store: store)
func memory(_ caller: borrowing Caller) -> Memory { caller.instance!.exports[memory: "memory"]! }
for item in mainModule.imports {
    guard case .function(let index) = item.descriptor, let type = mainModule.functionType(at: index) else { continue }
    let qualified = item.module + "." + item.name
    switch qualified {
    case "iso_hot.render_tree":
        imports.define(module: item.module, name: item.name, Function(store: store, type: type) { caller, args in
            memory(caller).withUnsafeBufferPointer(offset: UInt(args[0].i32), count: Int(args[1].i32)) { stream += $0 }
            return []
        })
    case _ where item.module == "wasi_snapshot_preview1":
        continue
    case _ where item.module == "env":
        // Late-bound: a side module defines it.
        imports.define(module: item.module, name: item.name, Function(store: store, type: type) { _, args in
            #if !NO_LINKER
            guard let function = linker?.function(named: item.name) else { fatalError("env.\(item.name) unresolved") }
            return try function.invoke(args)
            #else
            fatalError("env.\(item.name): no linker in this build")
            #endif
        })
    default:
        imports.define(module: item.module, name: item.name, Function(store: store, type: type) { _, _ in
            if item.name == "schedule_render" { wantsRender = true }
            if item.name == "epoch_millis" && benchmarking { return [.f64((Date().timeIntervalSince1970 * 1000).bitPattern)] }
            return type.results.map { result -> Value in
                switch result {
                case .i32: return item.name == "host_value" ? .i32(UInt32(bitPattern: -1)) : .i32(0)
                case .i64: return .i64(0)
                case .f32: return .f32(0)
                case .f64: return .f64((1.7e12).bitPattern)  // epoch_millis, fixed as the Node harness has it
                default: return .i32(0)
                }
            }
        })
    }
}
print("stage: instantiate")
let main = try mainModule.instantiate(store: store, imports: imports)
print("stage: initialize")
try wasi.initialize(main)
print("stage: initialized")
let loadStart = Date()
#if !NO_LINKER
if arguments.count > 3 {
    print("stage: linker")
    linker = try WasmDynamicLinker(main: main, store: store)
    for path in arguments[3...] {
        let module = try linker!.load(Array(try Data(contentsOf: URL(fileURLWithPath: path))))
        print("loaded \(path.split(separator: "/").last!): memory \(module.info.memorySize) B at \(module.memoryBase), table \(module.info.tableSize) at \(module.tableBase)")
    }
}
#endif
print("side load ms", Int(Date().timeIntervalSince(loadStart) * 1000))
final class StackBox { var stack: ExecutionStack; init(engine: Engine) { stack = ExecutionStack(engine: engine) } }
let callStack = StackBox(engine: engine)
func call(_ name: String, _ args: [Value] = []) throws -> [Value] { try main.exports[function: name]!.invoke(args, on: &callStack.stack) }
if benchmarking {
    let memory = main.exports[memory: "memory"]!
    print(try DragBench.run(
        call: { name, args in try call(name, args) },
        write: { address, bytes in
            memory.withUnsafeMutableBufferPointer(offset: UInt(address), count: bytes.count) { d in bytes.withUnsafeBytes { d.copyMemory(from: $0) } }
        },
        stream: { stream }, clearStream: { stream.removeAll(keepingCapacity: true) },
        takeWantsRender: { defer { wantsRender = false }; return wantsRender }))
    exit(0)
}
_ = try call("iso_hot_start", [.f64(1024.0.bitPattern), .f64(768.0.bitPattern)])
_ = try call("iso_hot_render")
var ids: [String] = []
let tap = Array(".tap".utf8)
func ok(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || c == 46 || (c >= 97 && c <= 122) }
if stream.count >= 4 {
    for i in 0...(stream.count - 4) where Array(stream[i..<i + 4]) == tap {
        var start = i
        while start > 0 && ok(stream[start - 1]) { start -= 1 }
        var id = String(decoding: stream[start..<i + 4], as: UTF8.self)
        while id.hasPrefix(".") { id.removeFirst() }
        if !ids.contains(id) { ids.append(id) }
    }
}
let tapStart = Date()
let mem = main.exports[memory: "memory"]!
for id in ids {
    let bytes = Array(id.utf8)
    let idPtr = try call("iso_hot_alloc", [.i32(UInt32(bytes.count))])[0].i32
    let valuePtr = try call("iso_hot_alloc", [.i32(1)])[0].i32
    mem.withUnsafeMutableBufferPointer(offset: UInt(idPtr), count: bytes.count) { dst in
        bytes.withUnsafeBytes { dst.copyMemory(from: $0) }
    }
    _ = try call("iso_hot_event", [.i32(idPtr), .i32(UInt32(bytes.count)), .i32(valuePtr), .i32(0)])
    _ = try call("iso_hot_render")
}
try Data(stream).write(to: URL(fileURLWithPath: out))
print("\(ids.count) taps, \(stream.count) bytes of frames, \(Int(Date().timeIntervalSince(tapStart) * 1000)) ms")
