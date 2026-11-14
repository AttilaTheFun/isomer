// `MixedWasmKitRuntime` — a runtime module and its features (side modules)
// in mixed mode, the guest on a thread of its own (docs/side_modules.md).
//
// Mixed mode: WasmKit interprets the runtime module and its features; native
// copies of the runtime's hot functions (tools/wasm/mixed.bzl's
// `wasm_mixed_native`, linked into the app) run over the same memory and
// table (MixedBridge.swift). Measured on the Storybook and on 2048 played,
// it is several times faster than interpreting everything.
//
// Its own thread: the guest runs only on a thread with a large stack
// (native code recurses on it), so the main thread never waits for a guest's
// render. `WasmFeatureRuntime` drives it from the main thread as it drives
// any engine; here:
//   • calls that answer nothing (an event, a render, a size, a job) are
//     queued for the guest's thread, in order;
//   • an allocation answers at once with a placeholder address, made real
//     on the guest's thread when the queue reaches it; any queued call or
//     write naming the placeholder gets the real address, and a free of it
//     frees the real one (so the host's alloc, write, event, free sequence
//     runs without the main thread waiting);
//   • a read, and a call that must answer (iso_hot_pending_tasks), wait for
//     the queue;
//   • the guest's calls into the host (iso_hot, swift_ffi) run on the main
//     thread: posted when they answer nothing, waited for when they do,
//     the guest's thread serving the queue meanwhile, so the host's calls
//     back into the guest (swift_ffi staging a result) run there, in turn.
// Frames come to the host on the main thread.
//
// One per process: the native part is one C instance. A trap in native code
// (or in interpreted code native code called) ends the process, as a crash
// in native code would. Native code compiled without bounds checks relies on
// WasmKit's guard pages; where WasmKit couldn't reserve them, launch fails.

import Foundation
import IsomerMixedABI
import IsomerWasmKitRuntime
import IsomerWasmRuntime
import SwiftFFIWasmHost
@_spi(OnlyForCLI) import WasmKit
import WasmKitWASI

public enum MixedRuntimeError: Error, CustomStringConvertible {
    case alreadyRunning
    case notLaunched
    case missingExport(String)
    case unprotectedMemory
    case launchFailed(String)

    public var description: String {
        switch self {
        case .alreadyRunning: return "a mixed runtime already runs in this process (the native part is one instance)"
        case .notLaunched: return "the mixed runtime isn't launched"
        case .missingExport(let name): return "the runtime module exports no \(name)"
        case .unprotectedMemory:
            return "no guard pages for the runtime's memory, and the native part was built without bounds checks"
        case .launchFailed(let reason): return "launch failed: \(reason)"
        }
    }
}

/// What the native part needs beside its C, from `wasm_mixed_native`'s
/// outputs (the app's bundle): the WasmKit shim, the table slots the split
/// added, and the runtime functions features call natively.
public struct MixedNativePart: Sendable {
    public var shim: [UInt8]
    public var slots: String
    public var routed: Set<String>

    public init(shim: [UInt8], slots: String, routed: Set<String> = []) {
        self.shim = shim
        self.slots = slots
        self.routed = routed
    }
}

/// The guest's thread: work in order, and a way to wait (for the main
/// thread) while still doing the work queued for it.
final class MixedEngineThread: Thread, @unchecked Sendable {
    private let condition = NSCondition()
    private var work: [() -> Void] = []
    /// How deep the guest's thread is in waits for the main thread.
    private var waiting = 0
    private var running = false

    override init() {
        super.init()
        stackSize = 64 << 20
        qualityOfService = .userInteractive
        name = "isomer-mixed-guest"
    }

    override func main() {
        while true {
            condition.lock()
            running = false
            while work.isEmpty { condition.wait() }
            let next = work.removeFirst()
            running = true
            condition.unlock()
            next()
        }
    }

    /// Nothing queued, nothing running, not waiting for the main thread.
    var isIdle: Bool {
        condition.lock()
        defer { condition.unlock() }
        return work.isEmpty && !running && waiting == 0
    }

    func post(_ item: @escaping () -> Void) {
        condition.lock()
        work.append(item)
        condition.signal()
        condition.unlock()
    }

    /// `body` on this thread, waited for (not from this thread).
    func sync<T>(_ body: @escaping () throws -> T) throws -> T {
        if Thread.current == self { return try body() }
        let done = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        post {
            result = Result { try body() }
            done.signal()
        }
        done.wait()
        return try result.get()
    }

