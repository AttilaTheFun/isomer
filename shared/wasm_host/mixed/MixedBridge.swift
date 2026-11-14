// Mixed mode's bridge between WasmKit and the native part (docs/
// side_modules.md): the runtime module stays one wasm module WasmKit
// interprets, and native copies (wasm2c) of a set of its hot functions run
// over the same memory, a mirrored function table and the one mutable
// global they share, `__stack_pointer`, synced at each crossing.
// Interpreted code never calls native code; the host enters native code at
// the runtime's entry points, and native code calls back into the
// interpreter for the functions it doesn't have (and for side modules').
// Features call a few heavy runtime functions natively (`routed`).
//
// The native part is a C library linked into the app (tools/wasm/
// mixed.bzl's wasm_mixed_native): one per process, so one bridge.

import IsomerMixedABI
import IsomerWasmKitRuntime
@_spi(OnlyForCLI) import WasmKit

func mixedValueType(_ c: Character) -> ValueType {
    switch c {
    case "i": return .i32
    case "I": return .i64
    case "f": return .f32
    default: return .f64
    }
}

func mixedSlot(_ v: Value) -> UInt64 {
    switch v {
    case .i32(let x): return UInt64(x)
    case .i64(let x): return x
    case .f32(let x): return UInt64(x)
    case .f64(let x): return x
    default: return 0
    }
}

func mixedValue(_ s: UInt64, _ t: ValueType) -> Value {
    switch t {
    case .i32: return .i32(UInt32(truncatingIfNeeded: s))
    case .i64: return .i64(s)
    case .f32: return .f32(UInt32(truncatingIfNeeded: s))
    case .f64: return .f64(s)
    default: return .i32(0)
    }
}

func mixedSignatureKey(_ type: FunctionType) -> String {
    func c(_ t: ValueType) -> String {
        switch t {
        case .i32: return "i"
        case .i64: return "I"
        case .f32: return "f"
        case .f64: return "F"
        default: return "?"
        }
    }
    return type.parameters.map(c).joined() + ":" + type.results.map(c).joined()
}

/// The process's one bridge (the native part is one C instance).
nonisolated(unsafe) var mixedBridge: MixedBridge?

final class MixedBridge {
    let engine: Engine
    let store: Store
    var memory: Memory!
    var table: Table!
    var stackPointer: Global!
    var nativeStackPointer: UnsafeMutablePointer<UInt32>!
    var signatures: [FunctionType] = []
    var signatureIndex: [String: UInt32] = [:]
    var nativeExports: [String: UInt32] = [:]
    var linker: WasmDynamicLinker!
    final class StackBox {
        var stack: ExecutionStack
        init(engine: Engine) { stack = ExecutionStack(engine: engine) }
    }
    var stacks: [StackBox] = []
    var depth = 0
    var memoryBasePointer: UnsafeMutablePointer<UInt8>?
    /// The interpreter's function behind each table slot, looked up once.
    var slotFunctions: [Function?] = []
    /// The native part's imports: the shim's function for each (the host's
    /// imports), or nil for a symbol a side module defines (`env.*`).
    var importFunctions: [Function?] = []
    var importIsEnv: [Bool] = []

    init(engine: Engine, store: Store) {
        self.engine = engine
        self.store = store
        for k in 0..<Int(iso_mixed_sig_count) {
            let key = String(cString: iso_mixed_sig(UInt32(k)))
            let parts = key.split(separator: ":", omittingEmptySubsequences: false)
            signatures.append(FunctionType(parameters: parts[0].map(mixedValueType), results: parts[1].map(mixedValueType)))
            signatureIndex[key] = UInt32(k)
        }
        for k in 0..<Int(iso_mixed_export_count) {
            nativeExports[String(cString: iso_mixed_export_name(UInt32(k)))] = UInt32(k)
        }
    }

    // Into native code from the host; out to the interpreter from native code.
    @inline(__always) func toNative() {
        nativeStackPointer.pointee = stackPointer.value.i32
        iso_mixed_memory_sync(iso_mixed_memory())
    }

    @inline(__always) func toInterpreter() {
        try! stackPointer.assign(.i32(nativeStackPointer.pointee))
    }

    /// An interpreted function called from native code, its arguments and
    /// result as raw slots.
    @inline(__always)
    func invokeInterpretedRaw(_ function: Function, _ a: UnsafePointer<UInt64>?, _ r: UnsafeMutablePointer<UInt64>?) {
        toInterpreter()
        if stacks.count <= depth { stacks.append(StackBox(engine: engine)) }
        let box = stacks[depth]
        depth += 1
        defer {
            depth -= 1
            toNative()
        }
        do {
            try function.invokeUnchecked(arguments: a, results: r, on: &box.stack)
        } catch {
            // Native code can't unwind a trap: as a trap in native code
            // (iso_mixed_trap_handler), the process ends.
            fatalError("[mixed] interpreted code trapped under native code: \(error)")
        }
    }

    /// Calls the runtime's export `name` from the host: its native copy when
    /// there is one, else the interpreted runtime's.
    func call(_ name: String, _ args: [Value], interpreted instance: Instance) throws -> [Value] {
        if let index = nativeExports[name] {
            let type = signatures[Int(iso_mixed_export_sig(index))]
            var a = args.map(mixedSlot)
            if a.isEmpty { a = [0] }
            var r: [UInt64] = [0]
            toNative()
            iso_mixed_call_export(index, a, &r)
            toInterpreter()
            return type.results.map { mixedValue(r[0], $0) }
        }
        guard let function = instance.exports[function: name] else {
            throw MixedRuntimeError.missingExport(name)
        }
        return try function(args)
    }

