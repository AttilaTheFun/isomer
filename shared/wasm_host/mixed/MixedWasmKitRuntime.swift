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
// One at a time: the native part is one C instance a process. A side module
// can't be unloaded, so a feature's reload is a new runtime: the old one's
// `release()` (or its deinit) lets its thread finish what was queued, then
// free the native part (the hand-over), and the new one's launch waits for
// that (MixedNativeClaim). A trap in native code (or in interpreted code
// native code called) ends the process, as a crash in native code would.
// Native code compiled without bounds checks relies on WasmKit's guard
// pages; where WasmKit couldn't reserve them, launch fails.

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
    case released
    case handOverTimedOut
    case missingExport(String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .alreadyRunning: return "a mixed runtime already runs in this process (the native part is one instance)"
        case .notLaunched: return "the mixed runtime isn't launched"
        case .released: return "the mixed runtime was released"
        case .handOverTimedOut: return "a released mixed runtime's guest didn't hand the native part over in time"
        case .missingExport(let name): return "the runtime module exports no \(name)"
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
///
/// It holds its `Thread` rather than being one: corelibs Foundation's
/// `Thread` (Linux, Windows) can't be subclassed from another module (its
/// overridable members name CoreFoundation's types, which it imports for
/// its implementation alone), and a block runs the same on every Foundation.
///
/// A released runtime stops its thread (`stop(finally:)`): what was queued
/// runs, then the hand-over, last; then the thread ends.
final class MixedEngineThread: @unchecked Sendable {
    private let condition = NSCondition()
    private var work: [() -> Void] = []
    /// How deep the guest's thread is in waits for the main thread.
    private var waiting = 0
    private var running = false
    /// The thread itself, made by `start()`.
    private var thread: Thread?
    /// `stop(finally:)` was called: work posted since is refused, but for
    /// the host's calls while the guest waits for the main thread (see
    /// `accepting`).
    private var stopping = false
    /// The hand-over `stop(finally:)` was given, until it runs: once the
    /// queue is empty, at the serve loop's top (never inside a wait for the
    /// main thread, where the guest's frames are still on the stack).
    private var handOver: (() -> Void)?
    /// What the guest's thread waits on the main thread for, by number. Each
    /// runs once, from the main queue or from a main thread that waits for
    /// this thread's hand-over (`answerMainRequests`), whichever comes first.
    private var mainRequests: [Int: () -> Void] = [:]
    private var nextMainRequest = 0

    init() {}

    /// The thread made and started: 64 MiB of stack (native code recurses on
    /// it), serving the queue until `stop(finally:)`.
    func start() {
        let thread = Thread { [self] in serve() }
        thread.stackSize = 64 << 20
        thread.qualityOfService = .userInteractive
        thread.name = "isomer-mixed-guest"
        self.thread = thread
        thread.start()
    }

    private func serve() {
        while true {
            condition.lock()
            running = false
            while work.isEmpty && handOver == nil { condition.wait() }
            if work.isEmpty, let finally = handOver {
                // Everything queued has run: the hand-over, last, and the
                // thread ends.
                handOver = nil
                running = true
                condition.unlock()
                finally()
                condition.lock()
                running = false
                condition.unlock()
                return
            }
            let next = work.removeFirst()
            running = true
            condition.unlock()
            next()
        }
    }

    /// Whether work may be queued now (under `condition`): always until
    /// `stop(finally:)`; after it, only while the guest waits for the main
    /// thread. Those are the host's calls back into the guest in answer to
    /// what it asked (swift_ffi staging a result): the guest can't finish
    /// without them, and they run before the hand-over, as it waits for the
    /// queue to empty.
    private var accepting: Bool { !stopping || waiting > 0 }

    /// Nothing queued, nothing running, not waiting for the main thread.
    var isIdle: Bool {
        condition.lock()
        defer { condition.unlock() }
        return work.isEmpty && !running && waiting == 0
    }

    /// Queues `item`; false (and nothing queued) once the thread is stopping.
    @discardableResult
    func post(_ item: @escaping () -> Void) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard accepting else { return false }
        work.append(item)
        condition.signal()
        return true
    }

    /// `body` on this thread, waited for (not from this thread). Throws
    /// `MixedRuntimeError.released` once the thread is stopping, rather than
    /// waiting for work that will never run.
    func sync<T>(_ body: @escaping () throws -> T) throws -> T {
        // Identity: Thread is NSObject's equality on Apple and corelibs, a
        // plain Swift class in Isomer's Foundation (the Swift SDK's on Android).
        if let thread, Thread.current === thread { return try body() }
        let done = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        let queued = post {
            result = Result { try body() }
            done.signal()
        }
        guard queued else { throw MixedRuntimeError.released }
        done.wait()
        return try result.get()
    }

    /// Stops the thread: what is queued runs, then `finally`, on this
    /// thread, and the thread ends. Work posted since is refused (`post`
    /// answers false, `sync` throws), but for calls in answer to the guest
    /// while it waits for the main thread. Once: a second stop does nothing.
    func stop(finally: @escaping () -> Void) {
        condition.lock()
        defer { condition.unlock() }
        guard !stopping else { return }
        stopping = true
        handOver = finally
        condition.signal()
    }

    /// Whether the guest's thread is waiting for the main thread now (so a
    /// call from the main thread may run on it at once, in turn).
    var isWaitingForMain: Bool {
        condition.lock()
        defer { condition.unlock() }
        return waiting > 0
    }

    /// Whether the guest's thread waits for the main thread to answer
    /// something no one has answered yet.
    var hasMainRequests: Bool {
        condition.lock()
        defer { condition.unlock() }
        return !mainRequests.isEmpty
    }

    /// On the main thread: answers now what the guest's thread waits on the
    /// main thread for, in the order it asked. For a main thread that waits
    /// for this thread (a launch waiting for this runtime's hand-over), so
    /// that neither waits for the other.
    func answerMainRequests() {
        condition.lock()
        let requests = mainRequests.sorted { $0.key < $1.key }.map(\.value)
        mainRequests.removeAll()
        condition.unlock()
        for request in requests { request() }
    }

    /// Request `number`, unless it was answered already (on the main thread).
    private func answerMainRequest(_ number: Int) {
        condition.lock()
        let request = mainRequests.removeValue(forKey: number)
        condition.unlock()
        request?()
    }

    /// From this thread: `body` on the main thread, this thread doing the
    /// work queued for it until `body` has answered. The request goes to the
    /// main queue, and to a main thread waiting for this thread's hand-over
    /// if there is one (which can't run the main queue meanwhile).
    func onMain<T>(_ body: @escaping @MainActor () -> T) -> T {
        var answer: T?
        var answered = false
        condition.lock()
        waiting += 1
        let number = nextMainRequest
        nextMainRequest += 1
        mainRequests[number] = {
            let value = MainActor.assumeIsolated(body)
            self.condition.lock()
            answer = value
            answered = true
            self.condition.broadcast()
            self.condition.unlock()
        }
        condition.unlock()
        DispatchQueue.main.async { self.answerMainRequest(number) }
        MixedNativeClaim.mainRequestPosted()
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

/// The process's one native part (one C instance): whether a runtime holds
/// it, and a released holder's hand-over until it has run.
///
/// A runtime claims it at launch and gives it back when released: its
/// thread finishes what was queued, frees the native part and lets go of
/// the bridge (the hand-over), and only then is the native part free. A
/// launch while a released runtime's hand-over is still to run waits for
/// it, on the main thread; the old guest may be waiting for the main thread
/// itself (a host value, a swift_ffi answer), so the launch answers those
/// requests as it waits: without running the main run loop (which would run
/// anything queued there, a view's update mid-reload among them), and
/// without the two threads waiting on each other.
enum MixedNativeClaim {
    private static let condition = NSCondition()
    /// A runtime holds the native part (from its launch to its hand-over).
    nonisolated(unsafe) private static var held = false
    /// The released holder's thread, while its hand-over is still to run.
    nonisolated(unsafe) private static var handingOver: MixedEngineThread?

    /// No runtime holds the native part, or the one that does was released
    /// (a launch now waits for its hand-over, then gets it).
    static var isAvailable: Bool {
        condition.lock()
        defer { condition.unlock() }
        return !held || handingOver != nil
    }

    /// Claims the native part for a launch, on the main thread. Held by a
    /// runtime not released: `alreadyRunning`. Held by a released one: waits
    /// for its hand-over (up to `timeout`, then `handOverTimedOut`),
    /// answering what its guest asks the main thread for meanwhile.
    @MainActor
    static func claim(timeout: TimeInterval) throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while held {
            guard let previous = handingOver else { throw MixedRuntimeError.alreadyRunning }
            if previous.hasMainRequests {
                condition.unlock()
                previous.answerMainRequests()
                condition.lock()
                continue
            }
            // Woken by the hand-over's end, or by a new request of the old
            // guest's (`mainRequestPosted`).
            if !condition.wait(until: deadline), held, Date() >= deadline {
                throw MixedRuntimeError.handOverTimedOut
            }
        }
        held = true
    }

    /// A released holder's hand-over is to run on `thread`.
    static func beginHandOver(_ thread: MixedEngineThread) {
        condition.lock()
        handingOver = thread
        condition.broadcast()
        condition.unlock()
    }

    /// The hand-over has run (on the old guest's thread): the native part is
    /// free.
    static func endHandOver() {
        condition.lock()
        held = false
        handingOver = nil
        condition.broadcast()
        condition.unlock()
    }

    /// A guest's thread asked the main thread for something: a launch
    /// waiting for a hand-over wakes to answer it.
    static func mainRequestPosted() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }
}

