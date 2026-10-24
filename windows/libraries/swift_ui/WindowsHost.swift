// Native Windows host bridge.
//
// Implements `HostBridge` by calling the flat C renderer API (`renderer.h`,
// imported as a Clang header), and owns the window + message loop. The window,
// event loop, and renderer are all native (Direct2D / Win32) — unlike wasm
// (JavaScript drives the loop) and Android (the JVM does) — so the Windows
// entry point itself runs the loop here.

import Foundation
import ImageIO
package import IsomerSwiftUI

func withUTF8Pointer(_ string: String, _ body: (UnsafePointer<CChar>?, Int32) -> Void) {
    var copy = string
    copy.withUTF8 { buffer in
        buffer.withMemoryRebound(to: CChar.self) { rebound in
            body(rebound.baseAddress, Int32(rebound.count))
        }
    }
}

struct WindowsHostBridge: HostBridge {
    func measureText(_ text: String, fontSize: Double, weight: Int, wrapWidth: Double?) -> CGSize {
        var width: Double = 0
        var height: Double = 0
        withUTF8Pointer(text) { ptr, length in
            iso_measure_text(ptr, length, fontSize, Int32(weight), wrapWidth ?? -1, &width, &height)
        }
        return CGSize(width: width, height: height)
    }

    /// A picture an app decoded through ImageIO, its bytes at its first draw.
    func registerImage(_ source: String, bytes: [UInt8]) {
        withUTF8Pointer(source) { ptr, length in
            bytes.withUnsafeBufferPointer { iso_register_image(ptr, length, $0.baseAddress, Int32($0.count)) }
        }
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
    // pixel through swift_gpu's D3D11 backend, and only calls the services half
    // below. The HostBridge drawing methods default to no-ops in the core, so
    // this bridge no longer implements them.

    // Nav bar and tab bar are drawn into the display list on Windows; the host
    // views that need real native widgets — WebView, Picker, Menu, DatePicker —
    // are reconciled through the structured hooks below into native child
    // windows (see renderer.cpp).
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
        // Option labels are newline-joined for the flat C boundary (labels are
        // short single-line text).
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
            iso_begin_text_input(
                ptr, length, rect.minX, rect.minY, rect.width, rect.height, fontSize)
        }
    }

    func endTextInput() {
        iso_end_text_input()
    }

    func setColorScheme(dark: Bool) {
        iso_set_color_scheme(dark ? 1 : 0)
    }

    func openURL(_ url: String) {
        withUTF8Pointer(url) { ptr, length in
            iso_bridge_open_url(ptr, length)
        }
    }

    // The SwiftGPU renderer's raster service: text via DirectWrite, gradients
    // via an offscreen D2D target, shadows via a CPU Gaussian, images via WIC
    // — [w u32 LE][h u32 LE][premultiplied RGBA], empty when unavailable.
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

    // The Windows host renders every loop iteration, so there is nothing to
    // schedule (a later refinement could render on demand from this signal).
    func scheduleRender() {}

    func now() -> Double { iso_bridge_epoch_millis() / 1000.0 }

    func fetch(_ url: String, completion: @escaping (String?) -> Void) {
        let id = windowsNextFetchID
        windowsNextFetchID += 1
        windowsFetchCompletions[id] = completion
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

// MARK: - Async fetch bookkeeping

// Completions are stored by request id and invoked when the C host delivers the
// response on the main thread (via `iso_drain_fetches` → `windowsFetchComplete`).
nonisolated(unsafe) var windowsNextFetchID: Int32 = 1
nonisolated(unsafe) var windowsFetchCompletions: [Int32: (String?) -> Void] = [:]

func windowsFetchComplete(_ id: Int32, _ ok: Int32, _ body: UnsafePointer<CChar>?, _ len: Int32) {
    guard let completion = windowsFetchCompletions.removeValue(forKey: id) else { return }
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

func windowsTextChanged(_ utf8: UnsafePointer<CChar>?, _ len: Int32) {
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

func windowsTextSubmit() {
    Runtime.shared.textSubmitted()
}

// MARK: - Synchronous paint (interactive resize)

// Invoked from WM_SIZE/WM_PAINT so the window keeps rendering during an
// interactive resize, when the modal move/size loop blocks the normal loop.
// Guarded until `start(host:)` has wired the host.
func windowsPaint() {
    guard Runtime.shared.host != nil else { return }
    // The host loop runs on the main thread, where views live: say so to
    // the runtime, which is main-actor isolated as SwiftUI is.
    MainActor.assumeIsolated { Runtime.shared.renderFrame() }
}

// MARK: - Native control change callback

// A native Picker/Menu/DatePicker reported a user edit; route it through the
// runtime's host-view event channel so the registered onChange updates the
// bound state, then request a redraw.
func windowsControlChanged(
    _ id: UnsafePointer<CChar>?, _ idLen: Int32,
    _ value: UnsafePointer<CChar>?, _ valueLen: Int32
) {
    func decode(_ ptr: UnsafePointer<CChar>?, _ len: Int32) -> String {
        guard let ptr, len > 0 else { return "" }
        return ptr.withMemoryRebound(to: UInt8.self, capacity: Int(len)) { p in
            String(decoding: UnsafeBufferPointer(start: p, count: Int(len)), as: UTF8.self)
        }
    }
    Runtime.shared.hostViewEvent(id: decode(id, idLen), value: decode(value, valueLen))
    Runtime.shared.setNeedsRender()
}

#if canImport(SwiftGPU)
import SwiftGPU

/// The SwiftGPU surface for Windows: swift_gpu's D3D11 device over the
/// host's HWND. The host owns the window and sizing; the backend owns the
/// swapchain (resized from the WM_SIZE callback below).
final class DirectXRendererSurface: SwiftGPURendererSurface {
    let gpuDevice: DirectXGPUDevice
    var device: GPUDevice { gpuDevice }
    var displayScale: Double { iso_window_scale() }

    init?() {
        var widthPx: Double = 0
        var heightPx: Double = 0
        iso_window_size_px(&widthPx, &heightPx)
        guard let hwnd = iso_window_hwnd(),
              let created = DirectXGPUDevice(
                  hwnd: hwnd, widthPx: Int(widthPx), heightPx: Int(heightPx))
        else { return nil }
        gpuDevice = created
    }

    func refreshSize() {
        var widthPx: Double = 0
        var heightPx: Double = 0
        iso_window_size_px(&widthPx, &heightPx)
        gpuDevice.resize(widthPx: Int(widthPx), heightPx: Int(heightPx))
    }

    func beginFrame(clear: GPUColor, width: Double, height: Double) -> GPURenderPass? {
        gpuDevice.beginFrame(clear: clear)
    }

    func endFrame() {
        gpuDevice.endFrame()  // Present(1, 0) — vsync paces the render loop
    }
}

nonisolated(unsafe) var windowsGPUSurface: DirectXRendererSurface?
#endif

/// The runtime host: the self-drawing SwiftGPURenderer over D3D11 wrapping
/// the services bridge. SwiftGPU is the only self-drawing renderer; a D3D11
/// device is required (there is no longer a Direct2D draw-list fallback).
func windowsMakeHost() -> HostBridge {
    #if canImport(SwiftGPU)
    guard let surface = DirectXRendererSurface() else {
        fatalError(
            "D3D11 surface unavailable and HostDrawnRenderer has been removed — "
            + "SwiftGPU is now the only self-drawing renderer on Windows. "
            + "See docs/renderer_layers.md")
    }
    #if canImport(SwiftMap)
    Renderer.hostRendersMaps = true  // `Map` draws real SwiftMap tiles
    #endif
    windowsGPUSurface = surface
    let renderer = SwiftGPURenderer(services: WindowsHostBridge(), surface: surface)
    Renderer.bind(renderer)
    return renderer
    #else
    #error("HostDrawnRenderer has been removed; SwiftGPU is now the only self-drawing renderer. Link swift_gpu (D3D11) for Windows — see docs/renderer_layers.md")
    #endif
}

func windowsResized(width: Double, height: Double) {
    #if canImport(SwiftGPU)
    windowsGPUSurface?.refreshSize()
    #endif
    MainActor.assumeIsolated { Runtime.shared.resize(width: width, height: height) }
}

/// Owns the native window and the render loop. `@main` on Windows calls
/// `WindowsApp.run()` after installing the app (see `App.main()`).
enum WindowsApp {
    static func run() {
        iso_set_pointer_callback { kind, x, y in
            Runtime.shared.pointerEvent(kind: Int(kind), x: x, y: y)
        }
        iso_set_wheel_callback { x, y, dx, dy in
            Runtime.shared.wheelEvent(x: x, y: y, deltaX: dx, deltaY: dy)
        }
        iso_set_resize_callback { width, height in
            windowsResized(width: width, height: height)
        }
        iso_set_paint_callback(windowsPaint)
        iso_set_fetch_callback(windowsFetchComplete)
        iso_set_text_changed_callback(windowsTextChanged)
        iso_set_text_submit_callback(windowsTextSubmit)
        iso_set_control_changed_callback(windowsControlChanged)

        // The app's `WindowGroup` title (installed before run()), else Isomer.
        let title = MainActor.assumeIsolated { Runtime.shared.windowTitle }
        (title.isEmpty ? "Isomer" : title).withCString { titlePtr in
            iso_window_create(1100, 720, titlePtr)
        }

        var width: Double = 0
        var height: Double = 0
        iso_window_size(&width, &height)

        // An ImageIO picture's last reference may go on any thread; its
        // bytes are the main thread's.
        _ImageIOHost.release = { source in
            DispatchQueue.main.async { withUTF8Pointer(source) { iso_forget_image($0, $1) } }
        }
        let host = windowsMakeHost()
        MainActor.assumeIsolated { Runtime.shared.start(host: host, width: width, height: height) }
        var presentPaces = false
        #if canImport(SwiftGPU)
        presentPaces = windowsGPUSurface != nil
        #endif
        while iso_pump_events() != 0 {
            isoRunMainQueue()
            iso_drain_fetches()
            iso_drain_images()
            DesktopBench.shared?.tick()
            MainActor.assumeIsolated { Runtime.shared.renderFrame() }
            DesktopBench.shared?.framePresented()
            // Under SwiftGPU, Present(1, 0) waits for vblank — no extra sleep.
            if !presentPaces { iso_frame_wait() }
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
