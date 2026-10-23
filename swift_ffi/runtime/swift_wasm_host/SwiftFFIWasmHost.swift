// SwiftFFIWasmHost — the engine-agnostic Swift half of the *native host*
// transport, the peer of swift_ffi/runtime/ts/swift_ffi_runtime.ts. It lets a
// native Swift process load a swift_ffi wasm reactor, call its exports, and
// satisfy its `swift_ffi` foreign-interface imports with native Swift
// implementations — the same capability the TypeScript runtime gives the web,
// but for a native host driving an embedded WebAssembly engine.
//
// The concrete engine (WasmKit, …) is injected as a
// `SwiftFFIWasmEngine`, so this file — like the generated bindings that build
// on it — has NO WebAssembly dependency. A consumer supplies the engine (e.g. a
// thin WasmKit adapter); the generated per-module facade (`swift-host-wasm`
// kind) keeps only the marshalling.
//
// Ownership mirrors the TS runtime (the swift-java model): a `Swift<Proto>` wrapper owns
// a +1 handle to the boxed Swift instance and releases it on `close()` (or when
// the wrapper is deinited). Native implementations passed *into* wasm are
// parked in a foreign registry; the wasm proxy releases its entry via the
// `foreign_release` import when ARC drops the proxy on the guest side.

/// A single WebAssembly scalar slot crossing the engine boundary. Buffers and
/// strings are marshalled as `(i32 ptr, i32 len)` pairs of these.
public enum SwiftFFIScalar: Sendable, Equatable {
    case i32(Int32)
    case i64(Int64)
    case f32(Float)
    case f64(Double)

    public var i32Value: Int32 {
        switch self {
        case .i32(let v): return v
        case .i64(let v): return Int32(truncatingIfNeeded: v)
        case .f32(let v): return Int32(v)
        case .f64(let v): return Int32(v)
        }
    }

    public var i64Value: Int64 {
        switch self {
        case .i32(let v): return Int64(v)
        case .i64(let v): return v
        case .f32(let v): return Int64(v)
        case .f64(let v): return Int64(v)
        }
    }

    public var u32Value: UInt32 { UInt32(bitPattern: i32Value) }
    public var f64Value: Double {
        switch self {
        case .i32(let v): return Double(v)
        case .i64(let v): return Double(v)
        case .f32(let v): return Double(v)
        case .f64(let v): return v
        }
    }
    public var boolValue: Bool { i32Value != 0 }
}

/// One import the generated `swift_ffi` module table binds before instantiation:
/// a name (e.g. `greeter_foreign_GreetingObserver_greetingDelivered`) and the
/// native handler Swift's foreign proxy calls out to. The handler receives the
/// engine's declared argument slots (any trailing Swift calling-convention
/// context slots are appended after the logical ones, so logical parameters are
/// read positionally from the front) and returns the declared result slots.
public struct SwiftFFIImport {
    public let name: String
    public let handler: ([SwiftFFIScalar]) -> [SwiftFFIScalar]

    public init(name: String, handler: @escaping ([SwiftFFIScalar]) -> [SwiftFFIScalar]) {
        self.name = name
        self.handler = handler
    }
}

/// An error surfaced from a `throws`/`Result`-returning Swift export (message
/// only), the native peer of the TS `SwiftError`.
public struct SwiftFFIError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// The concrete WebAssembly engine, injected. `instantiate` binds the
/// `swift_ffi` module imports (plus whatever WASI shim the reactor needs) and
/// runs `_initialize`; afterwards `call`/`readBytes`/`writeBytes` operate on the
/// live instance's exports and linear memory.
public protocol SwiftFFIWasmEngine: AnyObject {
    /// Compile + instantiate `wasm`, binding `swiftFFIImports` in module
    /// `"swift_ffi"`, then run the reactor's `_initialize`.
    func instantiate(wasm: [UInt8], swiftFFIImports: [SwiftFFIImport]) throws
    /// Invoke an export; returns its single result slot (or nil for `Void`).
    func call(_ name: String, _ args: [SwiftFFIScalar]) throws -> SwiftFFIScalar?
    /// Copy `len` bytes out of linear memory at `ptr`.
    func readBytes(_ ptr: UInt32, _ len: UInt32) -> [UInt8]
    /// Copy `bytes` into linear memory at `ptr`.
    func writeBytes(_ ptr: UInt32, _ bytes: [UInt8])
}

