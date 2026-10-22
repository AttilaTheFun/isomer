// The Windows **wasm delivery cell**: the same shell as `WindowsApp` (Win32
// window + D3D11 SwiftGPU renderer + message loop), but the UI runs as an
// `iso_hot` reactor on WasmKit, the Swift interpreter, through the same
// platform-free core every native host drives (`WasmFeatureRuntime` over
// `WasmKitRuntime`, //shared/wasm_host) rather than compiled in. The reactor
// ships a `tree.fbs` Patch per frame — the only wire format — applied to the
// retained decoded tree (`FlatTreeDecoder.applyPatch`; the first patch
// carries the full tree), and the result draws through the same
// `SwiftGPURenderer` the compiled cell uses. Input hit-tests the decoded tree;
// a tap echoes the node id back into the reactor. The D3D11 peer of
// `LinuxWasmHost.swift`; compiled only into the `swift_ui_wasm` module so the
// compiled Windows app never links an interpreter. (WasmKit checks a
// reactor's memory accesses in software on Windows: no guard pages, so no
// threaded reactors.)

import Foundation
import IsomerWasmHost
import IsomerURLSessionNetwork
import IsomerWasmKitRuntime
import SwiftFFIWasmHost

#if canImport(SwiftGPU)
import SwiftGPU
#endif

/// The one running wasm cell. Everything here lives on the loop's (main)
/// thread.
final class WindowsWasmCell {
    nonisolated(unsafe) static var shared: WindowsWasmCell?

    /// The running reactor (nil between a hot-reload's teardown and its
    /// replacement).
    var core: WasmFeatureRuntime?
    let decoder: FlatTreeDecoder
    var latestTree: RenderNode?
    /// Frames not yet applied, in arrival order. A QUEUE, not a latest-wins
    /// slot: with diff-aware updates each buffer is a delta against the
    /// reactor's previous frame, so dropping an intermediate one (e.g. the
    /// press-highlight patch when down+up land in one pump) desyncs the
    /// retained tree and every later splice corrupts it.
    var pendingBytes: [[UInt8]] = []
    /// The reactor asked for a frame (`pumpRender` on the loop's next turn).
    var renderDue = false

    init() {
        decoder = FlatTreeDecoder(send: { id, value in
            MainActor.assumeIsolated { WindowsWasmCell.shared?.core?.send(id: id, value: value) }
        })
    }
}

/// Keeps the window painting during an interactive resize (the modal move/size
/// loop blocks the normal loop) — redraws the latest decoded tree.
func windowsWasmPaint() {
    guard let tree = WindowsWasmCell.shared?.latestTree else { return }
    MainActor.assumeIsolated {
        guard Runtime.shared.host != nil else { return }
        Renderer.current.render(tree: tree)
    }
}

/// Resize: refresh the D3D swapchain + host layout size, then tell the reactor
/// so its size-dependent build (split vs. tab shell) re-runs.
func windowsWasmResized(width: Double, height: Double) {
    #if canImport(SwiftGPU)
    windowsGPUSurface?.refreshSize()
    #endif
    // The host loop runs on the main thread, where views live: say so to
    // the runtime, which is main-actor isolated as SwiftUI is.
    MainActor.assumeIsolated {
        Runtime.shared.resize(width: width, height: height)
        WindowsWasmCell.shared?.core?.resize(width: width, height: height)
    }
}

// MARK: - Entry

/// The loop WindowsWasmApp (IsomerDesktopWasmHost, the public entry: this
/// module is `SwiftUI`, which has nothing of Isomer's own) runs. Owns the
/// native window and the render loop for the Windows wasm cell.
///
/// `dependencies` are the platform services the reactor sees. `nextReload`,
/// when supplied (hot-reload via `ISO_HOT_RELOAD_SERVER`), is polled ~2×/sec
/// and returns fresh reactor bytes on a server build bump; the host then
/// tears the reactor down and swaps in a new one live.
package enum WindowsWasmLoop {
    package static func run(
        wasmBytes: [UInt8], dependencies: [String: SwiftFFIDependency] = [:],
        nextReload: (() -> [UInt8]?)? = nil
    ) {
        iso_set_pointer_callback { kind, x, y in
            Runtime.shared.pointerEvent(kind: Int(kind), x: x, y: y)
        }
        iso_set_wheel_callback { x, y, dx, dy in
            Runtime.shared.wheelEvent(x: x, y: y, deltaX: dx, deltaY: dy)
        }
        iso_set_resize_callback { width, height in
            windowsWasmResized(width: width, height: height)
        }
        iso_set_paint_callback(windowsWasmPaint)
        "Isomer (wasm)".withCString { iso_window_create(1100, 720, $0) }

        var width: Double = 0
        var height: Double = 0
        iso_window_size(&width, &height)

        let cell = WindowsWasmCell()
        WindowsWasmCell.shared = cell

        // Bind the self-drawing SwiftGPU/D3D11 host; no native app is installed,
        // so `start`'s `renderFrame` is a clean no-op.
        MainActor.assumeIsolated { Runtime.shared.start(host: windowsMakeHost(), width: width, height: height) }

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
                #if canImport(SwiftMap)
                // And its maps (SwiftMap is linked: the host draws `map`
                // host views as the compiled app does).
                core.drawnMaps = true
                #endif
                core.onTree = { bytes in cell.pendingBytes.append(bytes) }
                core.onScheduleRender = { cell.renderDue = true }
                core.resize(width: width, height: height)
                core.load(bundle: WasmServiceBundle(label: "reactor", wasm: bytes))
                return core
            }
        }

        cell.core = makeCore(wasmBytes, width: width, height: height)

        var presentPaces = false
        #if canImport(SwiftGPU)
        presentPaces = windowsGPUSurface != nil
        #endif
        var lastPollMs = iso_bridge_epoch_millis()

        while iso_pump_events() != 0 {
            iso_drain_fetches()
            iso_drain_images()
            // The guest's jobs (WasmKit posts them to the main queue) and the
            // core's debounced resize.
            isoRunMainQueue()

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
                    }
                }
            }

            if cell.renderDue {
                cell.renderDue = false
                MainActor.assumeIsolated { cell.core?.pumpRender() }
            }

            if !cell.pendingBytes.isEmpty {
                let queued = cell.pendingBytes
                cell.pendingBytes = []
                for bytes in queued {
                    cell.latestTree = cell.decoder.applyPatch(bytes: bytes, to: cell.latestTree)
                }
            }
            DesktopBench.shared?.tick()
            if let tree = cell.latestTree {
                MainActor.assumeIsolated { Renderer.current.render(tree: tree) }
                DesktopBench.shared?.framePresented()
            }
            if !presentPaces { iso_frame_wait() }
        }

        MainActor.assumeIsolated { cell.core?.forceShutdown() }
    }
}
