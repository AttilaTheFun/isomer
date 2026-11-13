// The mixed-mode 2048 drag benchmark, on an iPhone: tools/mixed/host's
// MixedCheck (the runtime interpreted, plus wasm2c'd native copies of its hot
// functions, CHot), as functions the app calls instead of a command line.
// Its bridge, link main and C callbacks are MixedCheck's, copied (keep them
// in step); DragBench.swift is tools/mixed/host's, copied.
import CHot
import Foundation
@_spi(OnlyForCLI) import WasmKit
import WasmKitWASI
import IsomerWasmKitRuntime

func valueType(_ c: Character) -> ValueType {
    switch c { case "i": return .i32; case "I": return .i64; case "f": return .f32; default: return .f64 }
}
func slot(_ v: Value) -> UInt64 {
    switch v {
    case .i32(let x): return UInt64(x)
    case .i64(let x): return x
    case .f32(let x): return UInt64(x)
    case .f64(let x): return x
    default: return 0
    }
}
func value(_ s: UInt64, _ t: ValueType) -> Value {
    switch t {
    case .i32: return .i32(UInt32(truncatingIfNeeded: s))
    case .i64: return .i64(s)
    case .f32: return .f32(UInt32(truncatingIfNeeded: s))
    case .f64: return .f64(s)
    default: return .i32(0)
    }
}
func signatureKey(_ type: FunctionType) -> String {
    func c(_ t: ValueType) -> String { switch t { case .i32: "i"; case .i64: "I"; case .f32: "f"; case .f64: "F"; default: "?" } }
    return type.parameters.map(c).joined() + ":" + type.results.map(c).joined()
}

final class Bridge {
    let engine: Engine
    let store: Store
    var memory: Memory!
    var table: Table!
    var stackPointer: Global!
    var nativeStackPointer: UnsafeMutablePointer<UInt32>!
    var signatures: [FunctionType] = []
    var signatureIndex: [String: UInt32] = [:]
    var nativeExports: [String: UInt32] = [:]
    var shimImports: [Function?] = []
    var shimCallIndirect: [Function] = []
    var linker: WasmDynamicLinker!
    final class StackBox { var stack: ExecutionStack; init(engine: Engine) { stack = ExecutionStack(engine: engine) } }
    var stacks: [StackBox] = []
    var depth = 0
    var intoInterpreted = 0
    var interpretedNanos: UInt64 = 0
    let timing = ProcessInfo.processInfo.environment["TIMING"] != nil
    var memoryBasePointer: UnsafeMutablePointer<UInt8>?
    /// The interpreter's function behind each table slot, looked up once.
    var slotFunctions: [Function?] = []
    var importFunctions: [Function?] = []
    var importIsEnv: [Bool] = []
    var importTypes: [FunctionType] = []
    var counts: [UInt32: Int] = [:]
    let counting = ProcessInfo.processInfo.environment["COUNT"] != nil

    init() {
        engine = Engine(configuration: EngineConfiguration(memoryBoundsChecking: .mprotect))
        store = Store(engine: engine)
        for k in 0..<Int(iso_mixed_sig_count) {
            let key = String(cString: iso_mixed_sig(UInt32(k)))
            let parts = key.split(separator: ":", omittingEmptySubsequences: false)
            signatures.append(FunctionType(parameters: parts[0].map(valueType), results: parts[1].map(valueType)))
            signatureIndex[key] = UInt32(k)
        }
        for k in 0..<Int(iso_mixed_export_count) { nativeExports[String(cString: iso_mixed_export_name(UInt32(k)))] = UInt32(k) }
    }

    // Into native code from the host; out to the interpreter from native code.
    @inline(__always) func toNative() {
        nativeStackPointer.pointee = stackPointer.value.i32
        iso_mixed_memory_sync(iso_mixed_memory())
    }
    @inline(__always) func toInterpreter() {
        try! stackPointer.assign(.i32(nativeStackPointer.pointee))
    }

