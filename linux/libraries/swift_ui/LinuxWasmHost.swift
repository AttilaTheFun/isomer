// The Linux **wasm delivery cell**: the same shell as `LinuxApp` (SDL2 window +
// GL SwiftGPU renderer + on-demand loop), but the UI is not compiled into this
// binary — it runs as an `iso_hot` reactor on WasmKit, the Swift interpreter,
// through the same platform-free core every native host drives
// (`WasmFeatureRuntime` over `WasmKitRuntime`, //shared/wasm_host). Each
// frame the reactor serializes its `RenderNode` tree to `tree.fbs`; this host
// decodes it (`FlatTreeDecoder`) and draws it through the exact same
// `SwiftGPURenderer` the compiled cell uses. Input hit-tests the decoded tree;
// a tap echoes the node's id back into the reactor, which re-renders and
// pushes a fresh tree.
//
// This file is compiled ONLY into the `swift_ui_wasm` module (which adds the
// engine) so the compiled Linux app never links an interpreter. It reuses
// `LinuxHost.swift`'s bridge/surface/loop primitives (same module).

import Foundation
import IsomerWasmHost
import IsomerURLSessionNetwork
import IsomerWasmKitRuntime
import SwiftFFIWasmHost

#if canImport(SwiftGPU)
import SwiftGPU
#endif

/// `ISO_WASM_TRACE` in the environment: each frame the reactor hands up,
/// each scheduled render, and each tree drawn, printed.
private let wasmTrace = ProcessInfo.processInfo.environment["ISO_WASM_TRACE"] != nil

/// The one running wasm cell. Everything here lives on the loop's (main)
/// thread.
final class LinuxWasmCell {
    nonisolated(unsafe) static var shared: LinuxWasmCell?

    /// The running reactor (nil between a hot-reload's teardown and its
    /// replacement).
    var core: WasmFeatureRuntime?
    /// Decodes each `tree.fbs` push into a drawable `RenderNode`, routing every
    /// interactive node's events back into the reactor by id.
    let decoder: FlatTreeDecoder
    /// The most recently decoded tree, redrawn every scheduled frame.
    var latestTree: RenderNode?
    /// Frames the reactor handed up, pending application on the loop — in
    /// arrival order. A QUEUE, not a latest-wins slot: each buffer is a delta
    /// against the reactor's previous frame, so dropping an intermediate one
    /// (e.g. the press-highlight patch when down+up land in one pump) desyncs
    /// the retained tree and every later splice corrupts it.
    var pendingBytes: [[UInt8]] = []
    /// The reactor asked for a frame (`pumpRender` on the loop's next turn).
    var renderDue = false

    init() {
        decoder = FlatTreeDecoder(send: { id, value in
            MainActor.assumeIsolated { LinuxWasmCell.shared?.core?.send(id: id, value: value) }
        })
    }
}

// MARK: - Entry