/// Whether a runtime holds the native part and whether it was released:
/// what `release()` and `deinit` (off the main actor) share, and the guest
/// reads to drop what a released guest sends its host.
final class MixedLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private var released = false
    private var guest: MixedGuest?

    var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }

    /// The runtime claimed the native part for `guest`.
    func claim(for guest: MixedGuest) {
        lock.lock()
        claimed = true
        self.guest = guest
        lock.unlock()
    }

    /// Releases the runtime, once, from any thread: stops `thread`, and,
    /// when the runtime holds the native part, hands it over last there.
    func release(thread: MixedEngineThread) {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        let held = claimed
        let guest = self.guest
        lock.unlock()
        guard held else {
            thread.stop {}
            return
        }
        MixedNativeClaim.beginHandOver(thread)
        thread.stop {
            guest?.release()
            MixedNativeClaim.endHandOver()
        }
    }
}

@MainActor
public final class MixedWasmKitRuntime: WasmRuntime {
    /// Dependency registers the runtime module was found not to export, each
    /// said once a process.
    private static var unregistered: Set<String> = []

    private let native: MixedNativePart
    private let thread = MixedEngineThread()
    private let lifecycle = MixedLifecycle()
    private var guest: MixedGuest?
    private var hostImports: WasmHostImports?
    private var ffi: SwiftFFIHostRuntime?
    private var pendingDependencies: [String: SwiftFFIDependency] = [:]
    /// Placeholder addresses handed out for allocations, counting down from
    /// the top of the 32-bit space (an address no guest of this size has).
    private var nextPlaceholder: UInt32 = 0xFFFF_F000