    /// As below, with the arguments and results as raw slots straight from C.
    @inline(__always)
    func invokeInterpretedRaw(_ function: Function, _ a: UnsafePointer<UInt64>?, _ r: UnsafeMutablePointer<UInt64>?) {
        toInterpreter()
        intoInterpreted += 1
        if stacks.count <= depth { stacks.append(StackBox(engine: engine)) }
        let box = stacks[depth]
        depth += 1
        let start = timing && depth == 1 ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if timing && depth == 1 { interpretedNanos += DispatchTime.now().uptimeNanoseconds - start }
            depth -= 1; toNative()
        }
        if rawCalls {
            do { try function.invokeUnchecked(arguments: a, results: r, on: &box.stack) } catch { fatalError("[mixed] interpreted code trapped: \(error)") }
        } else {
            let type = function.type
            var args: [Value] = []
            for (k, t) in type.parameters.enumerated() { args.append(value(a![k], t)) }
            let results: [Value]
            do { results = try function.invoke(args, on: &box.stack) } catch { fatalError("[mixed] interpreted code trapped: \(error)") }
            if let first = results.first { r![0] = slot(first) }
        }
    }
    let rawCalls = ProcessInfo.processInfo.environment["CHECKED_CALLS"] == nil
    /// ALL_INTERPRETED: the host's calls go to the interpreted runtime too.
    let allInterpreted = ProcessInfo.processInfo.environment["ALL_INTERPRETED"] != nil

    func invokeInterpreted(_ function: Function, _ args: [Value]) -> [Value] {
        toInterpreter()
        intoInterpreted += 1
        if stacks.count <= depth { stacks.append(StackBox(engine: engine)) }
        let box = stacks[depth]
        depth += 1
        let start = timing && depth == 1 ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if timing && depth == 1 { interpretedNanos += DispatchTime.now().uptimeNanoseconds - start }
            depth -= 1; toNative()
        }
        do { return try function.invoke(args, on: &box.stack) } catch { fatalError("[mixed] interpreted code trapped: \(error)") }
    }

    /// Calls the runtime's export `name` from the host: its native copy when
    /// there is one, else the interpreted runtime's.
    @discardableResult
    func call(_ name: String, _ args: [Value] = [], interpreted instance: Instance) -> [Value] {
        if let index = nativeExports[name], !allInterpreted {
            let type = signatures[Int(iso_mixed_export_sig(index))]
            var a = args.map(slot)
            if a.isEmpty { a = [0] }
            var r: [UInt64] = [0]
            toNative()
            iso_mixed_call_export(index, a, &r)
            toInterpreter()
            return type.results.map { value(r[0], $0) }
        }
        return try! instance.exports[function: name]!(args)
    }

    /// Native slots the native module leaves null call the interpreter's
    /// function in the same WasmKit slot.
    func mirror() {
        if table.count > Int(iso_mixed_table_size()) { iso_mixed_table_grow(UInt32(table.count)) }
        var set = 0
        for index in 0..<table.count where iso_mixed_table_native_sig(UInt32(index)) == -1 {
            if let f = table.function(at: index, store: store), let sig = signatureIndex[signatureKey(f.type)] {
                iso_mixed_table_set_interpreted(UInt32(index), sig)
                set += 1
            }
        }
        NSLog("[mixed] \(set) native slots now call the interpreter (table \(table.count))")
    }
}

nonisolated(unsafe) var bridge: Bridge!

final class MixedLinkMain: WasmLinkMain {
    let inner: WasmInstanceLinkMain
    init(_ inner: WasmInstanceLinkMain) { self.inner = inner }
    /// COUNT_IMPORTS: each function a feature imports, wrapped to count its calls.
    static var importCalls: [String: Int] = [:]
    let countingImports = ProcessInfo.processInfo.environment["COUNT_IMPORTS"] != nil
    var memory: Memory { inner.memory }
    var table: Table { inner.table }
    var stackPointer: Global { inner.stackPointer }
    func allocate(size: Int, alignment: Int) throws -> UInt32 { try inner.allocate(size: size, alignment: alignment) }
    /// ROUTED=<file>: these functions, when a feature imports them, run as
    /// their native copies (interpreted → native: one crossing a call).
    nonisolated(unsafe) static var routed: Set<String> = []
    static var intoNative = 0
    func function(named name: String) -> Function? {
        if MixedLinkMain.routed.contains(name), let index = bridge.nativeExports[name] {
            let b = bridge!
            let type = b.signatures[Int(iso_mixed_export_sig(index))]
            let resultType = type.results.first
            return Function(store: b.store, parameters: type.parameters, results: type.results) { _, args, results in
                MixedLinkMain.intoNative += 1
                withUnsafeTemporaryAllocation(of: UInt64.self, capacity: max(args.count, 1)) { a in
                    for k in 0..<args.count { a[k] = slot(args[k]) }
                    var r: UInt64 = 0
                    b.toNative()
                    iso_mixed_call_export(index, a.baseAddress, &r)
                    b.toInterpreter()
                    if let resultType { results[0] = value(r, resultType) }
                }
            }
        }
        guard let f = inner.function(named: name) else { return nil }
        guard countingImports else { return f }
        return Function(store: bridge.store, type: f.type) { _, args in
            MixedLinkMain.importCalls[name, default: 0] += 1
            return try f.invoke(args)
        }
    }
    func global(named name: String) -> Global? { inner.global(named: name) }
    func didInstantiate(_ module: WasmDynamicLinker.LoadedModule) throws { bridge.mirror() }
}