    /// Native slots the native module leaves null call the interpreter's
    /// function in the same slot of WasmKit's table.
    func mirror() {
        if table.count > Int(iso_mixed_table_size()) { iso_mixed_table_grow(UInt32(table.count)) }
        for index in 0..<table.count where iso_mixed_table_native_sig(UInt32(index)) == -1 {
            if let f = table.function(at: index, store: store), let sig = signatureIndex[mixedSignatureKey(f.type)] {
                iso_mixed_table_set_interpreted(UInt32(index), sig)
            }
        }
    }
}

/// Side modules linked over the mixed runtime: the runtime's WasmKit
/// instance, with the routed functions as native calls and the table
/// mirrored once a side module has filled its slots.
final class MixedLinkMain: WasmLinkMain {
    let inner: WasmInstanceLinkMain
    let bridge: MixedBridge
    /// Runtime functions a feature calls natively (one crossing a call).
    let routed: Set<String>

    init(_ inner: WasmInstanceLinkMain, bridge: MixedBridge, routed: Set<String>) {
        self.inner = inner
        self.bridge = bridge
        self.routed = routed
    }

    var memory: Memory { inner.memory }
    var table: Table { inner.table }
    var stackPointer: Global { inner.stackPointer }
    func allocate(size: Int, alignment: Int) throws -> UInt32 { try inner.allocate(size: size, alignment: alignment) }

    func function(named name: String) -> Function? {
        if routed.contains(name), let index = bridge.nativeExports[name] {
            let b = bridge
            let type = b.signatures[Int(iso_mixed_export_sig(index))]
            let resultType = type.results.first
            return Function(store: b.store, parameters: type.parameters, results: type.results) { _, args, results in
                withUnsafeTemporaryAllocation(of: UInt64.self, capacity: max(args.count, 1)) { a in
                    for k in 0..<args.count { a[k] = mixedSlot(args[k]) }
                    var r: UInt64 = 0
                    b.toNative()
                    iso_mixed_call_export(index, a.baseAddress, &r)
                    b.toInterpreter()
                    if let resultType { results[0] = mixedValue(r, resultType) }
                }
            }
        }
        return inner.function(named: name)
    }

    func global(named name: String) -> Global? { inner.global(named: name) }
    func didInstantiate(_ module: WasmDynamicLinker.LoadedModule) throws { bridge.mirror() }
}

// MARK: - The native part's callbacks

@_cdecl("iso_mixed_memory_attach")
func isoMixedMemoryAttach(_ memory: UnsafeMutableRawPointer?, _ initialPages: UInt64) {
    iso_mixed_memory_sync(memory)
}

@_cdecl("iso_mixed_memory_grow")
func isoMixedMemoryGrow(_ pages: UInt64) -> UInt64 {
    let b = mixedBridge!
    let old = (try? b.memory.grow(by: Int(pages), store: b.store)) ?? -1
    return old < 0 ? UInt64.max : UInt64(old)
}

@_cdecl("iso_mixed_memory_base")
func isoMixedMemoryBase() -> UnsafeMutablePointer<UInt8>? {
    let b = mixedBridge!
    if let base = b.memoryBasePointer { return base }
    let (address, stable) = b.memory.unsafeBaseAddress
    let base = address?.assumingMemoryBound(to: UInt8.self)
    if stable { b.memoryBasePointer = base }
    return base
}

@_cdecl("iso_mixed_memory_byte_count")
func isoMixedMemoryByteCount() -> UInt64 { UInt64(mixedBridge!.memory.byteCount) }

@_cdecl("iso_mixed_import_call")
func isoMixedImportCall(_ index: UInt32, _ a: UnsafePointer<UInt64>?, _ r: UnsafeMutablePointer<UInt64>?) {
    let b = mixedBridge!
    let i = Int(index)
    if MixedGuest.trace { print("[mixed-trace] native → import \(String(cString: iso_mixed_import_module(index))).\(String(cString: iso_mixed_import_name(index)))") }
    let function: Function
    if let f = b.importFunctions[i] {
        function = f
    } else {
        // A symbol a side module defines (the app's entry): found once.
        let name = String(cString: iso_mixed_import_name(index))
        guard let f = b.linker?.loaded.lazy.compactMap({ $0.instance.exports[function: name] }).first else {
            fatalError("[mixed] env.\(name) called before a side module defining it was loaded")
        }
        b.importFunctions[i] = f
        function = f
    }
    b.invokeInterpretedRaw(function, a, r)
}

@_cdecl("iso_mixed_slot_call")
func isoMixedSlotCall(_ tableSlot: UInt32, _ sig: UInt32, _ a: UnsafePointer<UInt64>?, _ r: UnsafeMutablePointer<UInt64>?) {
    let b = mixedBridge!
    let s = Int(tableSlot)
    if s >= b.slotFunctions.count {
        b.slotFunctions += [Function?](repeating: nil, count: s + 1 - b.slotFunctions.count)
    }
    let function: Function
    if let f = b.slotFunctions[s] {
        function = f
    } else {
        function = b.table.function(at: s, store: b.store)!
        b.slotFunctions[s] = function
    }
    b.invokeInterpretedRaw(function, a, r)
}
