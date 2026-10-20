// `WamrRuntime` — a `WasmRuntime` backed by WAMR (wasm-micro-runtime), the C
// interpreter that is already Android's wasm engine. It is the Apple alternative
// to `WasmKitRuntime`: a drop-in engine you can hand to `WasmFeatureRuntime`
// (`WasmFeatureRuntime(runtime: { _ in WamrRuntime() })`) to run the exact same wasm
// feature bundle under WAMR instead of the pure-Swift WasmKit interpreter.
//
// It wraps the shared C host (//shared/wamr_host, `CIsoWamr`) that already does
// all the engine-specific work — WAMR load/instantiate, the `iso_hot` render
// import binding, the generic swift_ffi DI transport — and surfaces it through
// the small `WasmRuntime` seam: `installDependencies` = the app's dependency
// table (registered with the generic C host at launch); `launch` = create the
// C host with the render callbacks; `call`/`readBytes`/`writeBytes` = the
// low-level C engine entry points. So every host that drives `WasmRuntime` (Apple's `WasmView`) runs
// unchanged on either engine — the only difference is which one you construct.
// It depends only on the engine-free `IsomerWasmRuntime` protocol module;
// WasmView's default engine on Apple (`WasmKitRuntime` is the other).

import CIsoWamr
import Foundation
import SwiftFFIWasmHost
import IsomerWasmRuntime

public enum WamrError: Error {
    case launchFailed(String)
}

@MainActor
public final class WamrRuntime: WasmRuntime {
    // Holds the Swift-side state the C callbacks reach through their `ctx`. Owned
    // by `self` (which outlives the C handle — destroyed in deinit), so the C
    // side can borrow it unretained.
    private final class Callbacks {
        var onRenderTree: ([UInt8]) -> Void = { _ in }
        var onLog: (String) -> Void = { _ in }
        var onScheduleRender: () -> Void = {}
        var onRunJobs: () -> Void = {}
        var onPlatformCommand: (String, String) -> Void = { _, _ in }
        var hostValue: (String) -> String? = { _ in nil }
    }

    /// One installed dependency, boxed so the C dispatch trampoline can reach
    /// the Swift dispatcher through an unretained context pointer (the boxes
    /// live as long as the runtime).
    private final class DependencyBox {
        let dependency: SwiftFFIDependency
        weak var runtime: SwiftFFIHostRuntime?
        init(_ dependency: SwiftFFIDependency, runtime: SwiftFFIHostRuntime?) {
            self.dependency = dependency
            self.runtime = runtime
        }
    }

    private var handle: OpaquePointer?
    private let callbacks = Callbacks()
    private var ffiPrefix: UnsafeMutablePointer<CChar>?
    private var pendingDependencies: [String: SwiftFFIDependency] = [:]
    private var dependencyBoxes: [DependencyBox] = []
    /// A Swift-side `SwiftFFIHostRuntime` over this engine for the generated
    /// dispatchers that need one (async service methods answer through its
    /// `resumeAsync`, which calls the guest's `swift_ffi_async_resume`).
    private var ffiRuntime: SwiftFFIHostRuntime?