@_cdecl("iso_mixed_memory_attach")
func memoryAttach(_ m: UnsafeMutablePointer<wasm_rt_memory_t>?, _ initialPages: UInt64) { iso_mixed_memory_sync(m) }
@_cdecl("iso_mixed_memory_grow")
func memoryGrow(_ pages: UInt64) -> UInt64 {
    let old = (try? bridge.memory.grow(by: Int(pages), store: bridge.store)) ?? -1
    return old < 0 ? UInt64.max : UInt64(old)
}
@_cdecl("iso_mixed_memory_base")
func memoryBase() -> UnsafeMutablePointer<UInt8>? {
    if let base = bridge.memoryBasePointer { return base }
    let (address, stable) = bridge.memory.unsafeBaseAddress
    let base = address?.assumingMemoryBound(to: UInt8.self)
    if stable { bridge.memoryBasePointer = base }
    return base
}
@_cdecl("iso_mixed_memory_byte_count")
func memoryByteCount() -> UInt64 { UInt64(bridge.memory.byteCount) }

@_cdecl("iso_mixed_import_call")
func importCall(_ index: UInt32, _ a: UnsafePointer<UInt64>?, _ r: UnsafeMutablePointer<UInt64>?) {
    let b = bridge!
    let i = Int(index)
    let function: Function
    if let f = b.importFunctions[i] {
        function = f
    } else {
        let name = String(cString: iso_mixed_import_name(index))
        guard let f = b.linker.loaded.lazy.compactMap({ $0.instance.exports[function: name] }).first else { fatalError("env.\(name) unresolved") }
        b.importFunctions[i] = f
        function = f
    }
    b.invokeInterpretedRaw(function, a, r)
}

@_cdecl("iso_mixed_slot_call")
func slotCall(_ tableSlot: UInt32, _ sig: UInt32, _ a: UnsafePointer<UInt64>?, _ r: UnsafeMutablePointer<UInt64>?) {
    let b = bridge!
    if b.counting { b.counts[tableSlot, default: 0] += 1 }
    let s = Int(tableSlot)
    if s >= b.slotFunctions.count { b.slotFunctions += [Function?](repeating: nil, count: s + 1 - b.slotFunctions.count) }
    let function: Function
    if let f = b.slotFunctions[s] {
        function = f
    } else {
        function = b.table.function(at: s, store: b.store)!
        b.slotFunctions[s] = function
    }
    b.invokeInterpretedRaw(function, a, r)
}


// MARK: - Run

nonisolated(unsafe) var stream: [UInt8] = []
nonisolated(unsafe) var wantsRender = false
nonisolated(unsafe) var linkerForLate: WasmDynamicLinker?

/// The host imports the runtime (and the shim, for the native copies) uses.
func hostImports(for module: Module, into imports: inout Imports, store: Store) {
    func memory(_ caller: borrowing Caller) -> Memory { caller.instance!.exports[memory: "memory"]! }
    for item in module.imports {
        guard case .function(let index) = item.descriptor, let type = module.functionType(at: index) else { continue }
        switch (item.module, item.name) {
        case ("wasi_snapshot_preview1", _):
            continue
        case ("iso_hot", "render_tree"):
            imports.define(module: item.module, name: item.name, Function(store: store, type: type) { caller, args in
                memory(caller).withUnsafeBufferPointer(offset: UInt(args[0].i32), count: Int(args[1].i32)) { stream += $0 }
                return []
            })
        case ("env", let name):
            imports.define(module: item.module, name: item.name, Function(store: store, type: type) { _, args in
                guard let f = linkerForLate?.loaded.lazy.compactMap({ $0.instance.exports[function: name] }).first else {
                    fatalError("env.\(name) unresolved")
                }
                return try f.invoke(args)
            })
        default:
            imports.define(module: item.module, name: item.name, Function(store: store, type: type) { _, _ in
                if item.name == "schedule_render" { wantsRender = true }
                if item.name == "epoch_millis" { return [.f64((Date().timeIntervalSince1970 * 1000).bitPattern)] }
                return type.results.map { t -> Value in
                    switch t {
                    case .i32: return item.name == "host_value" ? .i32(UInt32(bitPattern: -1)) : .i32(0)
                    case .i64: return .i64(0)
                    case .f32: return .f32(0)
                    default: return .f64(0)
                    }
                }
            })
        }
    }
}

