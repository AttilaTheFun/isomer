// The Apple binding of the cross-platform wasm-host runtime: a thin
// `ObservableObject` over `WasmFeatureRuntime` (//shared/wasm_host) so SwiftUI's
// `WasmView` observes the emitted tree with `@Published`. All the actual wasm
// work — running the reactor under the pluggable `WasmRuntime` engine (WasmKit
// by default), wiring the swift_ffi dependency DI, pumping `iso_hot` frames —
// lives in the shared core; this only republishes its callbacks as observable
// state.
//
// `WasmFeatureHost`, `BundleProvider`, `WasmServiceBundle`, `AppBundleProvider`,
// and the `WasmRuntime` engine protocol are re-exported from the shared module,
// so a host that imports `IsomerWasmView` sees the whole surface unchanged.

import Foundation
import os
import SwiftFFIWasmHost
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import IsomerTree
import IsomerURLSessionNetwork
import IsomerWasmKitRuntime
@_exported import IsomerWasmHost

@MainActor
public final class WasmViewModel: ObservableObject {
    /// Benchmark hook (the iOS wasm cell; see apple/libraries/bench): the
    /// most recently created model, so the harness can inject tap events.
    public private(set) nonisolated(unsafe) static weak var benchShared: WasmViewModel?

    /// The retained render tree, or nil before the first frame. Each `on_tree`
    /// buffer is a tree.fbs `Patch` — the only wire format — applied in arrival
    /// order (never coalesced: a tap emits press + un-press patches; dropping
    /// one desyncs the retained tree).
    @Published public private(set) var tree: PatchedNode?
    /// The raw patches, for a renderer that keeps its own retained tree
    /// (the GPU tree view); `onPatchReset` fires when a reload empties it.
    /// Patches that arrive before a consumer attaches (the first full tree
    /// lands when the bundle loads, before the UIView exists) are kept and
    /// replayed to it, since every later patch is a delta against them.
    public var onPatch: (([UInt8]) -> Void)? {
        didSet {
            guard let onPatch else { return }
            let buffered = patchBacklog
            patchBacklog = []
            for bytes in buffered { onPatch(bytes) }
        }
    }
    public var onPatchReset: (() -> Void)?
    private var patchBacklog: [[UInt8]] = []
    /// Set before the first load when the view draws with the GPU renderer:
    /// the reactor then emits drawn navigation chrome (`iso_hot_configure`).
    public var drawnNavigation: Bool {
        get { core.drawnNavigation }
        set { core.drawnNavigation = newValue }
    }
    /// Human-readable load/run status for a host's status line.
    @Published public private(set) var status = "Not loaded"
    /// Bumped each reload so SwiftUI rebuilds the tree view cleanly.
    @Published public private(set) var generation = 0

    /// The app's swift_ffi module prefix + dependency table, injected into the
    /// running feature's `dependencies` dictionary. Set before `load(...)`;
    /// build entries with the app's generated `Dependencies` builders.
    /// Foundation's networking (URLSession, IsomerURLSessionNetwork) goes in
    /// beneath them under `isomerHTTP` and `isomerWebSocket`: an app's entry
    /// under either key replaces it.
    public var ffiModulePrefix: String? {
        get { core.ffiModulePrefix }
        set { core.ffiModulePrefix = newValue }
    }
    public var dependencies: [String: SwiftFFIDependency] = [:]

    /// The live engine behind the running feature — the seam dependency
    /// implementations use to call feature exports back (async completions).
    public var engineRuntime: WasmRuntime? { core.engineRuntime }

    /// Every runtime log line (guest `print`/`Bridge.log` output arrives as
    /// "[wasm] …", load/reload phases and failures as themselves) — for hosts
    /// that surface a running feature's logs (the Playground's agent tools).
    public var onLog: ((String) -> Void)? {
        get { logRelay.handler }
        set { logRelay.handler = newValue }
    }

    /// The log closure is handed to the runtime before `self` is fully
    /// initialized, so it goes through this relay rather than capturing self.
    private final class LogRelay { var handler: ((String) -> Void)? }
    private let logRelay = LogRelay()

