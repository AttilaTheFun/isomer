// The GPU wasm reactor glue — the self-drawing counterpart of the slim
// tree-emitting HotReloadBridge. The reactor binds `SwiftGPURenderer`
// (running *inside* the module) over swift_gpu's OpenGL ES device; the
// device's `@_extern(c)` gl* calls surface as wasm imports in module "env",
// which the host binds to its real native GL at instantiation. The host
// keeps only the services half (text measurement + rasterization, on the
// platform's text stack), imported under module "iso_gpu".
//
// ABI (host <-> wasm):
//   exports (@_cdecl, host calls in, ALL on the GL thread):
//     iso_hot_start(w, h)                      run @main once, bind + start
//     iso_hot_render()                         draw one frame (GL context current)
//     iso_hot_resize(w, h)
//     iso_hot_surface_changed(wpx, hpx, scale) surface size/density (+ fresh EGL context)
//     iso_hot_pointer(kind, x, y)              0 down / 1 up / 2 move (logical pts)
//     iso_hot_alloc(len) -> ptr                scratch for marshalling
//     iso_hot_free(ptr)
//   imports (wasm calls out):
//     iso_hot.log(ptr, len) / .epoch_millis() -> f64 / .schedule_render()
//     iso_gpu.measure_text(ptr, len, size, weight, wrap, outPtr)  2 f64 out
//     iso_gpu.raster_begin(specPtr, specLen) -> byteLen           host rasterizes
//     iso_gpu.raster_copy(destPtr)                                copy stash out
//     env.gl* (from swift_gpu's GLES backend)                     native OpenGL ES

import SwiftGPU
import SwiftUI
import IsomerSwiftUI

#if canImport(WASILibc)
import WASILibc
#endif

// MARK: - Imports (wasm -> host)

@_extern(wasm, module: "iso_hot", name: "log")
func iso_hot_log(_ ptr: UnsafePointer<UInt8>?, _ len: Int32)

@_extern(wasm, module: "iso_hot", name: "epoch_millis")
func iso_hot_epoch_millis() -> Double

@_extern(wasm, module: "iso_hot", name: "schedule_render")
func iso_hot_schedule_render()

@_extern(wasm, module: "iso_gpu", name: "measure_text")
func iso_gpu_measure_text(
    _ ptr: UnsafePointer<UInt8>?, _ len: Int32,
    _ fontSize: Double, _ weight: Int32, _ wrapWidth: Double,
    _ outWH: UnsafeMutablePointer<Double>?
)

@_extern(wasm, module: "iso_gpu", name: "raster_begin")
func iso_gpu_raster_begin(_ specPtr: UnsafePointer<UInt8>?, _ specLen: Int32) -> Int32

@_extern(wasm, module: "iso_gpu", name: "raster_copy")
func iso_gpu_raster_copy(_ destPtr: UnsafeMutablePointer<UInt8>?)

// MARK: - The GL surface (size/density arrive from the host before start)

/// The SwiftGPU surface: swift_gpu's GLES device, driven on the host's GL
/// thread (every export here is called with the EGL context current).
final class GLESReactorSurface: SwiftGPURendererSurface {
    let gpuDevice = GLESGPUDevice()
    var displayScale: Double = 1
    var widthPx = 0
    var heightPx = 0
    var device: GPUDevice { gpuDevice }

    func beginFrame(clear: GPUColor, width: Double, height: Double) -> GPURenderPass? {
        gpuDevice.beginFrame(widthPx: widthPx, heightPx: heightPx, clear: clear)
    }

    func endFrame() {
        gpuDevice.endFrame()
    }
}

nonisolated(unsafe) var gpuSurface = GLESReactorSurface()

// MARK: - Host services bridge

