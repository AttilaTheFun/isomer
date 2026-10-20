// Native Linux host bridge.
//
// Implements `HostBridge` by calling the flat C renderer API (`renderer.h`,
// imported through `linux_bridge.h`), and owns the SDL2 window + event/render
// loop. Like the native Windows host — and unlike wasm (JavaScript drives the
// loop) or Android (the JVM does) — the Linux app is a real ELF that owns its
// process, so the entry point itself creates the window and runs the loop.

import Foundation
package import IsomerSwiftUI

func withUTF8Pointer(_ string: String, _ body: (UnsafePointer<CChar>?, Int32) -> Void) {
    var copy = string
    copy.withUTF8 { buffer in
        buffer.withMemoryRebound(to: CChar.self) { rebound in
            body(rebound.baseAddress, Int32(rebound.count))
        }
    }
}

struct LinuxHostBridge: HostBridge {
    func measureText(_ text: String, fontSize: Double, weight: Int, wrapWidth: Double?) -> CGSize {
        var width: Double = 0
        var height: Double = 0
        withUTF8Pointer(text) { ptr, length in
            iso_measure_text(ptr, length, fontSize, Int32(weight), wrapWidth ?? -1, &width, &height)
        }
        return CGSize(width: width, height: height)
    }

    func imageInfo(_ source: String, isRemote: Bool) -> ImageStatus {
        var width: Double = 0
        var height: Double = 0
        var status: Int32 = 0
        withUTF8Pointer(source) { ptr, length in
            status = iso_image_info(ptr, length, isRemote ? 1 : 0, &width, &height)
        }
        switch status {
        case 1: return .ready(CGSize(width: width, height: height))
        case 2: return .failed
        default: return .loading
        }
    }

    // Drawing is SwiftGPURenderer's job — it wraps this bridge, draws every
    // pixel through swift_gpu's GL backend, and only calls the services half.
    // The HostBridge drawing methods default to no-ops in the core, so this
    // bridge no longer implements them. (The C renderer keeps its drawQuad
    // vocabulary only for the native-control cards and popups it draws itself.)

    // The SwiftGPU renderer's raster service: text via SDL2_ttf, gradients
    // and shadows on the CPU, images from the retained stb decodes —
    // [w u32 LE][h u32 LE][premultiplied RGBA], empty when unavailable.
    func rasterize(_ spec: String) -> [UInt8] {
        var result: [UInt8] = []
        withUTF8Pointer(spec) { ptr, length in
            var payloadLength: Int32 = 0
            guard let payload = iso_rasterize(ptr, length, &payloadLength),
                  payloadLength > 0 else { return }
            result = Array(UnsafeBufferPointer(start: payload, count: Int(payloadLength)))
        }
        return result
    }

    // The nav bar and tab bar are drawn into the display list; the host views
    // needing real widgets (Picker/Menu/DatePicker/WebView) are reconciled
    // through the structured hooks below, which the renderer draws into the GL
    // frame and hit-tests (see renderer.c).
    func syncHostViews(_ viewsJSON: String) {}

    func beginHostViewSync() { iso_host_sync_begin() }

    func syncWebView(id: String, url: String, frame: CGRect) {
        withUTF8Pointer(id) { idPtr, idLen in
            withUTF8Pointer(url) { urlPtr, urlLen in
                iso_webview_sync(
                    idPtr, idLen, urlPtr, urlLen,
                    frame.minX, frame.minY, frame.width, frame.height)
            }
        }
    }

    func syncNativeControl(
        id: String, kind: String, value: String, options: [String], frame: CGRect
    ) {
        let joined = options.joined(separator: "\n")
        withUTF8Pointer(id) { idPtr, idLen in
            withUTF8Pointer(kind) { kindPtr, kindLen in
                withUTF8Pointer(value) { valPtr, valLen in
                    withUTF8Pointer(joined) { optPtr, optLen in
                        iso_control_sync(
                            idPtr, idLen, kindPtr, kindLen, valPtr, valLen, optPtr, optLen,
                            frame.minX, frame.minY, frame.width, frame.height)
                    }
                }
            }
        }
    }

    func endHostViewSync() { iso_host_sync_end() }