    /// Adapts the C engine seam to the Swift host runtime's engine protocol
    /// (nonisolated by protocol; every call happens on the main actor, where
    /// the runtime lives).
    private final class EngineAdapter: SwiftFFIWasmEngine {
        unowned let runtime: WamrRuntime
        init(runtime: WamrRuntime) { self.runtime = runtime }
        func instantiate(wasm: [UInt8], swiftFFIImports: [SwiftFFIImport]) throws {}
        func call(_ name: String, _ args: [SwiftFFIWasmHost.SwiftFFIScalar]) throws -> SwiftFFIWasmHost.SwiftFFIScalar? {
            try MainActor.assumeIsolated {
                let mapped: [WasmScalar] = args.map {
                    switch $0 {
                    case .i32(let v): return .i32(v)
                    case .i64(let v): return .i64(v)
                    case .f32(let v): return .f32(v)
                    case .f64(let v): return .f64(v)
                    }
                }
                guard let result = try runtime.call(name, mapped) else { return nil }
                switch result {
                case .i32(let v): return .i32(v)
                case .i64(let v): return .i64(v)
                case .f32(let v): return .f32(v)
                case .f64(let v): return .f64(v)
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

    /// The hybrid delivery policy's fast tier: when set (the app links an
    /// embedded `wamrc --xip` image in its signed __TEXT segment — see
    /// //tools/wasm:embedded_xip_aot), `launch` runs THAT image in place via
    /// AOT instead of interpreting the passed bytes. Leave nil to run the
    /// interpreter — the dynamically-deliverable tier, e.g. an opt-in hotfix
    /// bundle that trades a bit of speed to avoid a shipped bug. iOS forbids
    /// dynamically mapped executable pages, so embedded-XIP is the ONLY AOT
    /// shape there.
    public nonisolated(unsafe) static var embeddedImage: UnsafeRawBufferPointer?

    /// The host directory the guest sees as its home (/home/app, with
    /// Documents, Library/Application Support and Library/Caches): where its
    /// FileManager directories and UserDefaults are kept. WasmView gives the
    /// app's own container; nil gives the guest none. Read at `launch`.
    public var homeDirectory: String?

    /// The guest's `Bundle.main.bundleIdentifier` (UserDefaults names the
    /// standard suite's file after it). Read at `launch`.
    public var bundleIdentifier: String?

    public init() {}

    deinit {
        jobsWake?.cancel()
        if let handle { iso_wamr_destroy(handle) }
        free(ffiPrefix)
        NSLog("[wamr] runtime instance destroyed")
    }

    public func installDependencies(prefix: String, _ dependencies: [String: SwiftFFIDependency]) {
        free(ffiPrefix)
        ffiPrefix = strdup(prefix)
        pendingDependencies = dependencies
    }

    public func launch(wasm: [UInt8], hostImports: WasmHostImports) throws {
        callbacks.onRenderTree = { [weak self] bytes in
            hostImports.onRenderTree(bytes)
            self?.treeDelivered()
        }
        callbacks.onLog = hostImports.onLog
        callbacks.onScheduleRender = hostImports.onScheduleRender
        callbacks.onPlatformCommand = hostImports.onPlatformCommand
        callbacks.hostValue = hostImports.hostValue

        var cb = IsoWamrCallbacks()
        cb.ctx = Unmanaged.passUnretained(callbacks).toOpaque()
        cb.on_tree = { ctx, bytes, len in
            guard let ctx, let bytes else { return }
            let cbs = Unmanaged<Callbacks>.fromOpaque(ctx).takeUnretainedValue()
            cbs.onRenderTree(Array(UnsafeBufferPointer(start: bytes, count: len)))
        }
        cb.on_log = { ctx, msg, len in
            guard let ctx, let msg else { return }
            let cbs = Unmanaged<Callbacks>.fromOpaque(ctx).takeUnretainedValue()
            cbs.onLog(WamrRuntime.string(msg, len))
        }
        cb.on_schedule_jobs = { ctx in
            // Guest jobs queued: drain them on the main queue (the thread that
            // drives this instance), then let the host render what changed.
            guard let ctx else { return }
            let cbs = Unmanaged<Callbacks>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { cbs.onRunJobs() }
        }
        cb.on_schedule_render = { ctx in
            guard let ctx else { return }
            Unmanaged<Callbacks>.fromOpaque(ctx).takeUnretainedValue().onScheduleRender()
        }
        cb.on_platform_command = { ctx, key, keyLen, value, valueLen in
            guard let ctx, let key, let value else { return }
            Unmanaged<Callbacks>.fromOpaque(ctx).takeUnretainedValue()
                .onPlatformCommand(WamrRuntime.string(key, keyLen), WamrRuntime.string(value, valueLen))
        }
        cb.host_value = { ctx, key, keyLen, out, capacity in
            guard let ctx, let key else { return -1 }
            let cbs = Unmanaged<Callbacks>.fromOpaque(ctx).takeUnretainedValue()
            return WamrRuntime.answer(cbs.hostValue(WamrRuntime.string(key, keyLen)), into: out, capacity: capacity)
        }
        // ALWAYS enable the swift_ffi transport: every v3 reactor imports the
        // fixed five-entry `swift_ffi` set unconditionally, so the natives
        // must be bound even when the app injects no dependencies (an
        // unlinked import would trap on the guest's first `dependencies[...]`
        // touch). The prefix VALUE is unused since v3 — non-NULL just opts in.
        if ffiPrefix == nil { ffiPrefix = strdup("swift_ffi") }
        cb.ffi_prefix = UnsafePointer(ffiPrefix)
        // Copied by the engine while the instance is made.
        let home: UnsafeMutablePointer<CChar>? = homeDirectory.flatMap { strdup($0) }
        let bundle: UnsafeMutablePointer<CChar>? = bundleIdentifier.flatMap { strdup($0) }
        defer { free(home); free(bundle) }
        cb.home_dir = UnsafePointer(home)
        cb.bundle_identifier = UnsafePointer(bundle)

        var err = [CChar](repeating: 0, count: 256)
        var created: OpaquePointer?
        if let image = Self.embeddedImage {
            created = iso_wamr_create_in_place(
                image.baseAddress?.assumingMemoryBound(to: UInt8.self),
                image.count, cb, &err, err.count)
            if created == nil, !wasm.isEmpty {
                // The embedded AOT image exists but this runtime can't load it
                // (an interp-only build — e.g. the simulator — links the shim
                // and image without the @wamr AOT loader). Fall back to the
                // bundled `.wasm` on the interpreter, the same tier
                // ISO_FORCE_INTERP selects explicitly.
                hostImports.onLog(
                    "embedded AOT unloadable (\(String(cString: err))); interpreting bundled wasm")
                created = wasm.withUnsafeBufferPointer { buf in
                    iso_wamr_create(buf.baseAddress, buf.count, cb, &err, err.count)
                }
            }
        } else {
            created = wasm.withUnsafeBufferPointer { buf in
                iso_wamr_create(buf.baseAddress, buf.count, cb, &err, err.count)
            }
        }
        guard let created else {
            throw WamrError.launchFailed(String(cString: err))
        }
        handle = created
        scheduleProfileDumps()
        callbacks.onRunJobs = { [weak self] in self?.pumpGuestJobs() }
        let ffi = SwiftFFIHostRuntime(engine: EngineAdapter(runtime: self))
        ffi.jobScheduler = { work in DispatchQueue.main.async(execute: work) }
        ffi.onJobsDrained = { [weak self] in self?.pumpGuestJobs() }
        ffiRuntime = ffi
        registerPendingDependencies()
    }

    /// A host value into the guest's buffer: its UTF-8 bytes up to
    /// `capacity`; the full length (the guest asks again with room for it),
    /// or -1 for none.
    static func answer(_ value: String?, into out: UnsafeMutablePointer<UInt8>?, capacity: Int) -> Int32 {
        guard let value else { return -1 }
        let bytes = Array(value.utf8)
        if let out, bytes.count <= capacity {
            bytes.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: bytes.count) }
        }
        return Int32(bytes.count)
    }

    public func renderPending() {
        guard let handle else { return }
        timingGuest("render") { iso_wamr_render_pending(handle) }
    }

    /// Drain the C host's job queue (guest `Task {}`s and async resumes); the
    /// C host renders after any ran (when they changed anything), so the
    /// resulting patch arrives through `onRenderTree` without a separate
    /// render request. Then wake again when
    /// the guest's next timed job is due (a `Task.sleep`): nothing else would
    /// — a sleeping task enqueues no job until its time has come, and the C
    /// host only keeps the deadline (as Android's WasmView drains it).
    ///
    /// Not while a tree the guest sent has yet to be drawn: the host lays a
    /// tree out in the run loop's update after the one it arrived in, and
    /// what that layout reports (a list's new height) reaches the guest
    /// before its timers do, as an app's own layout runs before a timer
    /// that came due meanwhile. (A chat keeping its place as a page of
    /// earlier rows went in above let go before the list had measured the
    /// page, and a slow frame showed the page's top.)
    public func pumpGuestJobs() {
        guard let handle else { return }
        if treeUndrawn { jobsHeld = true; return }
        _ = timingGuest("jobs") { iso_wamr_run_jobs(handle) }
        jobsWake?.cancel()
        jobsWake = nil
        let wait = iso_wamr_next_job_delay_ms(handle)
        guard wait >= 0 else { return }
        let wake = DispatchWorkItem { [weak self] in self?.pumpGuestJobs() }
        jobsWake = wake
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(wait)), execute: wake)
    }