/// The services half `SwiftGPURenderer` wraps: measurement + rasterization
/// cross out to the host (the platform's text stack); time/log/scheduling
/// ride the same iso_hot imports as the tree-emitting reactor.
struct GpuHostBridge: HostBridge {
    func measureText(_ text: String, fontSize: Double, weight: Int, wrapWidth: Double?) -> CGSize {
        var out = [0.0, 0.0]
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            out.withUnsafeMutableBufferPointer { wh in
                iso_gpu_measure_text(
                    buffer.baseAddress, Int32(buffer.count),
                    fontSize, Int32(weight), wrapWidth ?? -1,
                    wh.baseAddress)
            }
        }
        return CGSize(width: out[0], height: out[1])
    }

    func rasterize(_ spec: String) -> [UInt8] {
        let bytes = Array(spec.utf8)
        let len = bytes.withUnsafeBufferPointer {
            iso_gpu_raster_begin($0.baseAddress, Int32($0.count))
        }
        guard len > 0 else { return [] }
        var result = [UInt8](repeating: 0, count: Int(len))
        result.withUnsafeMutableBufferPointer { iso_gpu_raster_copy($0.baseAddress) }
        return result
    }

    // No image pipeline in the GPU reactor yet (the host raster path covers
    // text/gradients/shadows); report images as still loading.
    func imageInfo(_ source: String, isRemote: Bool) -> ImageStatus { .loading }

    func syncHostViews(_ viewsJSON: String) {}
    func beginTextInput(_ text: String, in rect: CGRect, fontSize: Double) {}
    func endTextInput() {}

    func scheduleRender() { iso_hot_schedule_render() }

    func now() -> Double { iso_hot_epoch_millis() / 1000 }

    func log(_ message: String) {
        let bytes = Array(message.utf8)
        bytes.withUnsafeBufferPointer { iso_hot_log($0.baseAddress, Int32($0.count)) }
    }
}

// MARK: - Exports (host -> wasm)

// The app's synthesized @main, run once to install the App into the Runtime
// (the reactor is linked without a command `_start`). On wasm32 the two-arg C
// `main` is mangled to `__main_argc_argv`.
@_extern(c, "__main_argc_argv")
func _application_main(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_cdecl("iso_hot_surface_changed")
public func iso_hot_surface_changed(_ widthPx: Int32, _ heightPx: Int32, _ density: Double) {
    gpuSurface.widthPx = Int(widthPx)
    gpuSurface.heightPx = Int(heightPx)
    gpuSurface.displayScale = density
    gpuSurface.gpuDevice.contextLost() // fresh EGL context: rebuild programs
}

@_cdecl("iso_hot_start")
public func iso_hot_start(_ width: Double, _ height: Double) {
    if Runtime.shared.host == nil {
        _ = _application_main(0, nil)
    }
    // The self-drawing renderer: SwiftGPU draws every pixel through the
    // env.gl* imports; the SwiftGPURenderer is itself the runtime's host
    // (drawing half in-module, services half bridged to iso_gpu).
    // The host calls every export on its one UI thread: that is the main
    // actor here (as in HotBridge.swift).
    MainActor.assumeIsolated {
        let gpuRenderer = SwiftGPURenderer(services: GpuHostBridge(), surface: gpuSurface)
        Renderer.bind(gpuRenderer)
        Runtime.shared.start(host: gpuRenderer, width: width, height: height)
    }
}

@_cdecl("iso_hot_render")
public func iso_hot_render() {
    MainActor.assumeIsolated { Runtime.shared.renderFrame() }
}

@_cdecl("iso_hot_resize")
public func iso_hot_resize(_ width: Double, _ height: Double) {
    MainActor.assumeIsolated { Runtime.shared.resize(width: width, height: height) }
}

/// Graceful shutdown (see HotBridge.swift): cancel view tasks, stop
/// rendering; the host drains while `iso_hot_pending_tasks` > 0.
@_cdecl("iso_hot_shutdown")
public func iso_hot_shutdown() {
    MainActor.assumeIsolated { Runtime.shared.shutdown() }
}

@_cdecl("iso_hot_pending_tasks")
public func iso_hot_pending_tasks() -> Int32 {
    MainActor.assumeIsolated { Int32(clamping: Runtime.shared.pendingTaskCount) }
}

/// Pointer input in logical points; kind: 0 down / 1 up / 2 move. Returns 1
/// when the runtime wants a redraw (the host then requests a GL frame).
@_cdecl("iso_hot_pointer")
public func iso_hot_pointer(_ kind: Int32, _ x: Double, _ y: Double) -> Int32 {
    MainActor.assumeIsolated { Runtime.shared.pointerEvent(kind: Int(kind), x: x, y: y) }
    return 1
}

@_cdecl("iso_hot_alloc")
public func iso_hot_alloc(_ len: Int32) -> UnsafeMutableRawPointer? {
    malloc(Int(len))
}

@_cdecl("iso_hot_free")
public func iso_hot_free(_ ptr: UnsafeMutableRawPointer?) {
    free(ptr)
}