    /// Whether the guest's thread is waiting for the main thread now (so a
    /// call from the main thread may run on it at once, in turn).
    var isWaitingForMain: Bool {
        condition.lock()
        defer { condition.unlock() }
        return waiting > 0
    }

    /// From this thread: `body` on the main thread, this thread doing the
    /// work queued for it until `body` has answered.
    func onMain<T>(_ body: @escaping @MainActor () -> T) -> T {
        var answer: T?
        var answered = false
        condition.lock()
        waiting += 1
        condition.unlock()
        DispatchQueue.main.async {
            let value = MainActor.assumeIsolated(body)
            self.condition.lock()
            answer = value
            answered = true
            self.condition.broadcast()
            self.condition.unlock()
        }
        while true {
            condition.lock()
            while work.isEmpty && !answered { condition.wait() }
            if answered {
                waiting -= 1
                condition.unlock()
                return answer!
            }
            let next = work.removeFirst()
            condition.unlock()
            next()
        }
    }
}

@MainActor
public final class MixedWasmKitRuntime: WasmRuntime {
    nonisolated(unsafe) private static var running = false

    private let native: MixedNativePart
    private let thread = MixedEngineThread()
    private var guest: MixedGuest?
    private var hostImports: WasmHostImports?
    private var ffi: SwiftFFIHostRuntime?
    private var pendingDependencies: [String: SwiftFFIDependency] = [:]
    /// Placeholder addresses handed out for allocations, counting down from
    /// the top of the 32-bit space (an address no guest of this size has).
    private var nextPlaceholder: UInt32 = 0xFFFF_F000

    public init(native: MixedNativePart) {
        self.native = native
        thread.start()
    }

    public func installDependencies(prefix: String, _ dependencies: [String: SwiftFFIDependency]) {
        pendingDependencies.merge(dependencies) { _, new in new }
        ffi?.dependencies = pendingDependencies
    }

    /// Launches `wasm`, the runtime module, on the guest's thread.
    public func launch(wasm: [UInt8], hostImports: WasmHostImports) throws {
        guard !Self.running else { throw MixedRuntimeError.alreadyRunning }
        Self.running = true
        self.hostImports = hostImports
        let ffi = SwiftFFIHostRuntime(engine: Adapter(runtime: self))
        ffi.dependencies = pendingDependencies
        ffi.jobScheduler = { work in DispatchQueue.main.async(execute: work) }
        ffi.onJobsDrained = { [weak self] in self?.renderPending() }
        self.ffi = ffi
        var standard: [String: SwiftFFIImport] = [:]
        for item in ffi.standardImports() { standard[item.name] = item }
        let guest = MixedGuest(thread: thread, native: native, hostImports: hostImports, swiftFFI: standard)
        self.guest = guest
        try thread.sync { try guest.setUp(runtime: wasm) }
        // Each dependency's register export, so the guest's proxy factories
        // exist before its first lookup.
        var seen: Set<String> = []
        for dependency in pendingDependencies.values.sorted(by: { $0.key < $1.key }) {
            let symbol = dependency.registerSymbol
            guard !symbol.isEmpty, seen.insert(symbol).inserted else { continue }
            _ = try? call(symbol, [])
        }
    }

    /// Loads `wasm`, a feature linked as a side module, over the launched
    /// runtime module (on the guest's thread), and runs its constructors.
    public func loadSideModule(wasm: [UInt8]) throws {
        guard let guest else { throw MixedRuntimeError.notLaunched }
        try thread.sync { try guest.loadSideModule(wasm) }
    }

    // MARK: Calls from the host

    private static let allocators: Set<String> = ["iso_hot_alloc", "swift_ffi_alloc"]
    private static let deallocators: Set<String> = ["iso_hot_free", "swift_ffi_dealloc"]

    public func call(_ name: String, _ args: [WasmScalar]) throws -> WasmScalar? {
        guard let guest else { throw MixedRuntimeError.notLaunched }
        // The guest's thread waits for the main thread (a host import): the
        // call runs there now, in turn.
        if thread.isWaitingForMain || name == "iso_hot_pending_tasks" {
            return try thread.sync { try guest.call(name, args) }
        }
        if Self.allocators.contains(name) {
            nextPlaceholder -= 16
            let placeholder = nextPlaceholder
            thread.post { guest.allocate(name, args, placeholder: placeholder) }
            return .i32(Int32(bitPattern: placeholder))
        }
        thread.post {
            do {
                _ = try guest.call(name, args)
            } catch {
                guest.log("[mixed] \(name): \(error)")
            }
            if Self.deallocators.contains(name), case .i32(let p)? = args.first { guest.forget(UInt32(bitPattern: p)) }
        }
        return nil
    }

