// The fixed-name half of the C ABI, exported ONCE per linked image by this
// module (macro expansions add only per-declaration symbols on top). All
// exports use the formalized `@c` attribute (SE-0495); the wasm host imports
// come in through C interop (`swift_abi.h` declares them with
// import_module/import_name attributes), so no experimental import syntax is
// involved anywhere.

import SwiftABI
#if os(WASI)
@_spi(ExperimentalCustomExecutors) import _Concurrency
@_spi(ExperimentalScheduling) import _Concurrency
#endif

// MARK: - Staging buffers and byte boxes

@c(swift_ffi_alloc)
public func swiftFFIAlloc(_ byteCount: Int32) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer.allocate(byteCount: max(Int(byteCount), 1), alignment: 8)
}

@c(swift_ffi_dealloc)
public func swiftFFIDealloc(_ pointer: UnsafeMutableRawPointer) {
    pointer.deallocate()
}

@c(swift_ffi_string_len)
public func swiftFFIStringLen(_ handle: UnsafeMutableRawPointer) -> Int32 {
    Int32(Unmanaged<SwiftFFIStringBox>.fromOpaque(handle).takeUnretainedValue().bytes.count)
}

@c(swift_ffi_string_copy)
public func swiftFFIStringCopy(_ handle: UnsafeMutableRawPointer, _ dest: UnsafeMutableRawPointer) {
    let bytes = Unmanaged<SwiftFFIStringBox>.fromOpaque(handle).takeUnretainedValue().bytes
    bytes.withUnsafeBytes { buffer in
        if let base = buffer.baseAddress {
            dest.copyMemory(from: base, byteCount: buffer.count)
        }
    }
}

@c(swift_ffi_string_release)
public func swiftFFIStringRelease(_ handle: UnsafeMutableRawPointer) {
    Unmanaged<SwiftFFIStringBox>.fromOpaque(handle).release()
}

// MARK: - Lazy handles

@c(swift_ffi_lazy_get)
public func swiftFFILazyGet(_ handle: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let box = Unmanaged<SwiftFFILazyBox>.fromOpaque(handle).takeUnretainedValue()
    return Unmanaged.passRetained(SwiftFFIStringBox(bytes: box.bytes())).toOpaque()
}

@c(swift_ffi_lazy_release)
public func swiftFFILazyRelease(_ handle: UnsafeMutableRawPointer) {
    Unmanaged<SwiftFFILazyBox>.fromOpaque(handle).release()
}

// MARK: - Async host-implemented interface methods

/// In-flight `async` calls into host-implemented interface methods (the
/// foreign proxies): each call takes an id, sends it ahead of its arguments,
/// and suspends here until the host answers through `swift_ffi_async_resume`
/// (the result blob, or an ERROR blob). A host may also answer synchronously
/// by returning the result blob from the dispatch itself.
public enum SwiftFFIAsyncCalls {
    nonisolated(unsafe) private static var counter: Int32 = 0
    nonisolated(unsafe) private static var pending: [Int32: CheckedContinuation<[UInt8], any Error>] = [:]
    /// Answers that arrived before the caller suspended.
    nonisolated(unsafe) private static var early: [Int32: [UInt8]] = [:]
    private static let lock = SwiftFFILock()

    public static func next() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        counter &+= 1
        if counter <= 0 { counter = 1 }
        return counter
    }

    /// Awaits the answer for `callId`; `immediate` is the dispatch's own
    /// return blob — a non-empty, non-VOID blob IS the answer.
    public static func wait(_ callId: Int32, immediate: [UInt8]) async throws -> [UInt8] {
        if !immediate.isEmpty, SwiftFFIBlob.tag(of: immediate) != SwiftFFIBlob.Tag.void {
            if let message = SwiftFFIBlob.errorMessage(of: immediate) { throw BridgeError(message) }
            return immediate
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let answer = early.removeValue(forKey: callId) {
                lock.unlock()
                deliver(answer, to: continuation)
            } else {
                pending[callId] = continuation
                lock.unlock()
            }
        }
    }

    /// The host's answer for `callId`.
    public static func resume(_ callId: Int32, _ blob: [UInt8]) {
        lock.lock()
        guard let continuation = pending.removeValue(forKey: callId) else {
            early[callId] = blob
            lock.unlock()
            return
        }
        lock.unlock()
        deliver(blob, to: continuation)
    }

    private static func deliver(_ blob: [UInt8], to continuation: CheckedContinuation<[UInt8], any Error>) {
        if let message = SwiftFFIBlob.errorMessage(of: blob) {
            continuation.resume(throwing: BridgeError(message))
        } else {
            continuation.resume(returning: blob)
        }
    }
}