    func beginTextInput(_ text: String, in rect: CGRect, fontSize: Double) {
        withUTF8Pointer(text) { ptr, length in
            iso_begin_text_input(ptr, length)
        }
    }

    func endTextInput() {
        iso_end_text_input()
    }

    // Render on demand: the runtime calls this when a frame is needed (input,
    // an async load completing, or an animation in flight). The loop renders
    // only when this flag is set, so an idle window uses ~no CPU.
    func scheduleRender() { linuxRenderScheduled = true }

    func now() -> Double { iso_bridge_epoch_millis() / 1000.0 }

    func fetch(_ url: String, completion: @escaping (String?) -> Void) {
        let id = linuxNextFetchID
        linuxNextFetchID += 1
        linuxFetchCompletions[id] = completion
        withUTF8Pointer(url) { ptr, length in
            iso_fetch(id, ptr, length)
        }
    }

    func log(_ message: String) {
        withUTF8Pointer(message) { ptr, length in
            iso_bridge_log(ptr, length)
        }
    }
}

// MARK: - Render scheduling

// Set by `scheduleRender()` (and the initial frame); the loop renders only when
// it is set, then clears it. An in-flight animation keeps it set because the
// runtime re-calls `scheduleRender()` from each frame while animating.
nonisolated(unsafe) var linuxRenderScheduled = true

// MARK: - Async fetch bookkeeping

nonisolated(unsafe) var linuxNextFetchID: Int32 = 1
nonisolated(unsafe) var linuxFetchCompletions: [Int32: (String?) -> Void] = [:]

func linuxFetchComplete(_ id: Int32, _ ok: Int32, _ body: UnsafePointer<CChar>?, _ len: Int32) {
    guard let completion = linuxFetchCompletions.removeValue(forKey: id) else { return }
    if ok != 0, let body, len > 0 {
        let text = body.withMemoryRebound(to: UInt8.self, capacity: Int(len)) { p in
            String(decoding: UnsafeBufferPointer(start: p, count: Int(len)), as: UTF8.self)
        }
        completion(text)
    } else if ok != 0 {
        completion("")
    } else {
        completion(nil)
    }
    Runtime.shared.setNeedsRender()
}

// MARK: - Text input callbacks

func linuxTextChanged(_ utf8: UnsafePointer<CChar>?, _ len: Int32) {
    let text: String
    if let utf8, len > 0 {
        text = utf8.withMemoryRebound(to: UInt8.self, capacity: Int(len)) { p in
            String(decoding: UnsafeBufferPointer(start: p, count: Int(len)), as: UTF8.self)
        }
    } else {
        text = ""
    }
    Runtime.shared.textChanged(text)
}

func linuxTextSubmit() {
    Runtime.shared.textSubmitted()
}

// MARK: - Native control change callback

func linuxControlChanged(
    _ id: UnsafePointer<CChar>?, _ idLen: Int32,
    _ value: UnsafePointer<CChar>?, _ valueLen: Int32
) {
    func decode(_ ptr: UnsafePointer<CChar>?, _ len: Int32) -> String {
        guard let ptr, len > 0 else { return "" }
        return ptr.withMemoryRebound(to: UInt8.self, capacity: Int(len)) { p in
            String(decoding: UnsafeBufferPointer(start: p, count: Int(len)), as: UTF8.self)
        }
    }
    // The runtime asks for the render the event needs.
    Runtime.shared.hostViewEvent(id: decode(id, idLen), value: decode(value, valueLen))
}

#if canImport(SwiftGPU)
import SwiftGPU

/// The SwiftGPU surface for Linux: swift_gpu's GL device over the host's
/// SDL2 window and core-3.3 context (created in iso_window_create; current
/// on the main thread for the app's whole life). The host presents
/// (SDL_GL_SwapWindow inside iso_end_frame, which also evicts stale text
/// textures) after the pass closes.
final class GLRendererSurface: SwiftGPURendererSurface {
    let gpuDevice = GLGPUDevice()
    var device: GPUDevice { gpuDevice }
    var displayScale: Double { iso_window_scale() }