    /// The interpreter's stack for each stretch of interpreted code: a
    /// call from the host, or an interpreted function native code calls
    /// (each depth of crossing has its own). Its frames' locals and operands
    /// (the guest's own stack is in its memory). As `WasmKitRuntime`'s: a
    /// render interpreted throughout (ISO_MIXED_NATIVE=0, or no guard pages)
    /// recurses as deep as the reactor's, and the view tree an interpreted
    /// side module builds under native code nearly as deep; WasmKit's default
    /// (512 KiB) ran out in both on the Storybook. Read at `launch`.
    public var stackSize = 2 << 20

    /// How long `launch` waits for a released runtime's hand-over (its
    /// guest finishing what it was doing) before `handOverTimedOut`.
    public var handOverTimeout: TimeInterval = 10

    /// Whether a launch now gets the native part: no mixed runtime holds it,
    /// or the one that does was released (the launch waits for its
    /// hand-over). A host that finds it false runs the guest another way
    /// (`WasmKitRuntime`, interpreted).
    public nonisolated static var isAvailable: Bool { MixedNativeClaim.isAvailable }

    public init(native: MixedNativePart) {
        self.native = native
        thread.start()
    }

    /// A runtime let go of without `release()` releases itself; its thread
    /// hands the native part over as `release()` would.
    deinit {
        lifecycle.release(thread: thread)
    }

    public func installDependencies(prefix: String, _ dependencies: [String: SwiftFFIDependency]) {
        pendingDependencies.merge(dependencies) { _, new in new }
        ffi?.dependencies = pendingDependencies
    }