    /// `ISO_WAMR_PROFILE=<seconds>[,<seconds>…]` in the environment of an
    /// app built with `--define wamr_profile=1`: the interpreter's
    /// per-function profile (cumulative since launch) printed to stdout at
    /// each of those times after launch — two, to take a stretch between.
    private func scheduleProfileDumps() {
        guard let spec = ProcessInfo.processInfo.environment["ISO_WAMR_PROFILE"] else { return }
        for seconds in spec.split(separator: ",").compactMap({ Double($0) }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, let handle = self.handle else { return }
                print("[wamr-profile] at \(seconds) s")
                print(String(format: "[guest-time] %.0f ms in %d calls, longest %.0f ms",
                             self.guestTime.total * 1000, self.guestTime.calls, self.guestTime.longest * 1000))
                iso_wamr_dump_profile(handle)
                print("[wamr-profile] end")
            }
        }
    }

    /// Time spent inside the guest on this thread since launch (frames,
    /// events, async work), printed with the profile (ISO_WAMR_PROFILE): the
    /// main thread's cost of the app, interpreter included.
    private var guestTime = (total: 0.0, calls: 0, longest: 0.0)

    /// `ISO_WAMR_SLOW=<ms>`: each call into the guest that takes longer is
    /// printed as it ends (`[slow-guest] <s since launch> <what> <ms>`),
    /// to tell which calls make a hitch.
    private static let slowCall = ProcessInfo.processInfo.environment["ISO_WAMR_SLOW"].flatMap(Double.init).map { $0 / 1000 }
    private let launched = DispatchTime.now().uptimeNanoseconds

    private func timingGuest<T>(_ what: @autoclosure () -> String, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            guestTime.total += seconds
            guestTime.calls += 1
            guestTime.longest = max(guestTime.longest, seconds)
            if let slow = Self.slowCall, seconds > slow {
                print(String(format: "[slow-guest] %.2f s %@ %.0f ms", Double(start - launched) / 1e9, what(), seconds * 1000))
            }
        }
        return try body()
    }

    /// The pending wake for the guest's next timed job (see pumpGuestJobs).
    private var jobsWake: DispatchWorkItem?
    /// A tree has been handed to the host and not yet drawn; jobs that came
    /// due meanwhile are held (see pumpGuestJobs).
    private var treeUndrawn = false
    private var jobsHeld = false

    /// A tree went to the host: held jobs run once the host has had the
    /// run loop's next update to draw it.
    private func treeDelivered() {
        guard !treeUndrawn else { return }
        treeUndrawn = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.treeUndrawn = false
            if self.jobsHeld {
                self.jobsHeld = false
                self.pumpGuestJobs()
            }
        }
    }

    /// The instance's swift_ffi host runtime (nil before launch or without a
    /// prefix) — the seam an app uses to call its module's exports (e.g. an
    /// async fetch completion) through the generic C host.
    public var ffiHost: OpaquePointer? {
        handle.flatMap { iso_wamr_ffi_host($0) }
    }

    /// Registers the pending dependency table with the generic C host and
    /// activates the guest's dictionary. Runs at the end of `launch`.
    private func registerPendingDependencies() {
        guard let handle, let host = iso_wamr_ffi_host(handle),
            !pendingDependencies.isEmpty
        else { return }
        dependencyBoxes = []
        var entries: [SwiftFFIHostDependency] = []
        var keyCStrings: [UnsafeMutablePointer<CChar>] = []
        for (key, dependency) in pendingDependencies {
            let box = DependencyBox(dependency, runtime: ffiRuntime)
            dependencyBoxes.append(box)
            let cKey = strdup(key)!
            let cRegistryKey = strdup(dependency.key)!
            let cRegisterSymbol = strdup(dependency.registerSymbol)!
            keyCStrings.append(cKey)
            keyCStrings.append(cRegistryKey)
            keyCStrings.append(cRegisterSymbol)
            var entry = SwiftFFIHostDependency()
            entry.key = UnsafePointer(cKey)
            entry.registry_key = UnsafePointer(cRegistryKey)
            entry.register_symbol = UnsafePointer(cRegisterSymbol)
            entry.lazy = dependency.lazy ? 1 : 0
            entry.ctx = Unmanaged.passUnretained(box).toOpaque()
            entry.dispatch = { ctx, args, argsLen, writer in
                guard let ctx, let writer else { return }
                let box = Unmanaged<DependencyBox>.fromOpaque(ctx).takeUnretainedValue()
                var blob: [UInt8] = []
                if let args, argsLen > 0 {
                    blob = Array(UnsafeBufferPointer(start: args, count: argsLen))
                }
                let result: [UInt8]
                if let bound = box.dependency.runtimeDispatcher, let runtime = box.runtime {
                    result = bound(runtime, blob)
                } else {
                    result = box.dependency.dispatcher(blob)
                }
                result.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    swift_ffi_blob_w_raw(writer, base, result.count)
                }
            }
            entries.append(entry)
        }
        // The runtime copies entries and keys.
        entries.withUnsafeBufferPointer { buffer in
            swift_ffi_host_set_dependencies(host, buffer.baseAddress, entries.count)
        }
        for cKey in keyCStrings { free(cKey) }
        iso_wamr_activate_dependencies(handle)
    }

    @discardableResult
    public func call(_ name: String, _ args: [WasmScalar]) throws -> WasmScalar? {
        guard let handle else {
            callbacks.onLog("[wamr] call \(name) after the instance is gone")
            return nil
        }
        let cargs = args.map(Self.toValue)
        var out = IsoWamrValue()
        let hasResult = timingGuest(name) {
            name.withCString { cName in
                cargs.withUnsafeBufferPointer { buf in
                    iso_wamr_call(handle, cName, buf.baseAddress, buf.count, &out)
                }
            }
        }
        return hasResult != 0 ? .i32(out.v.i32) : nil
    }

    public func readBytes(_ ptr: UInt32, _ len: UInt32) -> [UInt8] {
        guard let handle, len > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: Int(len))
        out.withUnsafeMutableBufferPointer { buf in
            iso_wamr_read_bytes(handle, ptr, len, buf.baseAddress)
        }
        return out
    }

    public func writeBytes(_ ptr: UInt32, _ bytes: [UInt8]) {
        guard let handle, !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { buf in
            iso_wamr_write_bytes(handle, ptr, buf.baseAddress, UInt32(buf.count))
        }
    }

    // MARK: - conversions

    private static func toValue(_ scalar: WasmScalar) -> IsoWamrValue {
        switch scalar {
        case .i32(let x): return IsoWamrValue(is_f64: 0, v: .init(i32: x))
        case .i64(let x): return IsoWamrValue(is_f64: 0, v: .init(i32: Int32(truncatingIfNeeded: x)))
        case .f32(let x): return IsoWamrValue(is_f64: 1, v: .init(f64: Double(x)))
        case .f64(let x): return IsoWamrValue(is_f64: 1, v: .init(f64: x))
        }
    }

    private static func string(_ ptr: UnsafePointer<CChar>, _ len: Int) -> String {
        let raw = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        return String(decoding: UnsafeBufferPointer(start: raw, count: len), as: UTF8.self)
    }
}