/// A host-injected dependency (docs/wasm_di.md): one entry of the guest's
/// `dependencies` dictionary, generic across modules. `key` is the
/// interface's REGISTRY key (`swift_ffi_[<ns>_]<Interface>` — what the
/// guest's macro-registered proxy factory is filed under); `dispatcher` runs
/// one method call — the argument blob is ordinal-led (method ordinal first)
/// and the return value is the blob-encoded result (empty for Void). The
/// generated per-module `Dependencies` builders wrap typed implementations
/// into these; a host may also construct one by hand.
public struct SwiftFFIDependency {
    public let key: String
    /// The guest's register export for this interface
    /// (`swift_ffi_[<ns>_]register_<Proto>`) — what activation calls so the
    /// guest's proxy factory exists before the first lookup.
    public let registerSymbol: String
    public let lazy: Bool
    public let dispatcher: ([UInt8]) -> [UInt8]
    /// A dispatcher that needs the runtime — async methods complete back
    /// into the guest through it (`resumeAsync`). Preferred when set.
    public let runtimeDispatcher: ((SwiftFFIHostRuntime, [UInt8]) -> [UInt8])?

    public init(
        key: String, registerSymbol: String = "", lazy: Bool = true,
        dispatcher: @escaping ([UInt8]) -> [UInt8]
    ) {
        self.key = key
        self.registerSymbol = registerSymbol
        self.lazy = lazy
        self.dispatcher = dispatcher
        self.runtimeDispatcher = nil
    }

    public init(
        key: String, registerSymbol: String = "", lazy: Bool = true,
        runtimeDispatcher: @escaping (SwiftFFIHostRuntime, [UInt8]) -> [UInt8]
    ) {
        self.key = key
        self.registerSymbol = registerSymbol
        self.lazy = lazy
        self.dispatcher = { _ in [] }
        self.runtimeDispatcher = runtimeDispatcher
    }
}

/// The shared runtime the generated facade builds on: the injected engine,
/// string/byte staging over the fixed-name allocator, the foreign DISPATCHER
/// registry (closures, foreign objects, and injected dependencies all cross
/// the one `closure_invoke` channel), and the async pump. One per loaded
/// reactor; drive it from a single actor (the registry and call path are not
/// synchronized).
public final class SwiftFFIHostRuntime {
    public let engine: any SwiftFFIWasmEngine

    /// The dependency table the guest resolves through `dependency_get`,
    /// keyed by the dictionary key string. Set before the standard imports
    /// fire (i.e. before the guest's first lookup).
    public var dependencies: [String: SwiftFFIDependency] = [:]

    public init(engine: any SwiftFFIWasmEngine) {
        self.engine = engine
    }

    // MARK: The fixed `swift_ffi` import table