/// Delivers a host's answer to an in-flight async interface call: `blob` is
/// the result value — or an ERROR blob — borrowed for the call. Fixed-name
/// runtime entry on every platform (a wasm export; a C symbol natively).
@c(swift_ffi_async_resume)
public func swiftFFIAsyncResume(_ callId: Int32, _ blob: UnsafeRawPointer?, _ len: Int32) {
    SwiftFFIAsyncCalls.resume(callId, SwiftFFIBridge.bytes(blob, len))
}

#if os(WASI)

// MARK: - The wasm foreign-object channel

/// Wraps a consumer closure / foreign object / injected dependency (an id
/// into the host's foreign registry); calls dispatch through the fixed
/// `swift_ffi.closure_invoke` import, and the registry entry is dropped via
/// `swift_ffi.foreign_release` when ARC drops the dispatcher.
public final class SwiftFFIWasmDispatcher: SwiftFFIDispatcher {
    let id: Int32

    public init(id: Int32) { self.id = id }

    deinit { swift_ffi_wasm_foreign_release(id) }

    public func invoke(_ args: [UInt8]) throws -> [UInt8] {
        let packed = args.withUnsafeBytes {
            swift_ffi_wasm_closure_invoke(id, $0.baseAddress, Int32($0.count))
        }
        let bytes = SwiftFFIBridge.unpackForeignBytes(packed)
        if let message = SwiftFFIBlob.errorMessage(of: bytes) {
            throw BridgeError(message)
        }
        return bytes
    }
}

// MARK: - Async support

/// Delivers an async export's completion to the host: `blob` is the result
/// value — or an ERROR blob — borrowed for the call.
public func swiftFFIAsyncComplete(_ callId: Int32, _ blob: [UInt8]) {
    blob.withUnsafeBytes {
        swift_ffi_wasm_async_complete(callId, $0.baseAddress, Int32($0.count))
    }
}

/// Runs one enqueued Swift concurrency job — the export the host's microtask
/// calls back into after a `task_enqueue` import.
@c(swift_ffi_task_run)
public func swiftFFITaskRun(_ job: UnsafeMutableRawPointer) {
    unsafeBitCast(job, to: UnownedJob.self)
        .runSynchronously(on: SwiftFFIExecutorFactory.shared.asUnownedSerialExecutor())
}

/// The guest's ONE executor (single-threaded wasm): every job — the global
/// executor's, the MainActor's, and resumed continuations' — crosses to the
/// host through the `task_enqueue` import, and the host runs it through the
/// `swift_ffi_task_run` export. (A threaded reactor's is the main actor's
/// alone; see `SwiftFFIExecutorFactory`. Its `enqueue` is then called on any
/// guest thread, and the host takes the job to its own.) Installed as the
/// stdlib's executor FACTORY (Swift 6.3's `ExecutorFactory`): the platform
/// default on WASI is a CooperativeExecutor whose queue only drains inside
/// its own `run()`, which a reactor never calls — so `Task { @MainActor in
/// … }`, `MainActor.run`, and SwiftUI's `.task {}` would otherwise silently
/// never execute.
final class SwiftFFIHostExecutor: MainExecutor, TaskExecutor, @unchecked Sendable {
    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        swift_ffi_wasm_task_enqueue(unsafeBitCast(unowned, to: UnsafeMutableRawPointer.self))
    }

    var isMainExecutor: Bool { true }

    // RunLoopExecutor: the host owns the loop; nothing to run here.
    func run() throws {}
    func runUntil(_ condition: () -> Bool) throws {}
    func stop() {}

    func checkIsolated() {}
    func asUnownedSerialExecutor() -> UnownedSerialExecutor { UnownedSerialExecutor(ordinary: self) }
}

