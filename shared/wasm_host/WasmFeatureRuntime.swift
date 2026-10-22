// The cross-platform core that runs one wasm feature reactor in-process and
// republishes the render tree it emits. It is deliberately free of any
// platform-UI framework (no Combine / SwiftUI / Compose) AND of any concrete
// WebAssembly engine: it drives a pluggable `WasmRuntime` (WasmKit by default;
// see WasmRuntime.swift), so every native host builds on it:
//   • Apple: `WasmViewModel` (an ObservableObject) wraps it and `WasmView`
//     renders `onTree` with real SwiftUI (IsomerTreeView).
//   • Android: a JNI host wraps it and forwards `onTree` to a Compose
//     @Composable that renders it with the Compose interpreter.
//
// A feature bundle exports the `iso_hot` render ABI (`iso_hot_start/render/
// resize/event/alloc/free`) and imports its render callbacks (`iso_hot.
// render_tree/log/epoch_millis/schedule_render`) — AND, for native
// dependencies, resolves the app-defined services the host injected through
// the generic **swift_ffi dependency dictionary** (docs/wasm_di.md), not a
// hand-written capability ABI. This runtime is module-agnostic: the app
// supplies its module prefix + dependency table.
//
// `load(bundle:)` hands the app's dependency table to the injected
// `WasmRuntime`, launches it with the `iso_hot` host callbacks, starts the
// feature, and pumps frames on demand. All engine specifics (the swift_ffi
// transport, WASI, the WasmKit `Imports`/`Caller` types) live inside the
// `WasmRuntime` implementation, never here.

import SwiftFFIWasmHost
import Foundation
import SwiftFFIWasmHost
// Re-export the engine seam so consumers of `IsomerWasmHost` still see
// `WasmRuntime` / `WasmHostImports` / `WasmScalar` unchanged after the split.
@_exported import IsomerWasmRuntime

@MainActor
public final class WasmFeatureRuntime {
    /// The app's swift_ffi module prefix (e.g. `"swift_ffi_appservices_"`) and
    /// dependency table, injected into the feature's `dependencies` dictionary.
    /// Set both before `load(...)`; build entries with the app's generated
    /// `Dependencies` builders. The framework is module-agnostic — every key,
    /// protocol, and implementation belongs to the embedding app.
    public var ffiModulePrefix: String?
    public var dependencies: [String: SwiftFFIDependency] = [:]


    /// The small assets shipped with the running bundle (localized strings,
    /// tiny images), keyed by relative path. Held for the current instance; a
    /// future asset service exposes them to the feature.
    public private(set) var assets: [String: Data] = [:]

    /// The latest serialized render tree (tree.fbs), or nil before first frame.
    /// Human-readable load/run status for a host's status line.
    public private(set) var status = "Not loaded"
    /// A newer render tree is available (fires on the main actor).
    public var onTree: (([UInt8]) -> Void)?
    /// `status` changed.
    public var onStatus: ((String) -> Void)?
    /// A fresh bundle is about to (re)load — fires BEFORE the new reactor's
    /// first frame so consumers reset retained patch state.
    public var onReload: (() -> Void)?
    /// "Arrange for `pumpRender()` to run on the main thread soon" — the frame
    /// scheduler. The host owns WHERE that happens: on Apple the default posts to
    /// the libdispatch main queue (drained by the runloop); on Android nothing
    /// drains that queue, so the host injects a poster onto the main Looper
    /// (Handler.post → `wasmPump` → `pumpRender`). Coalescing (many requests →
    /// one pump) is handled here via `renderScheduled`, so the host just needs to
    /// deliver the callback once.
    public var onScheduleRender: (() -> Void)?
    /// The host draws the tree itself (SwiftGPU): the reactor is configured
    /// for drawn navigation chrome before it starts (`iso_hot_configure`).
    public var drawnNavigation = false
    /// The host draws `map` host views with SwiftMap: the reactor's `Map` is
    /// the real map, not its placeholder.
    public var drawnMaps = false
    /// The platform channel the embedding serves (`HostBridge.platformCommand`
    /// / `hostValue` in the guest): "copy" to the clipboard, "openURL", … and
    /// "pasteboard", the clipboard's text. Unset: commands dropped, no values.
    public var onPlatformCommand: ((String, String) -> Void)?
    public var hostValue: ((String) -> String?)?