    /// The six fixed `swift_ffi` imports EVERY reactor declares (the SwiftFFI
    /// runtime references them unconditionally and reactors link with
    /// --no-gc-sections): `closure_invoke`, `dependency_get`,
    /// `foreign_release`, `task_enqueue`, and `async_complete`. Bind the whole
    /// set at instantiation.
    public func standardImports() -> [SwiftFFIImport] {
        [
            SwiftFFIImport(name: "closure_invoke") { [weak self] arguments in
                guard let self else { return [.i64(0)] }
                let blob = self.foreignBytes(arguments[1].u32Value, arguments[2].u32Value)
                guard let dispatcher = self.foreign(arguments[0].i32Value) else {
                    return [.i64(0)]
                }
                return [.i64(self.packForeign(dispatcher(blob)))]
            },
            SwiftFFIImport(name: "dependency_get") { [weak self] arguments in
                guard let self else { return [.i64(0)] }
                let key = self.foreignString(arguments[0].u32Value, arguments[1].u32Value)
                guard let dep = self.dependencies[key] else { return [.i64(0)] }
                // A blob of .list([.bool(lazy), .string(registry key), .int32(id)]).
                var blob: [UInt8] = []
                SwiftFFIMemory.appendI32(&blob, 8)  // LIST
                SwiftFFIMemory.appendI32(&blob, 0)
                SwiftFFIMemory.appendI64(&blob, 3)
                SwiftFFIMemory.appendI32(&blob, 4)  // BOOL
                SwiftFFIMemory.appendI32(&blob, 0)
                SwiftFFIMemory.appendI64(&blob, dep.lazy ? 1 : 0)
                let keyBytes = Array(dep.key.utf8)
                SwiftFFIMemory.appendI32(&blob, 5)  // STRING
                SwiftFFIMemory.appendI32(&blob, 0)
                SwiftFFIMemory.appendI64(&blob, Int64(keyBytes.count))
                blob.append(contentsOf: keyBytes)
                SwiftFFIMemory.appendI32(&blob, 2)  // INT32
                SwiftFFIMemory.appendI32(&blob, 0)
                let dispatcher: ([UInt8]) -> [UInt8]
                if let bound = dep.runtimeDispatcher {
                    dispatcher = { [unowned self] blob in bound(self, blob) }
                } else {
                    dispatcher = dep.dispatcher
                }
                SwiftFFIMemory.appendI64(&blob, Int64(self.registerForeign(dispatcher)))
                return [.i64(self.packForeign(blob))]
            },
            SwiftFFIImport(name: "foreign_release") { [weak self] arguments in
                self?.releaseForeign(arguments[0].i32Value)
                return []
            },
            SwiftFFIImport(name: "task_enqueue") { [weak self] arguments in
                self?.enqueueJob(arguments[0].u32Value)
                self?.scheduleDrain()
                return []
            },
            SwiftFFIImport(name: "task_enqueue_after") { [weak self] arguments in
                self?.enqueueJob(arguments[0].u32Value, afterMilliseconds: arguments[1].i32Value)
                return []
            },
            SwiftFFIImport(name: "async_complete") { [weak self] arguments in
                guard let self else { return [] }
                self.completeAsync(
                    arguments[0].i32Value,
                    blob: self.foreignBytes(arguments[1].u32Value, arguments[2].u32Value))
                return []
            },
        ]
    }

    // MARK: Raw calls

    @discardableResult
    public func call(_ name: String, _ args: [SwiftFFIScalar]) -> SwiftFFIScalar? {
        // Exports never trap in the bridge's own code paths; a failure here is
        // a programming error in the expansion, so surface it loudly.
        try! engine.call(name, args)
    }

    // MARK: String / byte staging (into the guest's linear memory)

    /// Allocates `count` bytes in guest memory via `swift_ffi_alloc`.
    public func alloc(_ count: Int) -> UInt32 {
        guard count > 0 else { return 0 }
        // No result: the engine's call failed (a trap; the engine logs why).
        guard let result = call("swift_ffi_alloc", [.i32(Int32(count))]) else {
            fatalError("swift_ffi_alloc(\(count)) failed in the guest; the engine's log says why")
        }
        return result.u32Value
    }

    public func dealloc(_ ptr: UInt32) {
        guard ptr != 0 else { return }
        call("swift_ffi_dealloc", [.i32(Int32(bitPattern: ptr))])
    }

    /// Zeroes `count` bytes at `ptr` (a struct out-buffer or error slot, so the
    /// error path never reads uninitialized slots).
    public func zero(_ ptr: UInt32, _ count: Int) {
        guard ptr != 0, count > 0 else { return }
        engine.writeBytes(ptr, [UInt8](repeating: 0, count: count))
    }

    /// Reads a little-endian 32-bit slot (a `throws` error handle, or a struct
    /// field's ptr/len half).
    public func readU32(_ ptr: UInt32) -> UInt32 {
        let bytes = engine.readBytes(ptr, 4)
        guard bytes.count == 4 else { return 0 }
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    public func writeU32(_ ptr: UInt32, _ value: UInt32) {
        engine.writeBytes(ptr, [
            UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff),
        ])
    }

    /// Stages bytes into guest memory; the caller passes `(ptr, len)` to the
    /// export, then `drop()`s to free (allocation can grow/detach memory, so
    /// stage each buffer immediately before writing further).
    public func stageBytes(_ bytes: [UInt8]) -> (ptr: UInt32, len: UInt32) {
        guard !bytes.isEmpty else { return (0, 0) }
        let ptr = alloc(bytes.count)
        engine.writeBytes(ptr, bytes)
        return (ptr, UInt32(bytes.count))
    }