    public func readBytes(_ ptr: UInt32, _ len: UInt32) -> [UInt8] {
        guard let guest else { return [] }
        return (try? thread.sync { guest.read(ptr, len) }) ?? []
    }

    public func writeBytes(_ ptr: UInt32, _ bytes: [UInt8]) {
        guard let guest, !bytes.isEmpty else { return }
        if thread.isWaitingForMain {
            _ = try? thread.sync { guest.write(ptr, bytes) }
        } else {
            thread.post { guest.write(ptr, bytes) }
        }
    }

    public func pumpGuestJobs() { ffi?.runQueuedJobs() }

    /// The guest's thread has nothing queued or running and isn't waiting
    /// for the main thread. What it sent the main thread (frames, logs) may
    /// still be on the main queue.
    public var isIdle: Bool { thread.isIdle }

    public func renderPending() { guest?.requestRender() }

    /// swift_ffi's view of this engine, on the main thread.
    private final class Adapter: SwiftFFIWasmEngine {
        unowned let runtime: MixedWasmKitRuntime
        init(runtime: MixedWasmKitRuntime) { self.runtime = runtime }
        func instantiate(wasm: [UInt8], swiftFFIImports: [SwiftFFIImport]) throws {}
        func call(_ name: String, _ args: [SwiftFFIScalar]) throws -> SwiftFFIScalar? {
            MainActor.assumeIsolated {
                do {
                    return try runtime.call(name, args)
                } catch {
                    runtime.hostImports?.onLog("[mixed] \(name): \(error)")
                    return nil
                }
            }
        }
        func readBytes(_ ptr: UInt32, _ len: UInt32) -> [UInt8] { MainActor.assumeIsolated { runtime.readBytes(ptr, len) } }
        func writeBytes(_ ptr: UInt32, _ bytes: [UInt8]) { MainActor.assumeIsolated { runtime.writeBytes(ptr, bytes) } }
    }
}

/// The guest: everything here runs on the guest's thread.
final class MixedGuest: @unchecked Sendable {
    let thread: MixedEngineThread
    let native: MixedNativePart
    let hostImports: WasmHostImports
    let swiftFFI: [String: SwiftFFIImport]
    private var bridge: MixedBridge!
    private var runtime: Instance!
    private var wasi: WASIBridgeToHost?
    /// Placeholder address → the real one.
    private var placeholders: [UInt32: UInt32] = [:]
    private let renderLock = NSLock()
    private var renderQueued = false

    init(thread: MixedEngineThread, native: MixedNativePart, hostImports: WasmHostImports, swiftFFI: [String: SwiftFFIImport]) {
        self.thread = thread
        self.native = native
        self.hostImports = hostImports
        self.swiftFFI = swiftFFI
    }

    /// `ISO_MIXED_TRACE=1`: what the guest's thread does, printed there.
    static let trace = ProcessInfo.processInfo.environment["ISO_MIXED_TRACE"] != nil

    func log(_ message: String) {
        if Self.trace { print("[mixed-trace] \(message)") }
        let hostImports = self.hostImports
        DispatchQueue.main.async { hostImports.onLog(message) }
    }