    private let log: (String) -> Void
    private let makeRuntime: @MainActor ([UInt8]) -> WasmRuntime
    private var runtime: WasmRuntime?

    /// The live engine behind the running feature (nil before `load`). The
    /// seam an app's dependency implementations use to call the feature's own
    /// exports back (e.g. an async completion) and re-render.
    public var engineRuntime: WasmRuntime? { runtime }
    private var renderScheduled = false
    private var resizeWork: DispatchWorkItem?

    private var width: Double = 900
    private var height: Double = 680

    /// - runtime: a factory for the pluggable wasm engine. Each `load(...)` makes
    ///   a fresh one (so state resets). Defaults to the engine the host app
    ///   registered with `WasmRuntimeRegistry` (isomer's Apple host
    ///   registers WasmKit as its default); hand in a conformer to override
    ///   per-instance.
    /// - log: where guest `log(...)` output and load diagnostics go. Defaults to
    ///   stdout; a host can route it to `NSLog` / Android logcat.
    public init(
        runtime: @escaping @MainActor ([UInt8]) -> any WasmRuntime = { WasmRuntimeRegistry.make(for: $0) },
        log: @escaping (String) -> Void = { print("[wasm-view] \($0)") }
    ) {
        self.makeRuntime = runtime
        self.log = log
    }

    /// Instantiate a service bundle (reactor + its small assets) and start the
    /// feature. Each call is a fresh engine/instance, so state resets — this is
    /// also the reload entry point (a hot-reload shadow or dynamic update).
    public func load(bundle: WasmServiceBundle) {
        assets = bundle.assets
        // Announce the (re)load BEFORE the new reactor's first frame: consumers
        // reset their retained patch tree here, and the fresh reactor's first
        // on_tree buffer is a full-tree root op that rebuilds it from scratch.
        // (Announcing after start would wipe the tree the first frame just
        // built.)
        onReload?()
        do {
            let runtime = makeRuntime(bundle.wasm)
            // Hand the engine the app's dependency table BEFORE launch — the
            // DI imports bind at instantiation. A table without the app's
            // prefix (WasmView's own entries, the network hosts, for an app
            // that injects nothing) installs too: the imports' names are
            // fixed since swift_ffi's v3, so the prefix only names the app's
            // exports `complete` calls.
            if !dependencies.isEmpty {
                runtime.installDependencies(prefix: ffiModulePrefix ?? "swift_ffi", dependencies)
            }
            // Guest Swift concurrency (`Task {}`s, async-service resumes): the
            // engines drain queued jobs on the main queue themselves and ask
            // for a render through `onScheduleRender` when any ran.
            // The `iso_hot` render callbacks the engine binds into the guest.
            let hostImports = WasmHostImports(
                onRenderTree: { [weak self] bytes in self?.deliverTree(bytes) },
                onLog: { [weak self] message in self?.log("[wasm] \(message)") },
                epochMillis: { Date().timeIntervalSince1970 * 1000 },
                onScheduleRender: { [weak self] in self?.requestRender() },
                onPlatformCommand: { [weak self] key, value in self?.onPlatformCommand?(key, value) },
                hostValue: { [weak self] key in self?.hostValue?(key) ?? nil }
            )
            // Instantiate + wire WASI + swift_ffi DI + iso_hot; runs _initialize.
            try runtime.launch(wasm: bundle.wasm, hostImports: hostImports)
            self.runtime = runtime

            // Replay the host appearance: it is typically reported once
            // (onAppear) BEFORE the bundle loads, where it has no runtime to
            // land in — without the replay the guest renders light.
            if let dark = lastDark {
                _ = try? runtime.call("iso_hot_set_color_scheme", [.i32(dark ? 1 : 0)])
            }
            // And the scene phase, when it is not the guest's own default
            // (active): a bundle loaded while the app is in the background.
            if lastScenePhase != 0 {
                _ = try? runtime.call("iso_hot_set_scene_phase", [.i32(lastScenePhase)])
            }
            // And the size classes, before the first build reads them.
            if let classes = lastSizeClasses {
                _ = try? runtime.call("iso_hot_set_size_classes", [.i32(classes.horizontal), .i32(classes.vertical)])
            }
            if drawnNavigation { configure(runtime, key: "navigation", value: "drawn") }
            if drawnMaps { configure(runtime, key: "maps", value: "drawn") }
            _ = try runtime.call("iso_hot_start", [.f64(width), .f64(height)])
            requestRender()
            setStatus("Loaded \(bundle.label)")
        } catch {
            setStatus("Load failed: \(error)")
            log("load failed: \(error)")
        }
    }

