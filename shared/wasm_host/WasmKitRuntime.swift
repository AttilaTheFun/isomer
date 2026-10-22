// `WasmKitRuntime` — a `WasmRuntime` on WasmKit, the Swift WebAssembly
// interpreter (MODULE.bazel's `wasmkit`, AttilaTheFun/WasmKit): the engine
// on every native host since 0.38, when it replaced WAMR. Apple's WasmView
// registers it as the default; an app that configures its own registers it
// before its first feature launches:
//
//     WasmRuntimeRegistry.register {
//         let runtime = WasmKitRuntime()
//         runtime.homeDirectory = NSHomeDirectory()
//         runtime.bundleIdentifier = Bundle.main.bundleIdentifier
//         return runtime
//     }
//
// What WAMR's C host did is done here in Swift:
//
//   • WASI (WasmKitWASI) with the guest's file system laid out as an app
//     container: /tmp a folder of the host's temporary directory,
//     /home/app the app's container (Documents, Library/Application Support,
//     Library/Caches), HOME, XDG_DATA_HOME, XDG_CACHE_HOME and
//     ISOMER_BUNDLE_IDENTIFIER in the environment with the host's ISO_*
//     variables.
//   • The six `iso_hot` render callbacks, each read positionally from the
//     module's own declared type (they are Swift-convention imports: two
//     trailing context words).
//   • The six fixed `swift_ffi` imports, from `SwiftFFIHostRuntime` (the
//     dependency table, the foreign registry, the job queue and async
//     answers), and the dependencies' register exports called at launch.
//   • The guest's Swift concurrency jobs drained on the main queue, held
//     while a tree the guest sent has yet to be drawn, with a frame after each drain that changed something.
//
// Threads: a reactor built for `wasm32-unknown-wasip1-threads` imports a
// shared memory and `wasi.thread-spawn`. Where WasmKit can make a shared
// memory (`canRunThreads`), its WASI Threads group gives every guest thread
// its own instance over that memory. The guest's main actor stays the
// thread that drives this runtime (the main thread): swift_ffi's executor
// sends main-actor jobs here, while the guest's other tasks run on its own
// thread pool. A host import a worker calls runs on the main thread: those
// that answer nothing are posted to it, those that answer wait for it.
// Guest threads live as long as the process (WasmKit's WASI Threads is
// process-scoped), so a threaded instance is kept, not torn down.

import Foundation
import IsomerWasmRuntime
import SwiftFFIWasmHost
@_spi(OnlyForCLI) import WasmKit
import WasmKitWASI
import WasmKitWASIThreads

public enum WasmKitRuntimeError: Error, CustomStringConvertible {
    case launchFailed(String)
    case missingExport(String)

    public var description: String {
        switch self {
        case .launchFailed(let reason): return "WasmKit launch failed: \(reason)"
        case .missingExport(let name): return "WasmKit: no export \(name)"
        }
    }
}

@MainActor
public final class WasmKitRuntime: WasmRuntime {
    /// The host directory the guest sees as its home (/home/app, with
    /// Documents, Library/Application Support and Library/Caches): where its
    /// FileManager directories and UserDefaults are kept. nil gives the guest
    /// none. Read at `launch`.
    public var homeDirectory: String?

    /// The guest's `Bundle.main.bundleIdentifier`. Read at `launch`.
    public var bundleIdentifier: String?

    /// The interpreter's stack for one call into the guest: its frames'
    /// locals and operands (the guest's own stack is in its memory). WAMR's
    /// host gave its interpreter 512 KiB; WasmKit's frames are larger.
    public var stackSize = 2 << 20

    /// Whether WasmKit can run a threaded reactor here: it makes a shared
    /// memory (an address-space reservation with guard pages, and the
    /// signal handling that traps out-of-bounds accesses through them).
    /// A host with a threaded and a single-threaded build of its reactor
    /// asks this to choose.
    public nonisolated static let canRunThreads: Bool = {
        var configuration = EngineConfiguration()
        configuration.features.insert(.threads)
        let engine = Engine(configuration: configuration)
        guard engine.configuration.memoryBoundsChecking == .mprotect else { return false }
        do {
            _ = try SharedMemory(
                engine: engine, type: MemoryType(min: 1, max: 1, shared: true),
                resourceLimiter: DefaultResourceLimiter())
            return true
        } catch {
            return false
        }
    }()