    /// Launches `wasm`, the runtime module, on the guest's thread. The
    /// native part is one a process: held by another runtime, launch throws
    /// `alreadyRunning`; held by a released one, launch waits for its
    /// hand-over first (`handOverTimeout`).
    public func launch(wasm: [UInt8], hostImports: WasmHostImports) throws {
        guard !lifecycle.isReleased else { throw MixedRuntimeError.released }
        guard guest == nil else { throw MixedRuntimeError.alreadyRunning }
        try MixedNativeClaim.claim(timeout: handOverTimeout)
        self.hostImports = hostImports
        let ffi = SwiftFFIHostRuntime(engine: Adapter(runtime: self))
        ffi.dependencies = pendingDependencies
        ffi.jobScheduler = { work in DispatchQueue.main.async(execute: work) }
        ffi.onJobsDrained = { [weak self] in self?.renderPending() }
        self.ffi = ffi
        var standard: [String: SwiftFFIImport] = [:]
        for item in ffi.standardImports() { standard[item.name] = item }
        let guest = MixedGuest(
            thread: thread, lifecycle: lifecycle, native: native, hostImports: hostImports, swiftFFI: standard,
            stackSize: stackSize)
        self.guest = guest
        lifecycle.claim(for: guest)
        do {
            try thread.sync { try guest.setUp(runtime: wasm) }
        } catch {
            // What setUp made of the native part goes with the runtime, so
            // the next launch can have it.
            release()
            throw error
        }
        // Each dependency's register export, so the guest's proxy factories
        // exist before its first lookup. A dependency the runtime module
        // wasn't linked with (no IsomerNetworkHost, say) has none: skipped,
        // and said once a process.
        var seen: Set<String> = []
        for dependency in pendingDependencies.values.sorted(by: { $0.key < $1.key }) {
            let symbol = dependency.registerSymbol
            guard !symbol.isEmpty, seen.insert(symbol).inserted else { continue }
            guard try thread.sync({ guest.exports(symbol) }) else {
                if Self.unregistered.insert(symbol).inserted {
                    hostImports.onLog("[mixed] the runtime module exports no \(symbol): that dependency isn't registered")
                }
                continue
            }
            _ = try? call(symbol, [])
        }
    }

    /// Loads `wasm`, a feature linked as a side module, over the launched
    /// runtime module (on the guest's thread), and runs its constructors.
    public func loadSideModule(wasm: [UInt8]) throws {
        guard let guest else { throw MixedRuntimeError.notLaunched }
        try thread.sync { try guest.loadSideModule(wasm) }
    }

    /// Lets go of the native part, so another runtime can launch with it (a
    /// side module can't be unloaded: a feature's reload is a new runtime).
    /// The guest's thread finishes what was queued, then frees the native
    /// part and the bridge, and ends; a launch meanwhile waits for that.
    /// Calls after it throw `released` (reads answer nothing, writes and
    /// renders do nothing), but for the host's answers to the guest while it
    /// still waits for the main thread; frames and commands the guest sends
    /// after it are dropped. Once; `deinit` releases a runtime not released.
    public func release() {
        lifecycle.release(thread: thread)
    }

    // MARK: Calls from the host

    private static let allocators: Set<String> = ["iso_hot_alloc", "swift_ffi_alloc"]
    private static let deallocators: Set<String> = ["iso_hot_free", "swift_ffi_dealloc"]