/// Timed jobs — `Task.sleep`, timeouts — cross to the host through the
/// `task_enqueue_after` import with their delay in milliseconds; the host
/// runs them through `swift_ffi_task_run` once it is up. Without this the
/// stdlib's delayed enqueue has no executor to hand the job to, and traps.
extension SwiftFFIHostExecutor: SchedulingExecutor {
    func enqueue<C: Clock>(_ job: consuming ExecutorJob, after delay: C.Duration,
                           tolerance: C.Duration?, clock: C) {
        let unowned = UnownedJob(job)
        var milliseconds: Int64 = 0
        if let duration = delay as? Duration {
            let (seconds, attoseconds) = duration.components
            milliseconds = seconds &* 1000 &+ (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
        }
        let clamped = Int32(clamping: max(0, milliseconds))
        swift_ffi_wasm_task_enqueue_after(unsafeBitCast(unowned, to: UnsafeMutableRawPointer.self), clamped)
    }
}

struct SwiftFFIExecutorFactory: ExecutorFactory {
    static let shared = SwiftFFIHostExecutor()
    static var mainExecutor: any MainExecutor { shared }
    #if _runtime(_multithreaded)
    /// A threaded reactor (wasm32-unknown-wasip1-threads) keeps the
    /// platform's default executor, its pool of guest threads, for every
    /// job that is not the main actor's; only the main actor's cross to the
    /// host, which runs them on the thread that drives the reactor.
    static var defaultExecutor: any TaskExecutor { PlatformExecutorFactory.defaultExecutor }
    #else
    static var defaultExecutor: any TaskExecutor { shared }
    #endif
}

private typealias SwiftFFIEnqueueOriginal = @convention(thin) (UnownedJob) -> Void
private typealias SwiftFFIEnqueueHook = @convention(thin) (UnownedJob, SwiftFFIEnqueueOriginal) -> Void

// The legacy hook globals (pre-6.3 toolchains route `swift_task_enqueueGlobal`
// through them); harmless alongside the factory.
@_silgen_name("swift_task_enqueueGlobal_hook")
private nonisolated(unsafe) var swiftFFIEnqueueGlobalHook: UnsafeMutableRawPointer?

@_silgen_name("swift_task_enqueueMainExecutor_hook")
private nonisolated(unsafe) var swiftFFIEnqueueMainHook: UnsafeMutableRawPointer?

private nonisolated(unsafe) var swiftFFIExecutorInstalled = false

/// Routes Swift concurrency — global AND main-actor — to the host's microtask
/// queue (`task_enqueue` out, `swift_ffi_task_run` back in). Async entry
/// thunks and interface registration call this before any `Task` exists;
/// idempotent. Timed jobs (`Task.sleep`) go out through `task_enqueue_after`.
public func swiftFFIInstallExecutor() {
    guard !swiftFFIExecutorInstalled else { return }
    swiftFFIExecutorInstalled = true
    // WASI has no OS availability: the 6.3 factory API is always present.
    _createExecutors(factory: SwiftFFIExecutorFactory.self)
    let hook: SwiftFFIEnqueueHook = { job, _ in
        swift_ffi_wasm_task_enqueue(unsafeBitCast(job, to: UnsafeMutableRawPointer.self))
    }
    #if !_runtime(_multithreaded)
    swiftFFIEnqueueGlobalHook = unsafeBitCast(hook, to: UnsafeMutableRawPointer?.self)
    #endif
    swiftFFIEnqueueMainHook = unsafeBitCast(hook, to: UnsafeMutableRawPointer?.self)
}

#endif  // os(WASI)