    public func stageString(_ value: String) -> (ptr: UInt32, len: UInt32) {
        stageBytes(Array(value.utf8))
    }

    /// Copies out and releases a +1 string/byte-box handle returned by an
    /// export (`swift_ffi_string_len` / `_copy` / `_release`).
    public func takeBytes(_ handle: UInt32) -> [UInt8] {
        guard handle != 0 else { return [] }
        let len = call("swift_ffi_string_len", [.i32(Int32(bitPattern: handle))])!.u32Value
        var result: [UInt8] = []
        if len > 0 {
            let ptr = alloc(Int(len))
            call("swift_ffi_string_copy", [.i32(Int32(bitPattern: handle)), .i32(Int32(bitPattern: ptr))])
            result = engine.readBytes(ptr, len)
            dealloc(ptr)
        }
        call("swift_ffi_string_release", [.i32(Int32(bitPattern: handle))])
        return result
    }

    public func takeString(_ handle: UInt32) -> String {
        String(decoding: takeBytes(handle), as: UTF8.self)
    }

    // MARK: Foreign registry (native impls passed into wasm as DISPATCHERS)

    private var foreignObjects: [Int32: ([UInt8]) -> [UInt8]] = [:]
    private var nextForeignID: Int32 = 0

    /// Parks a native dispatcher and returns its id; Swift's foreign proxy
    /// calls back through the `closure_invoke` import keyed by this id and
    /// releases it via `foreign_release` when the guest-side proxy is dropped.
    public func registerForeign(_ dispatcher: @escaping ([UInt8]) -> [UInt8]) -> Int32 {
        nextForeignID += 1
        foreignObjects[nextForeignID] = dispatcher
        return nextForeignID
    }

    public func foreign(_ id: Int32) -> (([UInt8]) -> [UInt8])? { foreignObjects[id] }
    public func releaseForeign(_ id: Int32) { foreignObjects[id] = nil }

    // MARK: Foreign-return packing (native impl -> wasm, freed by the guest)

    /// Allocates + copies bytes and returns them packed `(len << 32) | ptr` for
    /// a foreign method's return; the guest reads and frees the pointer
    /// (`swiftFFIUnpackForeignBytes`). Not dropped here.
    public func packForeign(_ bytes: [UInt8]) -> Int64 {
        guard !bytes.isEmpty else { return 0 }
        let ptr = alloc(bytes.count)
        engine.writeBytes(ptr, bytes)
        return Int64(bitPattern: (UInt64(bytes.count) << 32) | UInt64(ptr))
    }

    public func packForeign(_ string: String) -> Int64 {
        packForeign(Array(string.utf8))
    }

    /// Reads a `(ptr, len)` buffer argument arriving from a foreign call.
    public func foreignBytes(_ ptr: UInt32, _ len: UInt32) -> [UInt8] {
        len == 0 ? [] : engine.readBytes(ptr, len)
    }

    public func foreignString(_ ptr: UInt32, _ len: UInt32) -> String {
        String(decoding: foreignBytes(ptr, len), as: UTF8.self)
    }

    // MARK: Async pump (the cooperative wasm executor, driven synchronously)
    //
    // A swift_ffi reactor installs a serial executor whose `enqueue` calls the
    // `task_enqueue` import with an `UnownedJob` pointer; `swift_ffi_task_run`
    // runs one job to its next suspension. The guest completes an async export
    // through the fixed `async_complete` import with the RESULT BLOB (or an
    // ERROR blob). Because our foreign deps are synchronous, an awaiting guest
    // function always has a runnable job, so draining the queue synchronously
    // advances it to completion — the native peer of the TS `queueMicrotask`
    // pump. The facade method stays `async` so it composes with Swift
    // concurrency (it just never truly suspends).

    private var callIdCounter: Int32 = 0
    public func makeCallId() -> Int32 {
        callIdCounter += 1
        return callIdCounter
    }

    private var jobQueue: [UInt32] = []
    /// Bound to the `task_enqueue` import: parks a job the pump will run.
    public func enqueueJob(_ job: UInt32) { jobQueue.append(job) }