    /// `ISO_WASMKIT_TRACE` in the host's environment: each guest thread's
    /// instance and each swift_ffi import printed as it is made or called,
    /// with the thread it came on.
    nonisolated static let trace = ProcessInfo.processInfo.environment["ISO_WASMKIT_TRACE"] != nil

    private var engine: Engine?
    private var store: Store?
    private var instance: Instance?
    private var memory: Memory?
    private var wasi: WASIBridgeToHost?
    private var threads: WASIThreads?
    private var exports: [String: Function] = [:]
    private var pendingDependencies: [String: SwiftFFIDependency] = [:]
    private var ffi: SwiftFFIHostRuntime?
    private var hostImports: WasmHostImports?

    /// Stacks for calls into the guest, reused: one is taken for each call
    /// and given back when it returns (a host import may call in again, on
    /// a stack of its own).
    private final class StackBox {
        var stack: ExecutionStack
        init(engine: Engine) { stack = ExecutionStack(engine: engine) }
    }
    private var freeStacks: [StackBox] = []

    /// Threaded instances (and their WASI) stay alive with the process: the
    /// guest's threads may still be using them.
    private static var keptAlive: [AnyObject] = []

    public init() {}

    deinit {
        // A single-threaded instance closes its WASI (WasmKit requires it
        // before the bridge goes); a threaded one was kept (see `launch`).
        if threads == nil { try? wasi?.close() }
    }

    public func installDependencies(prefix: String, _ dependencies: [String: SwiftFFIDependency]) {
        pendingDependencies = dependencies
    }

    // MARK: - Launch

    public func launch(wasm: [UInt8], hostImports: WasmHostImports) throws {
        self.hostImports = hostImports
        var configuration = EngineConfiguration(stackSize: stackSize)
        configuration.features.insert(.threads)
        let engine = Engine(configuration: configuration)
        self.engine = engine
        let module: Module
        do {
            module = try parseWasm(bytes: wasm, features: configuration.features)
        } catch {
            throw WasmKitRuntimeError.launchFailed("parse: \(error)")
        }
        let wasi = try makeWASI()
        self.wasi = wasi

        let ffi = SwiftFFIHostRuntime(engine: EngineAdapter(runtime: self))
        ffi.dependencies = pendingDependencies
        ffi.jobScheduler = { [weak self] work in self?.schedule(work) }
        ffi.onJobsDrained = { [weak self] in self?.renderPending() }
        self.ffi = ffi

        let bindings = Bindings(runtime: self, hostImports: hostImports, ffi: ffi)
        let declared = Self.importTypes(module)
        let makeImports: @Sendable (Store) throws -> Imports = { store in
            if WasmKitRuntime.trace {
                print("[wasmkit-trace] instance for a \(Thread.isMainThread ? "main" : "guest") thread")
            }
            var imports = Imports()
            wasi.link(to: &imports, store: store)
            bindings.link(to: &imports, store: store, declared: declared)
            return imports
        }

        let store = Store(engine: engine)
        self.store = store
        let imports: Imports
        let threaded = module.imports.contains {
            if case .memory(let type) = $0.descriptor { return type.shared }
            return false
        }
        do {
            if threaded {
                let group = try WASIThreads(
                    module: module, engine: engine,
                    processControl: .init(
                        terminateAfterMainReturn: { code in
                            fatalError("[wasmkit] the reactor's main thread returned (\(code))")
                        },
                        terminateAfterWorkerFailure: { error in
                            // A trap on a guest thread: as a crash on a
                            // native thread, the process ends.
                            fatalError("[wasmkit] a guest thread trapped: \(error)")
                        }),
                    childImports: makeImports)
                threads = group
                imports = try group.makeImports(store: store)
            } else {
                imports = try makeImports(store)
            }
            let instance = try module.instantiate(store: store, imports: imports)
            self.instance = instance
            memory = instance.exports[memory: "memory"]
            try wasi.initialize(instance)
        } catch {
            throw WasmKitRuntimeError.launchFailed("\(error)")
        }
        if let threads {
            Self.keptAlive.append(threads)
            Self.keptAlive.append(wasi)
            hostImports.onLog("[wasmkit] threaded reactor: guest threads on")
        }
        activateDependencies()
    }