    /// `iso_hot_configure(key, value)` on a launched reactor (before start).
    private func configure(_ runtime: any WasmRuntime, key: String, value: String) {
        do {
            let keyBytes = Array(key.utf8), valBytes = Array(value.utf8)
            let keyPtr = try runtime.call("iso_hot_alloc", [.i32(Int32(keyBytes.count))])?.u32Value ?? 0
            runtime.writeBytes(keyPtr, keyBytes)
            let valPtr = try runtime.call("iso_hot_alloc", [.i32(Int32(valBytes.count))])?.u32Value ?? 0
            runtime.writeBytes(valPtr, valBytes)
            _ = try runtime.call("iso_hot_configure", [
                .i32(Int32(bitPattern: keyPtr)), .i32(Int32(keyBytes.count)),
                .i32(Int32(bitPattern: valPtr)), .i32(Int32(valBytes.count)),
            ])
            _ = try? runtime.call("iso_hot_free", [.i32(Int32(bitPattern: keyPtr))])
            _ = try? runtime.call("iso_hot_free", [.i32(Int32(bitPattern: valPtr))])
            log("configured \(key)=\(value)")
        } catch {
            log("configure \(key) failed: \(error)")
        }
    }

    /// Deliver a host-view / tap event back into the running feature by node id.
    public func send(id: String, value: String) {
        guard let runtime, !isShutDown else { return }
        #if canImport(os)
        eventsSent += 1
        let signpost = IsomerTypingSignposts.begin("guest-event", "event", eventsSent)
        defer { IsomerTypingSignposts.end("guest-event", signpost) }
        #endif
        do {
            let idBytes = Array(id.utf8), valBytes = Array(value.utf8)
            let idPtr = try runtime.call("iso_hot_alloc", [.i32(Int32(idBytes.count))])?.u32Value ?? 0
            runtime.writeBytes(idPtr, idBytes)
            let valPtr = try runtime.call("iso_hot_alloc", [.i32(Int32(valBytes.count))])?.u32Value ?? 0
            runtime.writeBytes(valPtr, valBytes)
            _ = try runtime.call("iso_hot_event", [
                .i32(Int32(bitPattern: idPtr)), .i32(Int32(idBytes.count)),
                .i32(Int32(bitPattern: valPtr)), .i32(Int32(valBytes.count)),
            ])
            _ = try? runtime.call("iso_hot_free", [.i32(Int32(bitPattern: idPtr))])
            _ = try? runtime.call("iso_hot_free", [.i32(Int32(bitPattern: valPtr))])
            requestRender()
        } catch {
            log("event failed: \(error)")
        }
    }