    /// Bound to the `task_enqueue_after` import: a timed job (`Task.sleep`)
    /// joins the queue once its delay is up, drained on the host's thread
    /// through `jobScheduler`. A host without one has no loop to wake; the
    /// job then runs with the next drain.
    public func enqueueJob(_ job: UInt32, afterMilliseconds milliseconds: Int32) {
        guard let jobScheduler else { enqueueJob(job); return }
        nonisolated(unsafe) let host = self
        nonisolated(unsafe) let schedule = jobScheduler
        Task.detached {
            // In nanoseconds: `sleep(for:)` is iOS 16, and a host may be older.
            try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
            schedule {
                host.enqueueJob(job)
                host.runQueuedJobs()
            }
        }
    }

    /// A long-lived host (one that never awaits a facade call) drains queued
    /// jobs on its own thread: set this to hand a drain to that thread —
    /// e.g. `{ work in DispatchQueue.main.async(execute: work) }`. Guest
    /// `Task {}`s and async-resume continuations never run without it.
    public var jobScheduler: ((@escaping () -> Void) -> Void)?
    private var drainScheduled = false

    private func scheduleDrain() {
        guard let jobScheduler, !drainScheduled else { return }
        drainScheduled = true
        jobScheduler { [weak self] in
            guard let self else { return }
            self.drainScheduled = false
            self.runQueuedJobs()
        }
    }

    /// Runs every queued Swift concurrency job (jobs may enqueue more).
    public func runQueuedJobs() {
        var guardCount = 0
        while !jobQueue.isEmpty, guardCount < 10_000 {
            guardCount += 1
            let job = jobQueue.removeFirst()
            call("swift_ffi_task_run", [.i32(Int32(bitPattern: job))])
        }
        if !jobQueue.isEmpty { scheduleDrain() }
        onJobsDrained?()
    }

    /// Called after a drain ran jobs (a UI host re-renders here).
    public var onJobsDrained: (() -> Void)?

    /// Delivers a host implementation's answer to an in-flight async
    /// interface call (`swift_ffi_async_resume`), on the runtime's thread
    /// when a `jobScheduler` is set; the resumed continuation's job then runs
    /// through the same drain.
    public func resumeAsync(_ callId: Int32, blob: [UInt8]) {
        let deliver = { [weak self] in
            guard let self else { return }
            let staged = self.stageBytes(blob)
            self.call("swift_ffi_async_resume", [
                .i32(callId), .i32(Int32(bitPattern: staged.ptr)), .i32(Int32(bitPattern: staged.len)),
            ])
            if staged.ptr != 0 { self.dealloc(staged.ptr) }
            self.runQueuedJobs()
        }
        if let jobScheduler { jobScheduler(deliver) } else { deliver() }
    }

    private var asyncBlobs: [Int32: [UInt8]] = [:]
    private var asyncDone: Set<Int32> = []

    /// Bound to the `async_complete` import: records the result blob so the
    /// awaiting facade can decode it.
    public func completeAsync(_ callId: Int32, blob: [UInt8]) {
        asyncBlobs[callId] = blob
        asyncDone.insert(callId)
    }

    /// Drains the job queue until `callId` completes.
    public func pump(untilCallId callId: Int32) {
        while !asyncDone.contains(callId) {
            guard !jobQueue.isEmpty else {
                preconditionFailure(
                    "swift_ffi: async call \(callId) did not complete (the guest task "
                        + "suspended with no runnable job — host foreign deps are synchronous)")
            }
            let job = jobQueue.removeFirst()
            call("swift_ffi_task_run", [.i32(Int32(bitPattern: job))])
        }
    }

    /// Takes the completion blob and clears it.
    public func finishAsync(_ callId: Int32) -> [UInt8] {
        let result = asyncBlobs[callId] ?? []
        asyncBlobs[callId] = nil
        asyncDone.remove(callId)
        return result
    }
}

// MARK: - Little-endian slot codecs (packed @ExportedStruct buffers)
//
// Structs cross the C ABI as buffers of 8-byte slots, one per field: Double as
// f64, Int/Int32/Bool widened to i64, and String/[UInt8] as (len << 32) | ptr.
// The generated per-struct read/write helpers assemble/parse these buffers with
// the codecs below (the native peer of the TS DataView get/set calls).