    /// The guest's environment and preopened directories: the host's ISO_*
    /// variables, /tmp, and (with a home directory) /home/app.
    private func makeWASI() throws -> WASIBridgeToHost {
        var environment: [String: String] = [:]
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("ISO_") {
            environment[key] = value
        }
        var preopens: [WASIBridgeToHost.Preopen] = []
        let files = FileManager.default
        #if os(Windows)
        // WasmKit's WASI opens no directory on Windows (a preopen fails
        // with EACCES): the guest has no file system there.
        let home: String? = nil
        #else
        let temporary = files.temporaryDirectory.appendingPathComponent("isomer-guest", isDirectory: true)
        try? files.createDirectory(at: temporary, withIntermediateDirectories: true)
        preopens.append(.init(guestPath: "/tmp", hostPath: temporary.path))
        let home = homeDirectory
        #endif
        if let home, !home.isEmpty {
            for made in ["Documents", "Library/Application Support", "Library/Caches"] {
                try? files.createDirectory(
                    atPath: (home as NSString).appendingPathComponent(made), withIntermediateDirectories: true)
            }
            preopens.append(.init(guestPath: "/home/app", hostPath: home))
            environment["HOME"] = "/home/app"
            environment["XDG_DATA_HOME"] = "/home/app/Library/Application Support"
            environment["XDG_CACHE_HOME"] = "/home/app/Library/Caches"
        }
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            environment["ISOMER_BUNDLE_IDENTIFIER"] = bundleIdentifier
        }
        do {
            return try WASIBridgeToHost(environment: environment, preopens: preopens)
        } catch {
            throw WasmKitRuntimeError.launchFailed("WASI: \(error)")
        }
    }

    /// Calls each dependency's register export once, so the guest's proxy
    /// factories exist before its first lookup (the C host's
    /// `swift_ffi_host_activate_dependencies`).
    private func activateDependencies() {
        var seen: Set<String> = []
        for dependency in pendingDependencies.values.sorted(by: { $0.key < $1.key }) {
            let symbol = dependency.registerSymbol
            guard !symbol.isEmpty, seen.insert(symbol).inserted else { continue }
            do {
                try call(symbol, [])
            } catch {
                hostImports?.onLog("[wasmkit] register \(symbol): \(error)")
            }
        }
    }

    /// Each imported function's declared type, by module and name.
    private static func importTypes(_ module: Module) -> [String: FunctionType] {
        var types: [String: FunctionType] = [:]
        for item in module.imports {
            guard case .function(let index) = item.descriptor,
                let type = module.functionType(at: index)
            else { continue }
            types[item.module + "." + item.name] = type
        }
        return types
    }

    // MARK: - Calls and memory

    @discardableResult
    public func call(_ name: String, _ args: [WasmScalar]) throws -> WasmScalar? {
        guard let instance, let engine else {
            hostImports?.onLog("[wasmkit] call \(name) after the instance is gone")
            return nil
        }
        let function: Function
        if let cached = exports[name] {
            function = cached
        } else {
            guard let found = instance.exports[function: name] else {
                throw WasmKitRuntimeError.missingExport(name)
            }
            exports[name] = found
            function = found
        }
        let box = freeStacks.popLast() ?? StackBox(engine: engine)
        defer { freeStacks.append(box) }
        let results = try function.invoke(args.map(Self.value), on: &box.stack)
        return results.first.map(Self.scalar)
    }

    public func readBytes(_ ptr: UInt32, _ len: UInt32) -> [UInt8] {
        guard let memory, len > 0 else { return [] }
        return memory.withUnsafeBufferPointer(offset: UInt(ptr), count: Int(len)) { Array($0) }
    }

    public func writeBytes(_ ptr: UInt32, _ bytes: [UInt8]) {
        guard let memory, !bytes.isEmpty else { return }
        memory.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: bytes.count) { destination in
            bytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
    }

    // MARK: - Jobs and frames

    public func pumpGuestJobs() {
        ffi?.runQueuedJobs()
    }

    public func renderPending() {
        do {
            try call("iso_hot_render_pending", [])
        } catch WasmKitRuntimeError.missingExport {
            _ = try? call("iso_hot_render", [])
        } catch {
            hostImports?.onLog("[wasmkit] render: \(error)")
        }
    }

    /// A tree has been handed to the host and not yet drawn; work that came
    /// due meanwhile waits for the run loop's next update, where the host
    /// lays the tree out (what that layout reports reaches the guest before
    /// its timers do).
    private var treeUndrawn = false
    private var heldWork: [() -> Void] = []

    private func schedule(_ work: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.treeUndrawn {
                self.heldWork.append(work)
            } else {
                work()
            }
        }
    }

    fileprivate func treeDelivered(_ bytes: [UInt8]) {
        hostImports?.onRenderTree(bytes)
        guard !treeUndrawn else { return }
        treeUndrawn = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.treeUndrawn = false
            let held = self.heldWork
            self.heldWork = []
            for work in held { work() }
        }
    }

    // MARK: - Conversions

    nonisolated static func value(_ scalar: WasmScalar) -> Value {
        switch scalar {
        case .i32(let v): return .i32(UInt32(bitPattern: v))
        case .i64(let v): return .i64(UInt64(bitPattern: v))
        case .f32(let v): return .f32(v.bitPattern)
        case .f64(let v): return .f64(v.bitPattern)
        }
    }

    nonisolated static func scalar(_ value: Value) -> WasmScalar {
        switch value {
        case .i32(let v): return .i32(Int32(bitPattern: v))
        case .i64(let v): return .i64(Int64(bitPattern: v))
        case .f32(let v): return .f32(Float(bitPattern: v))
        case .f64(let v): return .f64(Double(bitPattern: v))
        default: return .i32(0)
        }
    }

    /// The swift_ffi host runtime's view of this engine (it stages strings
    /// and blobs through the guest's allocator and memory).
    private final class EngineAdapter: SwiftFFIWasmEngine {
        unowned let runtime: WasmKitRuntime
        init(runtime: WasmKitRuntime) { self.runtime = runtime }
        func instantiate(wasm: [UInt8], swiftFFIImports: [SwiftFFIImport]) throws {}
        func call(_ name: String, _ args: [SwiftFFIScalar]) throws -> SwiftFFIScalar? {
            // A trap here (a guest job's) is logged and answers nothing: the
            // swift_ffi runtime's own calls would otherwise end the app on
            // any guest trap.
            MainActor.assumeIsolated {
                do {
                    return try runtime.call(name, args)
                } catch {
                    runtime.hostImports?.onLog("[wasmkit] \(name): \(error)")
                    return nil
                }
            }
        }
        func readBytes(_ ptr: UInt32, _ len: UInt32) -> [UInt8] {
            MainActor.assumeIsolated { runtime.readBytes(ptr, len) }
        }
        func writeBytes(_ ptr: UInt32, _ bytes: [UInt8]) {
            MainActor.assumeIsolated { runtime.writeBytes(ptr, bytes) }
        }
    }
}