    /// Note the new size and re-run the feature — DEBOUNCED. Under the
    /// SwiftUIRenderer the serialized tree is the semantic hierarchy and the host
    /// lays it out natively, so a live resize just needs a native re-layout of
    /// the already-decoded tree. Re-running the interpreter every resize frame
    /// stutters, so only do it once the resize settles — which matters solely
    /// for features whose tree reads the size (GeometryReader).
    ///
    /// Before a feature starts, the size is only noted: `iso_hot_start` takes
    /// it. A change across the compact/regular width (700 points, where the
    /// size classes change and the feature lays itself out anew) applies at
    /// once rather than after the debounce, which would show the other
    /// layout for a beat.
    public func resize(width: Double, height: Double) {
        guard width != self.width || height != self.height else { return }
        let crossesSizeClass = (width < 700) != (self.width < 700)
        self.width = width
        self.height = height
        resizeWork?.cancel()
        guard runtime != nil else { return }
        if crossesSizeClass {
            applyResize()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.applyResize() }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// The host's system appearance; forwards to the feature's
    /// `iso_hot_set_color_scheme` export and pumps a frame so the adaptive
    /// palette re-renders. A reactor without the export (a drifted
    /// hand-copied bridge, or a bundle predating it) stays light — warn
    /// once, because the silent no-op looks identical to "dark mode is
    /// broken". Compiling the framework's HotBridge.swift into the reactor
    /// makes the export impossible to lose.
    public func setColorScheme(dark: Bool) {
        lastDark = dark
        guard let runtime else { return }
        do {
            _ = try runtime.call("iso_hot_set_color_scheme", [.i32(dark ? 1 : 0)])
        } catch {
            if !warnedMissingColorScheme {
                warnedMissingColorScheme = true
                print("[iso] reactor exports no iso_hot_set_color_scheme — "
                    + "appearance stays light (compile the framework HotBridge.swift): \(error)")
            }
        }
        requestRender()
    }

    private var warnedMissingColorScheme = false

    /// The host's scene phase (0 = active, 1 = inactive, 2 = background);
    /// forwards to the feature's `iso_hot_set_scene_phase` export, so the
    /// guest's `@Environment(\.scenePhase)` follows the app's, and pumps a
    /// frame for the `.onChange(of:)` it runs. A reactor built before the
    /// export stays active, as such reactors always did.
    public func setScenePhase(_ phase: Int32) {
        guard phase != lastScenePhase else { return }
        lastScenePhase = phase
        guard let runtime else { return }
        _ = try? runtime.call("iso_hot_set_scene_phase", [.i32(phase)])
        requestRender()
    }

    private var lastScenePhase: Int32 = 0

    /// The host's size classes (each 0 = none, 1 = compact, 2 = regular);
    /// forwards to the feature's `iso_hot_set_size_classes` export, so the
    /// guest's `horizontalSizeClass` is the system's (an iPhone's stays
    /// compact in landscape, wider than the guest's own 700-point rule) and
    /// pumps a frame. A reactor built before the export keeps the rule.
    public func setSizeClasses(horizontal: Int32, vertical: Int32) {
        guard lastSizeClasses.map({ $0.horizontal != horizontal || $0.vertical != vertical }) ?? true else { return }
        lastSizeClasses = (horizontal, vertical)
        guard let runtime else { return }
        _ = try? runtime.call("iso_hot_set_size_classes", [.i32(horizontal), .i32(vertical)])
        requestRender()
    }

    private var lastSizeClasses: (horizontal: Int32, vertical: Int32)?
    /// The most recent host appearance, replayed to each freshly loaded
    /// bundle (the initial report usually precedes the first load).
    private var lastDark: Bool?

    private func applyResize() {
        guard let runtime else { return }
        _ = try? runtime.call("iso_hot_resize", [.f64(width), .f64(height)])
        requestRender()
    }

    private func setStatus(_ value: String) {
        status = value
        onStatus?(value)
    }

    private func deliverTree(_ bytes: [UInt8]) {
        onTree?(bytes)
    }

    /// Request a frame, coalescing bursts to a single pump. The host owns WHEN
    /// (`onScheduleRender`) so the pump lands on the right main-thread loop —
    /// Apple's runloop-drained main queue, or Android's main Looper.
    private func requestRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        if let onScheduleRender {
            onScheduleRender()
        } else {
            // Apple default: the libdispatch main queue (the runloop drains it).
            DispatchQueue.main.async { [weak self] in self?.pumpRender() }
        }
    }