/// Packed-slot access into a struct buffer staged in reactor memory:
/// 8-byte little-endian slots, one per field.
public enum SwiftFFIMemory {
    public static func loadU64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(bytes[offset + i]) << (8 * i) }
        return value
    }

    public static func storeU64(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt64) {
        for i in 0..<8 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xff) }
    }
}

// MARK: - Blob primitives (bridge v2 wire encoding; see swift_abi.h)

extension SwiftFFIMemory {
    /// Reads one value header, returning its (tag, aux). STRUCT/HANDLE/FOREIGN
    /// carry their type NAME after the header (aux is its byte length) — the
    /// name is consumed (and discarded) here.
    public static func readHeader(_ bytes: [UInt8], _ cursor: inout Int) -> (tag: Int32, aux: Int32) {
        let tag = readI32(bytes, &cursor)
        let aux = readI32(bytes, &cursor)
        if (tag == 7 || tag == 9 || tag == 11) && aux > 0 {
            cursor += Int(aux)
        }
        return (tag, aux)
    }

    /// A STRUCT/HANDLE/FOREIGN header: types are identified on the wire by
    /// NAME (aux is the name's byte length, the name follows).
    public static func appendTypeHeader(_ bytes: inout [UInt8], _ tag: Int32, _ name: String) {
        let nameBytes = Array(name.utf8)
        appendI32(&bytes, tag)
        appendI32(&bytes, Int32(nameBytes.count))
        bytes.append(contentsOf: nameBytes)
    }

    /// If the blob is an ERROR blob, its message.
    /// An ERROR blob carrying `message`.
    public static func errorBlob(_ message: String) -> [UInt8] {
        var out: [UInt8] = []
        appendI32(&out, 10); appendI32(&out, 0)
        let bytes = Array(message.utf8)
        appendI64(&out, Int64(bytes.count)); out.append(contentsOf: bytes)
        return out
    }

    /// A LIST blob of strings.
    public static func appendStringList(_ out: inout [UInt8], _ values: [String]) {
        appendI32(&out, 8); appendI32(&out, 0)
        appendI64(&out, Int64(values.count))
        for value in values {
            let bytes = Array(value.utf8)
            appendI32(&out, 5); appendI32(&out, 0)
            appendI64(&out, Int64(bytes.count)); out.append(contentsOf: bytes)
        }
    }

    /// Reads a LIST blob of strings at `cursor`.
    public static func readStringList(_ bytes: [UInt8], _ cursor: inout Int) -> [String] {
        _ = readHeader(bytes, &cursor)
        let count = Int(readI64(bytes, &cursor))
        var out: [String] = []
        for _ in 0..<max(count, 0) {
            _ = readHeader(bytes, &cursor)
            let n = Int(readI64(bytes, &cursor))
            out.append(String(decoding: readSlice(bytes, &cursor, n), as: UTF8.self))
        }
        return out
    }

    public static func errorMessage(of bytes: [UInt8]) -> String? {
        guard bytes.count >= 16 else { return nil }
        var cursor = 0
        let tag = readI32(bytes, &cursor)
        guard tag == 10 else { return nil }
        _ = readI32(bytes, &cursor)
        let count = Int(readI64(bytes, &cursor))
        guard cursor + count <= bytes.count else { return nil }
        return String(decoding: readSlice(bytes, &cursor, count), as: UTF8.self)
    }

    public static func appendI32(_ bytes: inout [UInt8], _ value: Int32) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    public static func appendI64(_ bytes: inout [UInt8], _ value: Int64) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    public static func readI32(_ bytes: [UInt8], _ cursor: inout Int) -> Int32 {
        let value = bytes[cursor..<cursor + 4].withUnsafeBytes {
            Int32(littleEndian: $0.loadUnaligned(as: Int32.self))
        }
        cursor += 4
        return value
    }

    public static func readI64(_ bytes: [UInt8], _ cursor: inout Int) -> Int64 {
        let value = bytes[cursor..<cursor + 8].withUnsafeBytes {
            Int64(littleEndian: $0.loadUnaligned(as: Int64.self))
        }
        cursor += 8
        return value
    }

    public static func readSlice(_ bytes: [UInt8], _ cursor: inout Int, _ count: Int) -> [UInt8] {
        let value = Array(bytes[cursor..<cursor + count])
        cursor += count
        return value
    }
}