    /// The guest's home (its Documents, Application Support, Caches and
    /// UserDefaults) and the bundle identifier it is told, for the runtimes
    /// made after they are set: the app's own container and identifier when
    /// nil. A host that runs several apps (the Playground's projects) gives
    /// each its own. The directory is made when missing.
    public var guestHomeDirectory: String? {
        get { home.directory }
        set { home.directory = newValue }
    }
    public var guestBundleIdentifier: String? {
        get { home.bundleIdentifier }
        set { home.bundleIdentifier = newValue }
    }
    private final class HomeRelay { var directory: String?; var bundleIdentifier: String? }
    private let home = HomeRelay()

    /// The small assets shipped with the running bundle, keyed by relative path.
    public var assets: [String: Data] { core.assets }

    private let core: WasmFeatureRuntime

    /// The engine is injected as a factory (bundle bytes → a fresh
    /// `WasmRuntime`), defaulting to the registry: a host that wants to pick
    /// or configure the engine per feature passes its own.
    public init(runtime: @escaping @MainActor ([UInt8]) -> any WasmRuntime = { WasmRuntimeRegistry.make(for: $0) }) {
        // The Apple host's default engine: WasmKit, unless the app registered
        // its own (WasmRuntimeRegistry.register { ... }) before the first
        // feature launches. The engine seam is //shared/wasm_host's
        // WasmRuntime protocol; the core is engine-free.
        // The guest's home is the app's own container, as when the same app
        // runs compiled: its Documents, Application Support, Caches and
        // UserDefaults are the app's.
        WasmRuntimeRegistry.registerDefault {
            let runtime = WasmKitRuntime()
            runtime.homeDirectory = NSHomeDirectory()
            runtime.bundleIdentifier = Bundle.main.bundleIdentifier
            return runtime
        }
        // What a person picks goes where the guest reads it: the host maps
        // a folder of the temporary directory as the guest's /tmp.
        IsomerPickedFiles.folder = (
            FileManager.default.temporaryDirectory.appendingPathComponent("isomer-guest/picked", isDirectory: true),
            "/tmp/picked")
        let logRelay = self.logRelay
        let home = self.home
        core = WasmFeatureRuntime(runtime: { bytes in
            let made = runtime(bytes)
            if let directory = home.directory, let engine = made as? WasmKitRuntime {
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                engine.homeDirectory = directory
                engine.bundleIdentifier = home.bundleIdentifier ?? engine.bundleIdentifier
            }
            return made
        }, log: { line in
            NSLog("[wasm-view] %@", line)
            logRelay.handler?(line)
        })
        // The platform channel, as the system's: the guest's
        // `Clipboard.string` is the system pasteboard (a read is the
        // system's, with its paste prompt, as UIKit's is), a URL opens in the
        // system's way.
        // A frame a text field's edit asks for renders on the run loop's next
        // turn, after this turn's Core Animation commit: the text the person
        // typed (the field's own) is drawn first, and the guest's frame
        // follows in the commit after (a turn later, coalescing the edits
        // that came meanwhile). Any other frame renders as before, from a
        // main-queue block in the same turn.
        let core = self.core
        core.onScheduleRender = { [weak core] in
            if TextEditScope.active {
                Self.afterCommit { core?.pumpRender() }
            } else {
                DispatchQueue.main.async { core?.pumpRender() }
            }
        }
        core.onPlatformCommand = { key, value in
            switch key {
            case "copy":
                #if canImport(UIKit)
                UIPasteboard.general.string = value
                #elseif canImport(AppKit)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                #endif
            case "openURL":
                guard let url = URL(string: value) else { return }
                #if canImport(UIKit)
                UIApplication.shared.open(url)
                #elseif canImport(AppKit)
                NSWorkspace.shared.open(url)
                #endif
            case "haptic":
                GuestHaptics.play(value)
            default:
                break
            }
        }
        core.hostValue = { key in
            // "env:<NAME>": the app's environment variable, for the guest's
            // debug switches (ISO_FRAME_LOG).
            if key.hasPrefix("env:") { return ProcessInfo.processInfo.environment[String(key.dropFirst(4))] }
            guard key == "pasteboard" else { return nil }
            #if canImport(UIKit)
            return UIPasteboard.general.string
            #elseif canImport(AppKit)
            return NSPasteboard.general.string(forType: .string)
            #else
            return nil
            #endif
        }
        core.onTree = { [weak self] bytes in
            guard let self else { return }
            if let onPatch = self.onPatch { onPatch(bytes) } else { self.patchBacklog.append(bytes) }
            self.patchesApplied += 1
            let signpost = IsomerTypingSignposts.begin("patch-apply", "frame", self.patchesApplied)
            self.tree = FlatPatchTree.apply(patch: bytes, to: self.tree)
            IsomerTypingSignposts.end("patch-apply", signpost)
            TypingCommits.shared.tree(self.patchesApplied)
            // Headless-verification hook: ISO_DUMP_TREE=<path> keeps a
            // structural dump of the latest retained tree at <path>.
            if let path = ProcessInfo.processInfo.environment["ISO_DUMP_TREE"],
               let tree = self.tree {
                try? tree.structureDump().write(
                    toFile: path, atomically: true, encoding: .utf8)
            }
        }
        core.onStatus = { [weak self] status in
            // Mirrored to the log so headless runs (CI, benches) can follow
            // load/reload transitions without a window.
            NSLog("[wasm-view] status: %@", status)
            self?.status = status
        }
        core.onReload = { [weak self] in
            guard let self else { return }
            // The fresh reactor's encoder starts empty: drop the retained tree
            // so its first patch (a full tree at "n") rebuilds from scratch.
            self.tree = nil
            self.patchBacklog = []
            self.onPatchReset?()
            self.generation += 1
        }
            WasmViewModel.benchShared = self
    }