    /// Answer an async service call back into the running feature: stages
    /// `payload` in guest memory, calls the app's `<ffiModulePrefix><export>`
    /// export as `(requestID, ok, ptr, len)` — the completion convention the
    /// app-services examples use (`isoFetchComplete`) — frees the staging
    /// buffer, and schedules a frame so the completion's state change renders.
    /// A no-op before `load(...)` or without an `ffiModulePrefix`.
    public func complete(export: String, requestID: Int32, ok: Bool, payload: String) {
        // During a graceful shutdown completions still land (a service answer
        // is what lets an awaiting task unwind); after teardown `runtime` is nil.
        guard let runtime, let prefix = ffiModulePrefix else { return }
        let bytes = Array(payload.utf8)
        do {
            var staged: Int32 = 0
            if !bytes.isEmpty {
                guard case .i32(let allocated)? = try runtime.call(
                    "iso_hot_alloc", [.i32(Int32(bytes.count))])
                else { return }
                staged = allocated
                runtime.writeBytes(UInt32(bitPattern: allocated), bytes)
            }
            _ = try runtime.call(
                prefix + export,
                [.i32(requestID), .i32(ok ? 1 : 0), .i32(staged), .i32(Int32(bytes.count))])
            if staged != 0 { _ = try? runtime.call("iso_hot_free", [.i32(staged)]) }
        } catch {
            log("complete(\(export)) failed: \(error)")
        }
        requestRender()
    }

    /// Schedule a frame (e.g. after delivering host state to the guest outside
    /// an event or completion, which schedule their own).
    public func render() {
        requestRender()
    }

    // MARK: Shutdown

    /// How a shutdown ended.
    public enum ShutdownOutcome: Equatable {
        /// Every view task unwound (or the reactor was never loaded).
        case graceful
        /// The deadline passed with tasks still pending; the instance was
        /// torn down regardless.
        case forced(pendingTasks: Int)
        /// The reactor predates `iso_hot_shutdown`: torn down immediately.
        case unsupported
    }

    /// True once a shutdown began: later events, renders and completions
    /// are ignored (the guest is unwinding or gone).
    public private(set) var isShutDown = false

    /// Graceful shutdown with a deadline: tells the guest to cancel its view
    /// tasks (`iso_hot_shutdown`), then keeps draining the guest's job queue
    /// — which is where cancelled tasks actually run to completion — until
    /// the guest reports no pending tasks or `timeout` elapses, and finally
    /// releases the engine instance either way. A task awaiting a service
    /// that never answers cannot unwind; that is the forced case.
    public func shutdown(timeout: TimeInterval = 1) async -> ShutdownOutcome {
        guard let runtime, !isShutDown else { return .graceful }
        isShutDown = true
        resizeWork?.cancel()
        do {
            _ = try runtime.call("iso_hot_shutdown", [])
        } catch {
            log("shutdown: iso_hot_shutdown unavailable or failed (\(error)); tearing down immediately")
            forceShutdown()
            return .unsupported
        }
        let deadline = Date().addingTimeInterval(timeout)
        var pending = Int.max
        repeat {
            runtime.pumpGuestJobs()
            pending = Int((try? runtime.call("iso_hot_pending_tasks", [])?.i32Value) ?? 0)
            if pending == 0 { break }
            try? await Task.sleep(nanoseconds: 8_000_000)
        } while Date() < deadline
        self.runtime = nil
        if pending == 0 {
            log("shutdown: graceful")
            return .graceful
        }
        log("shutdown: forced with \(pending) task(s) pending")
        return .forced(pendingTasks: pending)
    }

    /// Immediate teardown: the engine instance is released now; guest tasks
    /// simply cease to exist.
    public func forceShutdown() {
        isShutDown = true
        resizeWork?.cancel()
        runtime = nil
    }

    /// The events sent, and those a pumped frame has been the first to
    /// render since (the typing signposts' numbering).
    private var eventsSent = 0
    private var eventsRendered = 0

    /// Render one frame NOW (on the main thread). The host calls this when the
    /// `onScheduleRender` callback it was handed comes due.
    public func pumpRender() {
        renderScheduled = false
        guard !isShutDown else { return }
        #if canImport(os)
        // "events=a-b": the events this frame is the first to render (none:
        // "events=0").
        let signpost = eventsRendered < eventsSent
            ? IsomerTypingSignposts.begin("guest-render", "events", eventsRendered + 1, eventsSent)
            : IsomerTypingSignposts.begin("guest-render", "events", 0)
        eventsRendered = eventsSent
        runtime?.renderPending()
        IsomerTypingSignposts.end("guest-render", signpost)
        #else
        runtime?.renderPending()
        #endif
    }
}
