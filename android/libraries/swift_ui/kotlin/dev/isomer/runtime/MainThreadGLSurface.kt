package dev.isomer.runtime

import android.content.Context
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLSurfaceView
import android.os.Handler
import android.os.Looper
import android.view.Choreographer
import android.view.SurfaceHolder
import android.view.SurfaceView

/**
 * The SwiftGPU renderer's surface: a SurfaceView whose OpenGL ES context is
 * current on the main thread, so the Swift runtime runs and draws there, as
 * it does under Compose. The runtime is main-actor isolated, as SwiftUI's
 * is; GLSurfaceView's own render thread can't run it (a main-actor check
 * there traps: `MainActor.assumeIsolated` off the main queue).
 *
 * It keeps the part of GLSurfaceView's interface the runtime's callers use:
 * `queueEvent` runs work on the main thread (posted, never inline: a caller
 * may be inside a frame), and `requestRender` asks for a frame on the next
 * vsync (Choreographer), from any thread. The renderer's callbacks are
 * GLSurfaceView.Renderer's, called on the main thread.
 */
class MainThreadGLSurface(context: Context, private val renderer: GLSurfaceView.Renderer) :
    SurfaceView(context), SurfaceHolder.Callback {
    private val main = Handler(Looper.getMainLooper())
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var config: EGLConfig? = null
    private var glContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var glSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var frameScheduled = false
    private var paused = false

    init {
        holder.addCallback(this)
    }

    /** `work` on the main thread, after what is already queued there. */
    fun queueEvent(work: Runnable) {
        main.post(work)
    }

    /** A frame on the next vsync (one however many ask before it). */
    fun requestRender() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post { requestRender() }
            return
        }
        if (frameScheduled) return
        frameScheduled = true
        Choreographer.getInstance().postFrameCallback {
            frameScheduled = false
            drawFrame()
        }
    }

    fun onResume() {
        paused = false
        requestRender()
    }

    fun onPause() {
        paused = true
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        if (glContext == EGL14.EGL_NO_CONTEXT) createContext()
        glSurface = EGL14.eglCreateWindowSurface(display, config, holder.surface, intArrayOf(EGL14.EGL_NONE), 0)
        makeCurrent()
        renderer.onSurfaceCreated(null, null)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        if (!makeCurrent()) return
        renderer.onSurfaceChanged(null, width, height)
        requestRender()
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        if (glSurface == EGL14.EGL_NO_SURFACE) return
        // The context stays (its programs and textures with it); only the
        // window's surface goes.
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, glContext)
        EGL14.eglDestroySurface(display, glSurface)
        glSurface = EGL14.EGL_NO_SURFACE
    }

    private fun drawFrame() {
        if (paused || !makeCurrent()) return
        renderer.onDrawFrame(null)
        EGL14.eglSwapBuffers(display, glSurface)
    }

    private fun makeCurrent(): Boolean =
        glSurface != EGL14.EGL_NO_SURFACE && EGL14.eglMakeCurrent(display, glSurface, glSurface, glContext)

    /** RGBA8, no depth or stencil, OpenGL ES 2 (as the GLSurfaceView had). */
    private fun createContext() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        EGL14.eglInitialize(display, version, 0, version, 1)
        val attributes = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_DEPTH_SIZE, 0, EGL14.EGL_STENCIL_SIZE, 0,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT, EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0)
        config = configs[0]
        glContext = EGL14.eglCreateContext(
            display, config, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
    }
}