    /// The patches applied (the typing signposts' frame numbers, as the
    /// runtime's tree-delivered); IsomerTree's TypingCommits stamps the
    /// `swiftui-commit` that draws them.
    private var patchesApplied = 0

    /// `work` on the main queue once this run-loop turn has committed (an
    /// observer ordered after Core Animation's commit observer, 2,000,000,
    /// posts it; the post wakes the loop for the next turn).
    private static func afterCommit(_ work: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 2_600_000
        ) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated(work) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    deinit {
        // The engine instance goes with the model (see the runtimes' deinit).
        NSLog("[wasm-view] model released")
    }

    public func load(bundle: WasmServiceBundle) {
        // Each reactor gets network hosts of its own (a reload's sockets go
        // with the reactor that opened them).
        core.dependencies = isomerNetworkDependencies().merging(dependencies) { _, app in app }
        core.load(bundle: bundle)
    }

    /// Graceful shutdown with a deadline, then teardown either way — see
    /// `WasmFeatureRuntime.shutdown`. Call before releasing the view so the
    /// feature's tasks can unwind; releasing without it is the forced path.
    @discardableResult
    public func shutdown(timeout: TimeInterval = 1) async -> WasmFeatureRuntime.ShutdownOutcome {
        let outcome = await core.shutdown(timeout: timeout)
        tree = nil
        return outcome
    }

    /// Immediate teardown of the engine instance.
    public func forceShutdown() {
        core.forceShutdown()
        tree = nil
    }
    public func send(id: String, value: String) { core.send(id: id, value: value) }

    /// Answer an async service call back into the feature (stage payload,
    /// call `<ffiModulePrefix><export>(requestID, ok, ptr, len)`, re-render) —
    /// see `WasmFeatureRuntime.complete`.
    public func complete(export: String, requestID: Int32, ok: Bool, payload: String) {
        core.complete(export: export, requestID: requestID, ok: ok, payload: payload)
    }

    /// Schedule a frame after delivering host state outside an event.
    public func render() { core.render() }

    /// The host's system appearance (see `WasmFeatureRuntime.setColorScheme`).
    public func setColorScheme(dark: Bool) { core.setColorScheme(dark: dark) }
    /// The app's scene phase: 0 = active, 1 = inactive, 2 = background (see
    /// `WasmFeatureRuntime.setScenePhase`).
    public func setScenePhase(_ phase: Int32) { core.setScenePhase(phase) }
    /// The system's size classes: each 0 = none, 1 = compact, 2 = regular
    /// (see `WasmFeatureRuntime.setSizeClasses`).
    public func setSizeClasses(horizontal: Int32, vertical: Int32) { core.setSizeClasses(horizontal: horizontal, vertical: vertical) }
    public func resize(width: Double, height: Double) { core.resize(width: width, height: height) }
}
