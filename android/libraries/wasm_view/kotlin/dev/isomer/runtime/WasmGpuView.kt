package dev.isomer.runtime

// The GPU (self-drawing) counterpart of `WasmView`: hosts a wasm feature
// reactor that runs `SwiftGPURenderer` *inside the module* and draws every
// pixel through native OpenGL ES (the reactor's "env" gl* imports, bound by
// the WAMR host). Where `WasmView` decodes the reactor's tree into Jetpack
// Compose, this view carries NO Compose at all — the wasm cell's analogue of
// the compiled path's `IsomerView` — so the APK is Swift-free AND
// Compose-free: just this GLSurfaceView, libiso_wamr_jni.so, and the bundle.
//
// Threading: everything (instantiate, start, render, input) runs on the
// GLSurfaceView's GL thread with the EGL context current — the reactor draws
// during render, and WAMR re-binds its exec_env to the calling thread. Module
// load therefore happens OFF the main thread here, unlike WasmView's on-main
// load (a startup win that comes free with the GL thread model).

import android.annotation.SuppressLint
import android.content.Context
import android.opengl.GLSurfaceView
import android.view.MotionEvent
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

@SuppressLint("ClickableViewAccessibility")
class WasmGpuView(
    context: Context,
    // Supplies the bundle bytes; invoked on whichever thread initializes the
    // reactor (below), so the asset read/decompress is part of the A/B too.
    private val loadWasm: () -> ByteArray,
    // Init-threading A/B (benchmark): the GL-thread model loads the module
    // OFF-main by construction; `mainThreadInit = true` instead reads +
    // instantiates the reactor synchronously on the main thread here
    // (blocking onCreate, like the toolkit cells' default), and the GL thread
    // only starts/drives it (WAMR re-binds its exec_env per call, so the
    // handoff is safe).
    mainThreadInit: Boolean = false,
) : GLSurfaceView(context) {
    @Volatile private var runtime: WamrRuntime? = null
    private val density = resources.displayMetrics.density

    // Tap-latency instrumentation: GLSurfaceView frames never enter the UI
    // toolkit's gfxinfo pipeline, so the benchmark reads this instead —
    // input-DOWN receipt (main thread) -> end of each GL frame (just before
    // swap). The parser takes the last frame of each tap burst, mirroring the
    // gfxinfo HandleInputStart -> FrameCompleted span used for other cells.
    @Volatile private var lastInputAt = 0L

    private val host = object : WamrHost {
        // Self-drawing reactor: no tree ever crosses (drawing stays in-module).
        override fun renderTree(tree: ByteArray) {}
        override fun scheduleRender() = requestRender()
        override fun log(message: String) {
            android.util.Log.i("Isomer", "[wasm] $message")
        }
        // measureText/rasterize keep the WamrHost defaults (HostServices).
    }

    // Set once iso_hot_start ran (on the GL thread, context current).
    @Volatile private var started = false

    init {
        HostServices.appContext = context.applicationContext
        HostServices.density = density
        if (mainThreadInit) {
            // A/B: block the main thread on asset read + module load +
            // instantiate (the toolkit cells' default shape); start still
            // happens on the GL thread once the surface exists.
            val t0 = android.os.SystemClock.uptimeMillis()
            val wasm = loadWasm()
            android.util.Log.i(
                "Isomer", "[wasm-init] start — ${wasm.size} bytes (mainThreadInit)")
            runtime = try {
                WamrRuntime(wasm, host)
            } catch (e: Throwable) {
                android.util.Log.e("Isomer", "wasm gpu reactor failed to start", e)
                null
            }
            val ms = android.os.SystemClock.uptimeMillis() - t0
            android.util.Log.i("Isomer", "[wasm-init] done in ${ms}ms")
        }
        setEGLContextClientVersion(2)
        setEGLConfigChooser(8, 8, 8, 8, 0, 0)
        setRenderer(ReactorRenderer())
        renderMode = RENDERMODE_WHEN_DIRTY
        setOnTouchListener { _, event ->
            val kind = when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> 0
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> 1
                MotionEvent.ACTION_MOVE -> 2
                else -> -1
            }
            if (kind >= 0) {
                // Anchor at UP (kind 1): that's the event that triggers the
                // action; DOWN clears so press-highlight frames don't log.
                lastInputAt = if (kind == 1) System.nanoTime() else 0L
                val x = (event.x / density).toDouble()
                val y = (event.y / density).toDouble()
                queueEvent {
                    if (runtime?.pointer(kind, x, y) == true) requestRender()
                }
            }
            true
        }
    }

    fun destroy() {
        queueEvent {
            runtime?.destroy()
            runtime = null
        }
    }

    private inner class ReactorRenderer : Renderer {
        override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
            // Programs (re)build inside the reactor after surfaceChanged's
            // contextLost signal (onSurfaceChanged always follows).
        }

        override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
            val widthPt = width / density.toDouble()
            val heightPt = height / density.toDouble()
            var rt = runtime
            if (rt == null) {
                // Default (off-main) model: first surface — read + instantiate
                // ON the GL thread, so the whole module init overlaps the main
                // thread's activity setup + first (empty) frame.
                val t0 = android.os.SystemClock.uptimeMillis()
                val wasm = loadWasm()
                android.util.Log.i("Isomer", "[wasm-init] start — ${wasm.size} bytes")
                rt = try {
                    WamrRuntime(wasm, host)
                } catch (e: Throwable) {
                    android.util.Log.e("Isomer", "wasm gpu reactor failed to start", e)
                    return
                }
                runtime = rt
                val ms = android.os.SystemClock.uptimeMillis() - t0
                android.util.Log.i("Isomer", "[wasm-init] done in ${ms}ms")
            }
            if (!started) {
                started = true
                rt.surfaceChanged(width, height, density.toDouble())
                rt.start(widthPt, heightPt)
            } else {
                rt.surfaceChanged(width, height, density.toDouble())
                rt.resize(widthPt, heightPt)
            }
        }

        private var firstFrameLogged = false

        override fun onDrawFrame(gl: GL10?) {
            runtime?.render()
            if (!firstFrameLogged) {
                firstFrameLogged = true
                // Honest content signal (see UIRenderer): "Displayed" can fire
                // before the SurfaceView layer has GL content.
                android.util.Log.i("Isomer", "[gpu-first-frame]")
            }
            val t0 = lastInputAt
            if (t0 != 0L) {
                // Tap receipt (UP dispatch) -> draw commands issued; see
                // UIRenderer's twin comment.
                val us = (System.nanoTime() - t0) / 1000
                android.util.Log.i("Isomer", "[gpu-tap] handoff latency_us=$us")
            }
        }
    }
}