    func setUp(runtime runtimeBytes: [UInt8]) throws {
        let engine = Engine(configuration: EngineConfiguration(memoryBoundsChecking: .mprotect))
        let store = Store(engine: engine)
        let b = MixedBridge(engine: engine, store: store)
        mixedBridge = b
        bridge = b
        let wasi = try WASIBridgeToHost(args: ["app"])
        self.wasi = wasi

        let runtimeModule = try parseWasm(bytes: runtimeBytes)
        var imports = Imports()
        wasi.link(to: &imports, store: store)
        bindHostImports(for: runtimeModule, into: &imports, store: store)
        let runtime = try runtimeModule.instantiate(store: store, imports: imports)
        self.runtime = runtime
        guard let memory = runtime.exports[memory: "memory"],
              let table = runtime.exports[table: "__indirect_function_table"],
              let stackPointer = runtime.exports[global: "__stack_pointer"]
        else { throw MixedRuntimeError.launchFailed("not a runtime module: no memory, table or __stack_pointer export") }
        b.memory = memory
        b.table = table
        b.stackPointer = stackPointer
        if !memory.unsafeBaseAddress.stable && iso_mixed_checks_bounds() == 0 {
            throw MixedRuntimeError.unprotectedMemory
        }

        iso_mixed_instantiate()
        b.nativeStackPointer = iso_mixed_stack_pointer()

        // The table slots the split added: the runtime's functions there.
        let originalCount = table.count
        for line in native.slots.split(separator: "\n") {
            let parts = line.split(separator: " ").compactMap { Int($0) }
            guard parts.count == 2 else { continue }
            guard let function = runtime.function(at: parts[1]) else {
                throw MixedRuntimeError.launchFailed("slots.txt names function \(parts[1]), which the runtime hasn't: another build's")
            }
            if parts[0] >= table.count { try table.grow(by: parts[0] + 1 - table.count, store: store) }
            if parts[0] >= originalCount { table[parts[0]] = function.reference }
        }

        // The shim: the host's imports for the native part, and calls
        // through the shared table into interpreted functions.
        let shimModule = try parseWasm(bytes: native.shim)
        var shimImports = Imports()
        wasi.link(to: &shimImports, store: store)
        bindHostImports(for: shimModule, into: &shimImports, store: store)
        shimImports.define(module: "env", name: "memory", memory)
        shimImports.define(module: "env", name: "table", table)
        let shim = try shimModule.instantiate(store: store, imports: shimImports)
        let importCount = Int(iso_mixed_import_count)
        b.importIsEnv = (0..<importCount).map { String(cString: iso_mixed_import_module(UInt32($0))) == "env" }
        b.importFunctions = (0..<importCount).map { b.importIsEnv[$0] ? nil : shim.exports[function: "imp_\($0)"] }
        b.mirror()

        try wasi.initialize(runtime)
        b.linker = WasmDynamicLinker(main: MixedLinkMain(try WasmInstanceLinkMain(runtime), bridge: b, routed: native.routed), store: store)
    }

    func loadSideModule(_ bytes: [UInt8]) throws {
        try bridge.linker.load(bytes)
    }

    // MARK: Calls

    private func translate(_ args: [WasmScalar]) -> [Value] {
        args.map {
            switch $0 {
            case .i32(let v):
                let p = UInt32(bitPattern: v)
                return .i32(placeholders[p] ?? p)
            case .i64(let v): return .i64(UInt64(bitPattern: v))
            case .f32(let v): return .f32(v.bitPattern)
            case .f64(let v): return .f64(v.bitPattern)
            }
        }
    }

    func call(_ name: String, _ args: [WasmScalar]) throws -> WasmScalar? {
        if Self.trace { print("[mixed-trace] call \(name) \(args)") }
        let results = try bridge.call(name, translate(args), interpreted: runtime)
        switch results.first {
        case .i32(let x)?: return .i32(Int32(bitPattern: x))
        case .i64(let x)?: return .i64(Int64(bitPattern: x))
        case .f32(let x)?: return .f32(Float(bitPattern: x))
        case .f64(let x)?: return .f64(Double(bitPattern: x))
        default: return nil
        }
    }

    func allocate(_ name: String, _ args: [WasmScalar], placeholder: UInt32) {
        do {
            if case .i32(let address)? = try call(name, args) { placeholders[placeholder] = UInt32(bitPattern: address) }
        } catch {
            log("[mixed] \(name): \(error)")
        }
    }

    func forget(_ placeholder: UInt32) { placeholders[placeholder] = nil }

    func read(_ ptr: UInt32, _ len: UInt32) -> [UInt8] {
        let address = placeholders[ptr] ?? ptr
        guard len > 0, Int(address) + Int(len) <= bridge.memory.byteCount else { return [] }
        return bridge.memory.withUnsafeBufferPointer(offset: UInt(address), count: Int(len)) { Array($0) }
    }

    func write(_ ptr: UInt32, _ bytes: [UInt8]) {
        let address = placeholders[ptr] ?? ptr
        guard Int(address) + bytes.count <= bridge.memory.byteCount else { return }
        bridge.memory.withUnsafeMutableBufferPointer(offset: UInt(address), count: bytes.count) { d in
            bytes.withUnsafeBytes { d.copyMemory(from: $0) }
        }
    }

    /// One render queued at a time, on the guest's thread.
    func requestRender() {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard !renderQueued else { return }
        renderQueued = true
        thread.post { [self] in
            renderLock.lock()
            renderQueued = false
            renderLock.unlock()
            do {
                if bridge.nativeExports["iso_hot_render_pending"] != nil || runtime.exports[function: "iso_hot_render_pending"] != nil {
                    _ = try call("iso_hot_render_pending", [])
                } else {
                    _ = try call("iso_hot_render", [])
                }
            } catch {
                log("[mixed] render: \(error)")
            }
        }
    }

    // MARK: The guest's imports

    private func memory(_ caller: borrowing Caller) -> Memory? { caller.instance?.exports[memory: "memory"] ?? bridge.memory }