/// Runs the drag benchmark in mixed mode; the runtime, shim, slot map and
/// side modules from the app's bundle. Returns the report's lines.
func runMixedBench(runtime runtimeBytes: [UInt8], shim shimBytes: [UInt8], slots: String, sides: [[UInt8]], routed: Set<String>) throws -> [String] {
    var log: [String] = []
    stream = []
    MixedLinkMain.routed = routed
    let started = Date()
    let b = Bridge()
    bridge = b
    let wasi = try WASIBridgeToHost(args: ["app"])
    // WasmKit requires a bridge closed before it goes.
    defer { try? wasi.close() }

    let runtimeModule = try parseWasm(bytes: runtimeBytes)
    var runtimeImports = Imports()
    wasi.link(to: &runtimeImports, store: b.store)
    hostImports(for: runtimeModule, into: &runtimeImports, store: b.store)
    let runtime = try runtimeModule.instantiate(store: b.store, imports: runtimeImports)
    b.memory = runtime.exports[memory: "memory"]!
    b.table = runtime.exports[table: "__indirect_function_table"]!
    b.stackPointer = runtime.exports[global: "__stack_pointer"]!
    let reserved = b.memory.unsafeBaseAddress.stable
    log.append("memory: \(reserved ? "reserved (guard pages)" : "NOT reserved: malloc-backed, moves as it grows")")

    iso_mixed_instantiate()
    b.nativeStackPointer = iso_mixed_stack_pointer()

    let originalCount = b.table.count
    for line in slots.split(separator: "\n") {
        let parts = line.split(separator: " ").map { Int($0)! }
        let (tableSlot, functionIndex) = (parts[0], parts[1])
        guard let f = runtime.function(at: functionIndex) else { fatalError("no function \(functionIndex)") }
        if tableSlot >= b.table.count { try b.table.grow(by: tableSlot + 1 - b.table.count, store: b.store) }
        if tableSlot >= originalCount { b.table[tableSlot] = f.reference }
    }

    let shimModule = try parseWasm(bytes: shimBytes)
    var shimImports = Imports()
    wasi.link(to: &shimImports, store: b.store)
    hostImports(for: shimModule, into: &shimImports, store: b.store)
    shimImports.define(module: "env", name: "memory", b.memory)
    shimImports.define(module: "env", name: "table", b.table)
    let shim = try shimModule.instantiate(store: b.store, imports: shimImports)
    b.shimImports = (0..<Int(iso_mixed_import_count)).map { shim.exports[function: "imp_\($0)"] }
    b.importIsEnv = (0..<Int(iso_mixed_import_count)).map { String(cString: iso_mixed_import_module(UInt32($0))) == "env" }
    b.importFunctions = (0..<Int(iso_mixed_import_count)).map { b.importIsEnv[$0] ? nil : b.shimImports[$0] }
    b.importTypes = (0..<Int(iso_mixed_import_count)).map { b.signatures[Int(iso_mixed_import_sig(UInt32($0)))] }
    b.shimCallIndirect = (0..<Int(iso_mixed_sig_count)).map { shim.exports[function: "ci_\($0)"]! }
    b.mirror()

    try wasi.initialize(runtime)
    b.linker = WasmDynamicLinker(main: MixedLinkMain(try WasmInstanceLinkMain(runtime)), store: b.store)
    linkerForLate = b.linker
    for side in sides { try b.linker.load(side) }
    log.append(String(format: "ready in %.0f ms", Date().timeIntervalSince(started) * 1000))
    log.append(try DragBench.run(
        call: { name, args in b.call(name, args, interpreted: runtime) },
        write: { address, bytes in
            b.memory.withUnsafeMutableBufferPointer(offset: UInt(address), count: bytes.count) { d in bytes.withUnsafeBytes { d.copyMemory(from: $0) } }
        },
        stream: { stream }, clearStream: { stream.removeAll(keepingCapacity: true) },
        takeWantsRender: { defer { wantsRender = false }; return wantsRender }))
    log.append("\(b.intoInterpreted) calls from native into the interpreter, \(MixedLinkMain.intoNative) from feature code into native code")
    return log
}