// MARK: - Host imports

/// The `iso_hot` and `swift_ffi` imports for every store of the instance
/// (the main thread's and each guest thread's). Everything they reach
/// lives on the main thread: called there, they run in place; called on a
/// guest thread, they run on the main thread (posted when they answer
/// nothing, waited for when they do).
private final class Bindings: @unchecked Sendable {
    weak var runtime: WasmKitRuntime?
    let hostImports: WasmHostImports
    let ffi: SwiftFFIHostRuntime
    let standard: [String: SwiftFFIImport]
    /// The patches handed out (the typing signposts' frame numbers).
    let framesDelivered = Counter()

    final class Counter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func add() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }

    @MainActor
    init(runtime: WasmKitRuntime, hostImports: WasmHostImports, ffi: SwiftFFIHostRuntime) {
        self.runtime = runtime
        self.hostImports = hostImports
        self.ffi = ffi
        var standard: [String: SwiftFFIImport] = [:]
        for item in ffi.standardImports() { standard[item.name] = item }
        self.standard = standard
    }

    /// `body` on the main thread: in place there; from a guest thread
    /// posted (`wait` false: nothing to answer) or waited for.
    private func onMain<T>(wait: Bool, _ fallback: T, _ body: @escaping @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        if !wait {
            DispatchQueue.main.async { _ = MainActor.assumeIsolated(body) }
            return fallback
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    func link(to imports: inout Imports, store: Store, declared: [String: FunctionType]) {
        func define(_ module: String, _ name: String, _ body: @escaping Function.Implementation) {
            guard let type = declared[module + "." + name] else { return }
            imports.define(module: module, name: name, Function(store: store, type: type, body: body))
        }

        // iso_hot: (formal arguments…, context, error) — read positionally.
        define("iso_hot", "render_tree") { [self] caller, args in
            let bytes = try Self.read(caller, args[0], args[1])
            IsomerTypingSignposts.event("tree-delivered", "frame", self.framesDelivered.add(), bytes: bytes.count)
            _ = onMain(wait: false, ()) { [weak runtime] in runtime?.treeDelivered(bytes) }
            return []
        }
        define("iso_hot", "log") { [self] caller, args in
            let message = String(decoding: try Self.read(caller, args[0], args[1]), as: UTF8.self)
            let hostImports = self.hostImports
            _ = onMain(wait: false, ()) { hostImports.onLog(message) }
            return []
        }
        define("iso_hot", "epoch_millis") { [self] _, _ in
            [.f64(hostImports.epochMillis().bitPattern)]
        }
        define("iso_hot", "schedule_render") { [self] _, _ in
            let hostImports = self.hostImports
            _ = onMain(wait: false, ()) { hostImports.onScheduleRender() }
            return []
        }
        define("iso_hot", "platform_command") { [self] caller, args in
            let key = String(decoding: try Self.read(caller, args[0], args[1]), as: UTF8.self)
            let value = String(decoding: try Self.read(caller, args[2], args[3]), as: UTF8.self)
            let hostImports = self.hostImports
            _ = onMain(wait: false, ()) { hostImports.onPlatformCommand(key, value) }
            return []
        }
        define("iso_hot", "host_value") { [self] caller, args in
            // Its UTF-8 bytes into the guest's buffer when they fit; the full
            // length (the guest asks again with room), or -1 for none.
            let key = String(decoding: try Self.read(caller, args[0], args[1]), as: UTF8.self)
            let hostImports = self.hostImports
            let answer: String? = onMain(wait: true, nil) { hostImports.hostValue(key) }
            guard let answer else { return [.i32(UInt32(bitPattern: -1))] }
            let bytes = Array(answer.utf8)
            if bytes.count <= Int(args[3].i32) {
                try Self.write(caller, args[2], bytes)
            }
            return [.i32(UInt32(bytes.count))]
        }

        // swift_ffi: the host runtime's handlers, on the main thread.
        for (name, item) in standard {
            let answers = declared["swift_ffi." + name].map { !$0.results.isEmpty } ?? false
            define("swift_ffi", name) { [self] _, args in
                if WasmKitRuntime.trace {
                    print("[wasmkit-trace] swift_ffi.\(name) on \(Thread.isMainThread ? "the main thread" : "a guest thread") \(args)")
                }
                let scalars = args.map(WasmKitRuntime.scalar)
                let handler = item.handler
                let results: [SwiftFFIScalar] = onMain(wait: answers, []) { handler(scalars) }
                _ = self
                return results.map(WasmKitRuntime.value)
            }
        }
    }

    private static func memory(_ caller: borrowing Caller) throws -> Memory {
        guard let memory = caller.instance?.exports[memory: "memory"] else {
            throw WasmKitRuntimeError.launchFailed("the reactor exports no memory")
        }
        return memory
    }

    static func read(_ caller: borrowing Caller, _ pointer: Value, _ length: Value) throws -> [UInt8] {
        let memory = try memory(caller)
        let start = Int(pointer.i32), count = Int(length.i32)
        guard count > 0 else { return [] }
        guard start + count <= memory.byteCount else { return [] }
        return memory.withUnsafeBufferPointer(offset: UInt(start), count: count) { Array($0) }
    }

    static func write(_ caller: borrowing Caller, _ pointer: Value, _ bytes: [UInt8]) throws {
        let memory = try memory(caller)
        let start = Int(pointer.i32)
        guard !bytes.isEmpty, start + bytes.count <= memory.byteCount else { return }
        memory.withUnsafeMutableBufferPointer(offset: UInt(start), count: bytes.count) { destination in
            bytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
    }
}