    func beginFrame(clear: GPUColor, width: Double, height: Double) -> GPURenderPass? {
        // Query the drawable each frame: resizes need no explicit hook.
        var widthPx: Double = 0
        var heightPx: Double = 0
        iso_window_size_px(&widthPx, &heightPx)
        return gpuDevice.beginFrame(widthPx: Int(widthPx), heightPx: Int(heightPx), clear: clear)
    }

    func endFrame() {
        gpuDevice.endFrame()
        iso_end_frame()  // text-cache eviction + SDL_GL_SwapWindow
    }
}
#endif

/// The runtime host: the self-drawing SwiftGPURenderer over the GL backend
/// wrapping the services bridge. SwiftGPU is the only self-drawing renderer;
/// linking swift_gpu (OpenGL) for Linux is required.
func linuxMakeHost() -> HostBridge {
    #if canImport(SwiftGPU)
    #if canImport(SwiftMap)
    Renderer.hostRendersMaps = true  // `Map` draws real SwiftMap tiles
    #endif
    let renderer = SwiftGPURenderer(services: LinuxHostBridge(), surface: GLRendererSurface())
    Renderer.bind(renderer)
    return renderer
    #else
    #error("HostDrawnRenderer has been removed; SwiftGPU is now the only self-drawing renderer. Link swift_gpu (OpenGL) for Linux — see docs/renderer_layers.md")
    #endif
}

/// Owns the native window and the render loop. `@main` on Linux calls
/// `LinuxApp.run()` after installing the app (see `App.main()`).
enum LinuxApp {
    static func run() {
        iso_set_pointer_callback { kind, x, y in
            Runtime.shared.pointerEvent(kind: Int(kind), x: x, y: y)
        }
        iso_set_wheel_callback { x, y, dx, dy in
            Runtime.shared.wheelEvent(x: x, y: y, deltaX: dx, deltaY: dy)
        }
        iso_set_resize_callback { width, height in
            // The host loop runs on the main thread, where views live: say so to
            // the runtime, which is main-actor isolated as SwiftUI is.
            MainActor.assumeIsolated { Runtime.shared.resize(width: width, height: height) }
        }
        iso_set_fetch_callback(linuxFetchComplete)
        iso_set_text_changed_callback(linuxTextChanged)
        iso_set_text_submit_callback(linuxTextSubmit)
        iso_set_control_changed_callback(linuxControlChanged)

        let ok = "Isomer".withCString { titlePtr in
            iso_window_create(1100, 720, titlePtr)
        }
        guard ok != 0 else {
            iso_bridge_log("failed to create window", 23)
            return
        }

        var width: Double = 0
        var height: Double = 0
        iso_window_size(&width, &height)

        MainActor.assumeIsolated { Runtime.shared.start(host: linuxMakeHost(), width: width, height: height) }
        while true {
            // While a render is pending (animation / fresh input) don't block,
            // so animations run at the full frame rate; otherwise sleep until an
            // event or a short timeout (to pick up async network completions),
            // so an idle window costs ~no CPU.
            let timeout: Int32 = linuxRenderScheduled ? 0 : 32
            if iso_pump_events(timeout) == 0 { break }

            isoRunMainQueue()
            let fetched = iso_drain_fetches()
            let imaged = iso_drain_images()
            if fetched > 0 || imaged > 0 { linuxRenderScheduled = true }
            DesktopBench.shared?.tick()
            // Host widgets (popups, slider drag) request frames out of band.
            if iso_take_render_request() != 0 { linuxRenderScheduled = true }

            if linuxRenderScheduled {
                linuxRenderScheduled = false
                MainActor.assumeIsolated { Runtime.shared.renderFrame() }
                DesktopBench.shared?.framePresented()
                iso_frame_wait()  // cap continuous (animating) frames to ~60 fps
            }
        }
    }
}

/// Runs the main queue's pending work — main-actor jobs (a `.task`, an
/// `await` coming back from the network) are dispatched there, and this
/// host's loop is the main thread: without a turn of the run loop here they
/// never ran, and an app's async work stayed where it started.
@inline(__always)
func isoRunMainQueue() {
    _ = RunLoop.main.run(mode: .default, before: Date())
}
