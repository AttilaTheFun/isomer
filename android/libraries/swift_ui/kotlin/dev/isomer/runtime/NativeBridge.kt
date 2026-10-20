package dev.isomer.runtime

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Paint
import android.graphics.Typeface
import android.net.Uri
import android.opengl.GLSurfaceView
import java.util.concurrent.ConcurrentHashMap

/**
 * The Kotlin side of the Swift <-> Android bridge, carried by swift_ffi.
 *
 * Downward calls (Kotlin -> Swift) go through the generated `SwiftUIBridge`
 * facade; upward calls (Swift -> Kotlin) arrive on the [AndroidHost]
 * implementation passed to `nativeStart` (Swift holds it through a JNI
 * global ref in the generated foreign proxy). This object keeps the old
 * Float-based surface so the view/renderer call sites are unchanged.
 */
object NativeBridge {
    /**
     * Run `work` on the runtime's driving thread (the GL thread when a
     * surface renderer is live, else the main looper), then render a frame —
     * the delivery shape for any async host completion (e.g. an injected
     * dependency's callback). Generic: no service knowledge lives here.
     */
    fun deliverToRuntime(work: () -> Unit) {
        val view = surface
        if (view != null) {
            view.queueEvent {
                work()
                view.requestRender()
            }
        } else {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                work()
                NativeBridge.render()
                pumpFramesIfNeeded()
            }
        }
    }

    /** The Swift-facing host: measurement, chrome, and services. */
    private val host = object : AndroidHost {
        override fun measureText(text: String, fontSize: Double, weight: Int, wrapWidth: Double): TextMetrics {
            val wh = HostServices.measureText(text, fontSize, weight, wrapWidth)
            return TextMetrics(wh[0], wh[1])
        }

        override fun imageInfo(source: String, isRemote: Boolean): ImageInfoValue {
            if (surface == null) {
                // JetpackComposeRenderer: the component system owns
                // image loading — report "ready" so the runtime always emits
                // the image node; IsoImage loads the bitmap and recomposes.
                return ImageInfoValue(1, 0.0, 0.0)
            }
            val (state, w, h) = HostServices.imageInfo(source, isRemote)
            return ImageInfoValue(state, w, h)
        }

        override fun openURL(url: String) = openUrl(url)

        override fun registerImage(source: String, bytes: ByteArray) =
            HostServices.registerImageBytes(source, bytes)

        override fun decodeImage(source: String, bytes: ByteArray, maxPixelSize: Int, transform: Boolean): ImageInfoValue {
            val bitmap = HostServices.decodeNow(source, bytes, maxPixelSize, transform)
                ?: return ImageInfoValue(2, 0.0, 0.0)
            return ImageInfoValue(1, bitmap.width.toDouble(), bitmap.height.toDouble())
        }

        override fun displayScale(): Double = density.toDouble()

        override fun platformCommand(key: String, value: String) {
            platformCommandHandler?.invoke(key, value)
        }

        // Main-actor jobs queued from any thread: run them where the runtime
        // lives (GL thread or main), then render what they changed.
        override fun scheduleMainJobs() {
            runMainJobs()
        }

        override fun scheduleMainJobsAfter(milliseconds: Int) {
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed(
                { runMainJobs() },
                milliseconds.toLong(),
            )
        }

        override fun beginTextInput(
            text: String, x: Double, y: Double, width: Double, height: Double, fontSize: Double,
        ) {
            textInput?.begin(
                text, x.toFloat(), y.toFloat(), width.toFloat(), height.toFloat(),
                fontSize.toFloat())
        }

        override fun endTextInput() {
            textInput?.end()
        }

        override fun syncHostViews(viewsJSON: String) {
            hostViews?.sync(viewsJSON)
        }

        override fun renderTree(tree: ByteArray) {
            // The render-tree FlatBuffer (tree.fbs), reconciled into the retained
            // UNode tree so unchanged subtrees keep identity and only the changed
            // views update. Default consumer = the Compose interpreter; a host
            // may install another sink.
            treeSink?.invoke(tree) ?: ComposeTreeState.applyPatch(tree)
        }

        override fun rasterize(spec: String): ByteArray = rasterizeSpec(spec)    }

    // Downward calls, keeping the pre-swift_ffi Float surface the view code uses.
    fun nativeStart(width: Float, height: Float, renderer: String = "openGL") {
        // The embedding surfaces prepared already; a host driving this
        // bridge itself may not have.
        appContext?.let { IsomerRuntime.prepare(it) }
        SwiftUIBridge.nativeStart(host, renderer, width.toDouble(), height.toDouble())
        watchDispatchMainQueue()
    }

    /** libdispatch's main queue (`DispatchQueue.main`, the Swift SDK's own
     *  Dispatch): nothing in an Android process drains it, so the main
     *  looper watches its wake handle and drains it when it fires, as
     *  CoreFoundation's run loop does on Linux. Main-thread only: the queue
     *  belongs to the process's main thread. */
    private var mainQueueWatch: android.os.ParcelFileDescriptor? = null

    private fun watchDispatchMainQueue() {
        if (mainQueueWatch != null || android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) return
        val handle = SwiftUIBridge.nativeMainQueueHandle()
        if (handle < 0) return
        val watch = android.os.ParcelFileDescriptor.fromFd(handle)
        mainQueueWatch = watch
        val wakes = java.io.FileInputStream(watch.fileDescriptor)
        val input = android.os.MessageQueue.OnFileDescriptorEventListener.EVENT_INPUT
        android.os.Looper.getMainLooper().queue.addOnFileDescriptorEventListener(watch.fileDescriptor, input) { _, _ ->
            // An eventfd: reading it clears the wake.
            try { wakes.read(ByteArray(8)) } catch (_: java.io.IOException) {}
            SwiftUIBridge.nativeDrainMainQueue()
            if (SwiftUIBridge.nativeWantsRender()) {
                NativeBridge.render()
                pumpFramesIfNeeded()
            }
            input
        }
    }

    fun nativeRender(): ByteArray = SwiftUIBridge.nativeRender()

    /** A Swift render (build, diff, patch) as a trace section, so a system
     *  trace shows how long each takes and what asked for it. */
    fun render() {
        android.os.Trace.beginSection("iso:render")
        try { SwiftUIBridge.nativeRender() } finally { android.os.Trace.endSection() }
    }

    fun nativeWantsRender(): Boolean = SwiftUIBridge.nativeWantsRender()

    fun nativeOverscroll(path: String, amount: Float) =
        SwiftUIBridge.nativeOverscroll(path, amount.toDouble())

    fun nativeBack(): Boolean = SwiftUIBridge.nativeBack()

    fun nativePointer(kind: Int, x: Float, y: Float): Boolean =
        SwiftUIBridge.nativePointer(kind, x.toDouble(), y.toDouble())

    fun nativeWheel(x: Float, y: Float, deltaX: Float, deltaY: Float): Boolean =
        SwiftUIBridge.nativeWheel(x.toDouble(), y.toDouble(), deltaX.toDouble(), deltaY.toDouble())

    fun nativeResize(width: Float, height: Float) =
        SwiftUIBridge.nativeResize(width.toDouble(), height.toDouble())

    fun nativeTextChanged(text: String): Boolean = SwiftUIBridge.nativeTextChanged(text)

    fun nativeTextSubmitted(): Boolean = SwiftUIBridge.nativeTextSubmitted()

    fun nativeHostEvent(id: String, value: String): Boolean =
        SwiftUIBridge.nativeHostEvent(id, value)

    /** Logical-points-per-pixel scale — shared with the interpreter's pure
     * host services (the image cache / measurement read it). Forwarded so the
     * native call sites (`NativeBridge.density = …`) stay unchanged. */
    var density: Float
        get() = HostServices.density
        set(value) { HostServices.density = value }
    var appContext: Context?
        get() = HostServices.appContext
        set(value) { HostServices.appContext = value }
    var surface: GLSurfaceView? = null

    /// Compose mode: bumps recomposition when an async image lands.
    var onImageLoaded: (() -> Unit)?
        get() = HostServices.onImageLoaded
        set(value) { HostServices.onImageLoaded = value }

    /** Applies runtime platform commands (window title, status bar, …) to the
     * current Activity; installed by [IsomerRuntime.attach]. */
    var platformCommandHandler: ((String, String) -> Unit)? = null

    /** Where serialized trees go under a component-system renderer. Null =
     * the Compose interpreter (ComposeTreeState). */
    var treeSink: ((ByteArray) -> Unit)? = null

    /** Run a runtime entry point on the thread that owns the Swift runtime
     * (the GL thread under the SwiftGPURenderer, main otherwise) and render
     * the result. */
    /** Runs the queued main-actor jobs and renders only if they changed
     * state: most jobs (a socket read, a sleep ending) change nothing on
     * screen, and a render per job kept a long transcript's main thread
     * busy without pause. */
    private fun runMainJobs() {
        val view = surface
        if (view != null) {
            view.queueEvent {
                SwiftUIBridge.nativeRunMainJobs()
                if (SwiftUIBridge.nativeWantsRender()) view.requestRender()
            }
        } else {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                SwiftUIBridge.nativeRunMainJobs()
                if (SwiftUIBridge.nativeWantsRender()) {
                    NativeBridge.render()
                    pumpFramesIfNeeded()
                }
            }
        }
    }

    fun dispatchToRuntime(block: () -> Unit) {
        val view = surface
        if (view != null) {
            view.queueEvent {
                block()
                view.requestRender()
            }
        } else {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                block()
                NativeBridge.render()
                pumpFramesIfNeeded()
            }
        }
    }

    /** Compose mode has no GL frame loop: while the runtime wants further
     * frames (a nav transition, an implicit animation, a spinner), pump
     * Choreographer frames so time-driven state keeps advancing. The GL
     * path drives its own continuation via requestRender. */
    private var framePumpScheduled = false
    fun pumpFramesIfNeeded() {
        if (surface != null || framePumpScheduled) return
        if (!SwiftUIBridge.nativeWantsRender()) return
        framePumpScheduled = true
        android.view.Choreographer.getInstance().postFrameCallback {
            framePumpScheduled = false
            NativeBridge.render()
            pumpFramesIfNeeded()
        }
    }

    /** Set by MainActivity; manages the EditText overlay used by TextField. */
    interface TextInput {
        fun begin(text: String, x: Float, y: Float, w: Float, h: Float, fontSize: Float)
        fun end()
    }

    var textInput: TextInput? = null

    /** Set by MainActivity; reconciles native host-view widgets. */
    interface HostViews {
        fun sync(json: String)
    }

    var hostViews: HostViews? = null

    const val LINE_HEIGHT = HostServices.LINE_HEIGHT

    // Text measurement + SwiftGPU rasterization moved to HostServices (pure
    // Kotlin) so the wasm GPU cell — which carries no compiled Swift, hence no
    // SwiftUIBridge — shares them. These forward for existing call sites.

    fun rasterizeSpec(spec: String): ByteArray = HostServices.rasterizeSpec(spec)

    fun configurePaint(paint: Paint, sizePoints: Float, weight: Int) =
        HostServices.configurePaint(paint, sizePoints, weight)

    /** Greedy word wrap, mirroring the web renderer's layoutLines(). */
    fun wrapLines(paint: Paint, text: String, wrapWidthPx: Float?): List<String> =
        HostServices.wrapLines(paint, text, wrapWidthPx)

    /** Called from HostViewManager (openURL host views) and the Swift bridge. */
    fun openUrl(url: String) = HostServices.openUrl(url)

    // MARK: Images — the cache lives in HostServices (shared with the
    // interpreter's Swift-free wasm path). These forward for the native GL /
    // SwiftGPU raster call sites.

    fun bitmapFor(source: String): Bitmap? = HostServices.bitmapFor(source)

    fun imageBitmap(source: String, isRemote: Boolean): Bitmap? =
        HostServices.imageBitmap(source, isRemote)
}