    public func call(_ name: String, _ args: [WasmScalar]) throws -> WasmScalar? {
        guard let guest else { throw MixedRuntimeError.notLaunched }
        // The guest's thread waits for the main thread (a host import): the
        // call runs there now, in turn (released or not: the guest needs it).
        if thread.isWaitingForMain || name == "iso_hot_pending_tasks" {
            return try thread.sync { try guest.call(name, args) }
        }
        guard !lifecycle.isReleased else { throw MixedRuntimeError.released }
        if Self.allocators.contains(name) {
            nextPlaceholder -= 16
            let placeholder = nextPlaceholder
            guard thread.post({ guest.allocate(name, args, placeholder: placeholder) }) else {
                throw MixedRuntimeError.released
            }
            return .i32(Int32(bitPattern: placeholder))
        }
        let queued = thread.post {
            do {
                _ = try guest.call(name, args)
            } catch {
                guest.log("[mixed] \(name): \(error)")
            }
            if Self.deallocators.contains(name), case .i32(let p)? = args.first { guest.forget(UInt32(bitPattern: p)) }
        }
        guard queued else { throw MixedRuntimeError.released }
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

    public func pumpGuestJobs() {
        guard !lifecycle.isReleased else { return }
        ffi?.runQueuedJobs()
    }

    /// The guest's thread has nothing queued or running and isn't waiting
    /// for the main thread. What it sent the main thread (frames, logs) may
    /// still be on the main queue.
    public var isIdle: Bool { thread.isIdle }

    /// Whether the native part runs. False when WasmKit couldn't reserve
    /// the runtime's memory with guard pages (an iPhone grants a process a
    /// few such reservations) and the native part checks no bounds: the
    /// guest then runs interpreted. Known after `launch`.
    public var isNative: Bool { guest?.isNative ?? false }

    public func renderPending() {
        guard !lifecycle.isReleased else { return }
        guest?.requestRender()
    }

    /// Native code's calls into the interpreter so far (ISO_MIXED_COUNT=1),
    /// and resets them.
    public func takeCrossings() -> MixedCrossings {
        guard let guest else { return MixedCrossings() }
        return (try? thread.sync { guest.takeCrossings() }) ?? MixedCrossings()
    }

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
    let lifecycle: MixedLifecycle
    let native: MixedNativePart
    let hostImports: WasmHostImports
    let swiftFFI: [String: SwiftFFIImport]
    let stackSize: Int
    private var bridge: MixedBridge!
    private var runtime: Instance!
    /// Native code runs (else the guest runs interpreted: see `setUp`).
    var isNative = false
    /// `setUp` made the native part's instance (`release` frees it).
    private var instantiated = false
    private var wasi: WASIBridgeToHost?
    /// Placeholder address → the real one.
    private var placeholders: [UInt32: UInt32] = [:]
    private let renderLock = NSLock()
    private var renderQueued = false

    init(
        thread: MixedEngineThread, lifecycle: MixedLifecycle, native: MixedNativePart, hostImports: WasmHostImports,
        swiftFFI: [String: SwiftFFIImport], stackSize: Int
    ) {
        self.thread = thread
        self.lifecycle = lifecycle
        self.native = native
        self.hostImports = hostImports
        self.swiftFFI = swiftFFI
        self.stackSize = stackSize
    }

    /// `ISO_MIXED_TRACE=1`: what the guest's thread does, printed there.
    static let trace = ProcessInfo.processInfo.environment["ISO_MIXED_TRACE"] != nil

    func log(_ message: String) {
        if Self.trace { print("[mixed-trace] \(message)") }
        let hostImports = self.hostImports
        DispatchQueue.main.async { hostImports.onLog(message) }
    }

    /// `body` on the main thread, unless the runtime is released by then: a
    /// released guest's frames, render requests and commands are its host's
    /// no longer (after a reload the new guest's are). Logs still go.
    private func toHost(_ body: @escaping () -> Void) {
        let lifecycle = self.lifecycle
        DispatchQueue.main.async {
            if !lifecycle.isReleased { body() }
        }
    }

    func setUp(runtime runtimeBytes: [UInt8]) throws {
        var configuration = EngineConfiguration(stackSize: stackSize, memoryBoundsChecking: .mprotect)
        // The features its runtime module was parsed with (WasmKitModules).
        configuration.features = WasmKitModules.features
        let engine = Engine(configuration: configuration)
        let store = Store(engine: engine)
        let b = MixedBridge(engine: engine, store: store)
        mixedBridge = b
        bridge = b
        let wasi = try WASIBridgeToHost(args: ["app"])
        self.wasi = wasi

        // Parsed once a process (WasmKitModules): a reload of the same
        // runtime module skips most of its launch.
        let runtimeModule = try WasmKitModules.module(runtimeBytes)
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
        // Native code without bounds checks needs the memory WasmKit reserved
        // with guard pages, whose base never moves. The reservation is 4 GiB
        // and more; an iPhone grants a process only a few, so one can be
        // refused (other engines in the process hold theirs), and WasmKit
        // then gives a memory that moves as it grows. Native code there would
        // fault: the guest runs interpreted instead, slower but safe.
        // ISO_MIXED_NATIVE=0 takes that path anywhere (a test's, a host's
        // that wants to compare).
        let forcedOff = ProcessInfo.processInfo.environment["ISO_MIXED_NATIVE"] == "0"
        let protected = memory.unsafeBaseAddress.stable || iso_mixed_checks_bounds() != 0
        b.nativeEnabled = protected && !forcedOff
        isNative = b.nativeEnabled
        if forcedOff {
            log("[mixed] ISO_MIXED_NATIVE=0: running interpreted")
        } else if !protected {
            log("[mixed] no guard pages for the runtime's memory (the reservation was refused): running interpreted")
        } else {
            iso_mixed_instantiate()
            instantiated = true
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
            b.runtimeSlotLimit = table.count
        }

        try wasi.initialize(runtime)
        b.linker = WasmDynamicLinker(main: MixedLinkMain(try WasmInstanceLinkMain(runtime), bridge: b, routed: native.routed), store: store)
    }

    func loadSideModule(_ bytes: [UInt8]) throws {
        try bridge.linker.load(bytes)
    }

    /// Whether the runtime module exports `name` (natively or interpreted).
    func exports(_ name: String) -> Bool {
        bridge.nativeExports[name] != nil || runtime.exports[function: name] != nil
    }

    /// The hand-over, the guest's thread's last work once its runtime is
    /// released: the native part's instance freed and the process's bridge
    /// let go of, so the next runtime's launch makes both again over its own
    /// memory. No native code of this guest's runs after it.
    func release() {
        if instantiated {
            iso_mixed_release()
            instantiated = false
        }
        if let bridge, mixedBridge === bridge { mixedBridge = nil }
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

    func takeCrossings() -> MixedCrossings {
        defer { bridge.crossings = MixedCrossings() }
        return bridge.crossings
    }

    func read(_ ptr: UInt32, _ len: UInt32) -> [UInt8] {
        let address = placeholders[ptr] ?? ptr
        guard len > 0, Int(address) + Int(len) <= bridge.memory.byteCount else { return [] }
        return (try? bridge.memory.withUnsafeBufferPointer(offset: UInt(address), count: Int(len)) { Array($0) }) ?? []
    }

    func write(_ ptr: UInt32, _ bytes: [UInt8]) {
        let address = placeholders[ptr] ?? ptr
        guard Int(address) + bytes.count <= bridge.memory.byteCount else { return }
        _ = try? bridge.memory.withUnsafeMutableBufferPointer(offset: UInt(address), count: bytes.count) { d in
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
        return (try? memory.withUnsafeBufferPointer(offset: UInt(pointer.i32), count: count) { Array($0) }) ?? []
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
                    toHost { hostImports.onRenderTree(tree) }
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
                implementation = { [self] _, _ in
                    toHost { hostImports.onScheduleRender() }
                    return []
                }
            case ("iso_hot", "platform_command"):
                implementation = { [self] caller, args in
                    let key = String(decoding: bytes(caller, args[0], args[1]), as: UTF8.self)
                    let value = String(decoding: bytes(caller, args[2], args[3]), as: UTF8.self)
                    toHost { hostImports.onPlatformCommand(key, value) }
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
                    if utf8.count <= Int(args[3].i32), let memory = memory(caller),
                       Int(args[2].i32) + utf8.count <= memory.byteCount {
                        _ = try? memory.withUnsafeMutableBufferPointer(offset: UInt(args[2].i32), count: utf8.count) { d in
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
                        toHost { _ = handler(scalars) }
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

// MARK: - Features over a runtime module

/// `launch` then `loadSideModule`: a feature over the runtime module in
/// mixed mode, for `WasmFeatureRuntime`'s side-module bundles.
extension MixedWasmKitRuntime: WasmSideModuleRuntime {}

extension WasmRuntimeModule {
    /// A runtime module in mixed mode with `native`, its native part (the
    /// app links its C; `wasm_mixed_native`), while the process's native
    /// part is free (`MixedWasmKitRuntime.isAvailable`), else interpreted by
    /// WasmKit (`WasmKitRuntime`, set up by `configure`), as a host that
    /// finds it held (another view's feature runs in mixed mode) must.
    /// `WasmFeatureRuntime` releases the running engine before it makes the
    /// next, so a reload of the same view finds it free and stays native.
    public static func mixed(
        name: String, source: WasmModuleSource, native: MixedNativePart,
        configure: @escaping @MainActor (WasmKitRuntime) -> Void = { _ in }
    ) -> WasmRuntimeModule {
        WasmRuntimeModule(name: name, source: source) {
            if MixedWasmKitRuntime.isAvailable { return MixedWasmKitRuntime(native: native) }
            let runtime = WasmKitRuntime()
            configure(runtime)
            return runtime
        }
    }
}