    private func bytes(_ caller: borrowing Caller, _ pointer: Value, _ length: Value) -> [UInt8] {
        let count = Int(length.i32)
        guard count > 0, let memory = memory(caller), Int(pointer.i32) + count <= memory.byteCount else { return [] }
        return memory.withUnsafeBufferPointer(offset: UInt(pointer.i32), count: count) { Array($0) }
    }

    /// `iso_hot`, `swift_ffi` and the runtime's `env` symbols (a side
    /// module's, found when first called) for a module of the guest.
    private func bindHostImports(for module: Module, into imports: inout Imports, store: Store) {
        let hostImports = self.hostImports
        for item in module.imports {
            guard case .function(let index) = item.descriptor, let type = module.functionType(at: index) else { continue }
            let name = item.name
            let implementation: Function.Implementation
            switch (item.module, name) {
            case ("iso_hot", "render_tree"):
                implementation = { [self] caller, args in
                    let tree = bytes(caller, args[0], args[1])
                    if Self.trace { print("[mixed-trace] render_tree \(tree.count) bytes") }
                    DispatchQueue.main.async { hostImports.onRenderTree(tree) }
                    return []
                }
            case ("iso_hot", "log"):
                implementation = { [self] caller, args in
                    let message = String(decoding: bytes(caller, args[0], args[1]), as: UTF8.self)
                    DispatchQueue.main.async { hostImports.onLog(message) }
                    return []
                }
            case ("iso_hot", "epoch_millis"):
                implementation = { _, _ in [.f64(hostImports.epochMillis().bitPattern)] }
            case ("iso_hot", "schedule_render"):
                implementation = { _, _ in
                    DispatchQueue.main.async { hostImports.onScheduleRender() }
                    return []
                }
            case ("iso_hot", "platform_command"):
                implementation = { [self] caller, args in
                    let key = String(decoding: bytes(caller, args[0], args[1]), as: UTF8.self)
                    let value = String(decoding: bytes(caller, args[2], args[3]), as: UTF8.self)
                    DispatchQueue.main.async { hostImports.onPlatformCommand(key, value) }
                    return []
                }
            case ("iso_hot", "host_value"):
                // Its UTF-8 into the guest's buffer when it fits; its length,
                // or -1 for none.
                implementation = { [self] caller, args in
                    let key = String(decoding: bytes(caller, args[0], args[1]), as: UTF8.self)
                    guard let answer = thread.onMain({ hostImports.hostValue(key) }) else {
                        return [.i32(UInt32(bitPattern: -1))]
                    }
                    let utf8 = Array(answer.utf8)
                    if utf8.count <= Int(args[3].i32), let memory = memory(caller) {
                        memory.withUnsafeMutableBufferPointer(offset: UInt(args[2].i32), count: utf8.count) { d in
                            utf8.withUnsafeBytes { d.copyMemory(from: $0) }
                        }
                    }
                    return [.i32(UInt32(utf8.count))]
                }
            case ("swift_ffi", _):
                guard let handler = swiftFFI[name]?.handler else { continue }
                let answers = !type.results.isEmpty
                implementation = { [self] _, args in
                    let scalars: [SwiftFFIScalar] = args.map {
                        switch $0 {
                        case .i32(let x): return .i32(Int32(bitPattern: x))
                        case .i64(let x): return .i64(Int64(bitPattern: x))
                        case .f32(let x): return .f32(Float(bitPattern: x))
                        case .f64(let x): return .f64(Double(bitPattern: x))
                        default: return .i32(0)
                        }
                    }
                    guard answers else {
                        DispatchQueue.main.async { _ = handler(scalars) }
                        return []
                    }
                    let results = thread.onMain { handler(scalars) }
                    return zip(results, type.results).map { scalar, valueType in
                        switch scalar {
                        case .i32(let v): return .i32(UInt32(bitPattern: v))
                        case .i64(let v): return .i64(UInt64(bitPattern: v))
                        case .f32(let v): return .f32(v.bitPattern)
                        case .f64(let v): return .f64(v.bitPattern)
                        }
                    }
                }
            case ("env", _):
                guard name != "memory", name != "table" else { continue }
                implementation = { [self] _, args in
                    guard let function = bridge.linker?.function(named: name) else {
                        throw MixedRuntimeError.launchFailed("env.\(name) called before a side module defining it was loaded")
                    }
                    return try function(args)
                }
            default:
                continue
            }
            imports.define(module: item.module, name: name, Function(store: store, type: type, body: implementation))
        }
    }
}
