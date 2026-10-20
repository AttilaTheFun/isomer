package dev.isomer.runtime

import android.opengl.GLSurfaceView
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/**
 * Thin GLSurfaceView.Renderer that drives the Swift render loop. The
 * SwiftGPURenderer draws every pixel in Swift through swift_gpu's OpenGL ES
 * backend during `nativeRender()`; this class only owns the GL surface
 * lifecycle and pumps frames.
 *
 * (The old Kotlin draw-list replay — an SDF rect shader plus text/image/
 * gradient/shadow textures decoded from a per-frame op buffer — was the
 * HostDrawnRenderer path and has been removed. `nativeRender` now always
 * returns an empty list.)
 */
class UIRenderer : GLSurfaceView.Renderer {
    private var started = false

    /** Tap-latency instrumentation (see WasmGpuView): GLSurfaceView frames
     * never enter the gfxinfo pipeline, so the benchmark reads input-DOWN
     * receipt -> end of each GL frame from here instead. Stamped by
     * IsomerView's touch listener. */
    companion object {
        @Volatile var lastInputAt = 0L
    }

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        // Nothing to set up: SwiftGPU rebuilds its GL programs after context
        // (re)creation via gpuDevice.contextLost(), which is signalled from
        // nativeSurfaceChanged in onSurfaceChanged below (always called after
        // this).
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        val density = NativeBridge.density
        // SwiftGPU draws in Swift and needs the surface's device-pixel size
        // (and a fresh-context signal, via contextLost() inside this call).
        SwiftUIBridge.nativeSurfaceChanged(width, height, density.toDouble())
        if (!started) {
            NativeBridge.nativeStart(width / density, height / density)
            started = true
        } else {
            NativeBridge.nativeResize(width / density, height / density)
        }
    }

    private var firstFrameLogged = false

    override fun onDrawFrame(gl: GL10?) {
        // SwiftGPU draws this frame in Swift (through swift_gpu) inside
        // nativeRender; there is no draw list to replay.
        NativeBridge.nativeRender()
        if (!firstFrameLogged) {
            firstFrameLogged = true
            // The honest content signal for benchmarks: SurfaceView is its own
            // layer, so ActivityManager's "Displayed" can fire before any GL
            // content exists. This logs when the first real frame is drawn.
            android.util.Log.i("Isomer", "[gpu-first-frame]")
        }
        val t0 = lastInputAt
        if (t0 != 0L) {
            // Tap receipt (UP dispatch) -> draw commands issued for the frame
            // that renders the update: the GL analogue of the View toolkit's
            // SYNC_QUEUED handoff. requestRender wakes the GL thread directly
            // (not vsync-paced), so no frame timing enters the metric.
            val us = (System.nanoTime() - t0) / 1000
            android.util.Log.i("Isomer", "[gpu-tap] handoff latency_us=$us")
        }
        // Keep a continuous loop going while the runtime is animating (an
        // in-flight fling, animation, sheet transition, or spinner). The
        // surface renders on demand, so without this a flick would render a
        // single frame and stop instead of decelerating.
        if (NativeBridge.nativeWantsRender()) {
            NativeBridge.surface?.requestRender()
        }
    }
}