/// The loop LinuxWasmApp (IsomerDesktopWasmHost, the public entry: this
/// module is `SwiftUI`, which has nothing of Isomer's own) runs. Owns the
/// native window and the render loop for the wasm cell. The app binary's
/// `@main` reads the reactor bytes and calls this.
///
/// `dependencies` are the platform services the reactor sees (built with a
/// generated `Dependencies` table, e.g. `nativePlatformDependencies`).
/// `nextReload`, when supplied (hot-reload enabled via `ISO_HOT_RELOAD_SERVER`),
/// is polled ~2×/sec and returns fresh reactor bytes when the server's build
/// counter bumps — the host then tears down the running reactor and swaps in a
/// new one live, so an edit on the server updates this app (and every other
/// connected client) at once.
package enum LinuxWasmLoop {
    package static func run(
        wasmBytes: [UInt8], dependencies: [String: SwiftFFIDependency] = [:],
        nextReload: (() -> [UInt8]?)? = nil
    ) {
        // Input → runtime. Pointer/wheel hit-test the decoded tree (its tap
        // regions are populated by `drawTree`); a hit fires the node's
        // synthesized `tapAction`, which echoes the id into the reactor.
        iso_set_pointer_callback { kind, x, y in
            Runtime.shared.pointerEvent(kind: Int(kind), x: x, y: y)
        }
        iso_set_wheel_callback { x, y, dx, dy in
            Runtime.shared.wheelEvent(x: x, y: y, deltaX: dx, deltaY: dy)
        }
        // A resize both updates the host layout size and tells the reactor, so
        // its size-dependent build (the split vs. tab shell) re-runs.
        iso_set_resize_callback { width, height in
            // The host loop runs on the main thread, where views live: say so to
            // the runtime, which is main-actor isolated as SwiftUI is.
            MainActor.assumeIsolated {
                Runtime.shared.resize(width: width, height: height)
                LinuxWasmCell.shared?.core?.resize(width: width, height: height)
            }
        }
        let ok = "Isomer (wasm)".withCString { iso_window_create(1100, 720, $0) }
        guard ok != 0 else {
            iso_bridge_log("failed to create window", 23)
            return
        }

        var width: Double = 0
        var height: Double = 0
        iso_window_size(&width, &height)

        let cell = LinuxWasmCell()
        LinuxWasmCell.shared = cell

        // Bind the self-drawing SwiftGPU host so `drawTree` has a renderer.
        // No native app is installed; `start`'s `renderFrame` is a clean no-op.
        MainActor.assumeIsolated { Runtime.shared.start(host: linuxMakeHost(), width: width, height: height) }

        // A reactor from bytes (the initial load and every hot-reload swap):
        // WasmKit under the shared core, whose frames come back here.
        func makeCore(_ bytes: [UInt8], width: Double, height: Double) -> WasmFeatureRuntime {
            MainActor.assumeIsolated {
                let core = WasmFeatureRuntime(runtime: { _ in WasmKitRuntime() }, log: { line in
                    withUTF8Pointer(line) { ptr, len in iso_bridge_log(ptr, len) }
                })
                core.ffiModulePrefix = "swift_ffi_platform_services_"
                // Foundation's networking (URLSession) beneath the host's
                // own, fresh for each reactor, as Apple's WasmView does.
                core.dependencies = isomerNetworkDependencies().merging(dependencies) { _, own in own }
                // This host draws the whole tree with SwiftGPU, navigation
                // chrome included (as Apple's WasmView does for its GPU
                // renderer).
                core.drawnNavigation = true
                core.onTree = { bytes in
                    if wasmTrace { print("[wasm-trace] tree \(bytes.count) bytes") }
                    cell.pendingBytes.append(bytes)
                    linuxRenderScheduled = true
                }
                core.onScheduleRender = {
                    if wasmTrace { print("[wasm-trace] render scheduled") }
                    cell.renderDue = true
                    linuxRenderScheduled = true
                }
                core.onStatus = { status in print("[wasm] \(status)") }
                core.resize(width: width, height: height)
                core.load(bundle: WasmServiceBundle(label: "reactor", wasm: bytes))
                return core
            }
        }

        // Starts the reactor: its first frame (the full tree) comes back
        // through `onTree`.
        cell.core = makeCore(wasmBytes, width: width, height: height)

        var lastPollMs = iso_bridge_epoch_millis()

        while true {
            let timeout: Int32 = linuxRenderScheduled ? 0 : 32
            if iso_pump_events(timeout) == 0 { break }

            _ = iso_drain_fetches()
            _ = iso_drain_images()
            // The guest's jobs (WasmKit posts them to the main queue) and the
            // core's debounced resize.
            isoRunMainQueue()
            if iso_take_render_request() != 0 { linuxRenderScheduled = true }

            // Hot reload: poll the server ~2×/sec; a build bump swaps the reactor.
            if let nextReload {
                let now = iso_bridge_epoch_millis()
                if now - lastPollMs > 500 {
                    lastPollMs = now
                    if let fresh = nextReload() {
                        MainActor.assumeIsolated { cell.core?.forceShutdown() }
                        cell.core = nil
                        cell.pendingBytes = []
                        // The fresh reactor's encoder starts empty: drop the
                        // retained tree so its first patch (a full tree at "n")
                        // rebuilds from scratch.
                        cell.latestTree = nil
                        cell.core = makeCore(fresh, width: Runtime.shared.width, height: Runtime.shared.height)
                        linuxRenderScheduled = true
                    }
                }
            }

            if cell.renderDue {
                cell.renderDue = false
                MainActor.assumeIsolated { cell.core?.pumpRender() }
            }

            DesktopBench.shared?.tick()
            if linuxRenderScheduled {
                linuxRenderScheduled = false
                if !cell.pendingBytes.isEmpty {
                    let queued = cell.pendingBytes
                    cell.pendingBytes = []
                    for bytes in queued {
                        cell.latestTree = cell.decoder.applyPatch(bytes: bytes, to: cell.latestTree)
                    }
                }
                if wasmTrace { print("[wasm-trace] draw: tree \(cell.latestTree == nil ? "none" : "decoded")") }
                if let tree = cell.latestTree {
                    MainActor.assumeIsolated { Renderer.current.render(tree: tree) }
                    DesktopBench.shared?.framePresented()
                    iso_frame_wait()  // cap continuous frames to ~60 fps
                }
            }
        }

        MainActor.assumeIsolated { cell.core?.forceShutdown() }
    }
}
