package dev.swiftmap.runtime

import android.content.Context
import android.opengl.GLSurfaceView
import android.util.Log
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import kotlin.math.log2

/**
 * The imperative SwiftMap entry point on Android: a GLSurfaceView driving
 * the Swift engine over the swift_ffi bridge. Event-driven
 * (RENDERMODE_WHEN_DIRTY): the engine invalidates via `scheduleRender`.
 *
 * Threading: the Swift engine is single-threaded on the GL thread — touch
 * input marshals through `queueEvent`, frames render inside `onDrawFrame`,
 * and decoded tiles are uploaded + reported on the GL thread too.
 */
class MapSurfaceView(
    context: Context,
    private val initialLatitude: Double = 37.7749,
    private val initialLongitude: Double = -122.4194,
    private val initialZoom: Double = 12.0,
    private val initialBearing: Double = 0.0,
    private val initialTilt: Double = 0.0,
) : GLSurfaceView(context) {
    private val density = context.resources.displayMetrics.density
    private val fetcher = TileFetcher()
    private var started = false
    private var annotationsSpec: String = ""
    private var polygonsSpec: String = ""
    private var polylinesSpec: String = ""
    private var selectedAnnotationId: String? = null

    /** The selected annotation's callout state, posted on the main thread
     * every frame: (title, x, y) in dp, or null when nothing is selected. */
    var onCalloutChanged: ((String, Double, Double) -> Unit)? = null
    var onCalloutHidden: (() -> Unit)? = null

    /** Replace the annotation set (spec grammar in MapOverlaySpec.swift):
     * `id|lat|lon|red|green|blue|alpha|radius` records joined by ";". */
    fun setAnnotations(spec: String) {
        annotationsSpec = spec
        if (started) {
            queueEvent { SwiftMapBridge.smSetAnnotations(spec) }
        }
    }

    /** Replace the polygon set:
     * `id|fillR,G,B,A|strokeR,G,B,A,width|lat,lon;…` records joined by
     * newlines (empty stroke field = no stroke). */
    fun setPolygons(spec: String) {
        polygonsSpec = spec
        if (started) {
            queueEvent { SwiftMapBridge.smSetPolygons(spec) }
        }
    }

    /** Replace the polyline set: `id|red,green,blue,alpha|width|lat,lon;…`
     * records joined by newlines. */
    fun setPolylines(spec: String) {
        polylinesSpec = spec
        if (started) {
            queueEvent { SwiftMapBridge.smSetPolylines(spec) }
        }
    }

    private val host = object : MapAndroidHost {
        override fun presentFrame(infoJSON: String) {
            // Drawing already happened in Swift (SwiftGPU/GLES); this is
            // the slim per-frame info. Reposition the selected annotation's
            // callout from its projected anchor (main-thread UI).
            val info = FrameInfo.parse(infoJSON)
            val anchor = selectedAnnotationId?.let { id -> info.annotationAnchors.find { it.id == id } }
            post {
                if (anchor != null && anchor.title.isNotEmpty()) {
                    onCalloutChanged?.invoke(anchor.title, anchor.x, anchor.y)
                } else {
                    onCalloutHidden?.invoke()
                }
            }
        }

        override fun annotationTapped(id: String, title: String, x: Double, y: Double) {
            // GL thread (during smTap); toggle and redraw to reposition.
            selectedAnnotationId = if (selectedAnnotationId == id) null else id
            requestRender()
        }

        override fun requestTile(key: String, url: String) {
            fetcher.fetch(key, url) { bitmap ->
                // RGBA extraction happens on the fetcher's worker; the GL
                // thread only uploads.
                val rgba = bitmap?.let { TileFetcher.rgbaBytes(it) }
                val width = bitmap?.width ?: 0
                val height = bitmap?.height ?: 0
                bitmap?.recycle()
                queueEvent {
                    if (rgba != null) {
                        SwiftMapBridge.smTileLoaded(key, width, height, rgba)
                    } else {
                        SwiftMapBridge.smTileFailed(key)
                    }
                }
            }
        }

        override fun scheduleRender() {
            requestRender()
        }

        override fun log(message: String) {
            Log.i("SwiftMap", message)
        }
    }

    init {
        setEGLContextClientVersion(2)
        setRenderer(object : Renderer {
            override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
                // Fresh context: every GL handle is gone; restart the
                // engine so every visible tile is refetched (smStart resets
                // the SwiftGPU device + scene).
                started = false
            }

            override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
                SwiftMapBridge.smSurfaceChanged(width, height)
                if (!started) {
                    started = true
                    SwiftMapBridge.smStart(
                        host,
                        width / density.toDouble(), height / density.toDouble(),
                        initialLatitude, initialLongitude, initialZoom,
                        initialBearing, initialTilt,
                    )
                    // Overlays set before start (or lost to a context-loss
                    // restart) are re-applied to the fresh engine.
                    if (annotationsSpec.isNotEmpty()) SwiftMapBridge.smSetAnnotations(annotationsSpec)
                    if (polygonsSpec.isNotEmpty()) SwiftMapBridge.smSetPolygons(polygonsSpec)
                    if (polylinesSpec.isNotEmpty()) SwiftMapBridge.smSetPolylines(polylinesSpec)
                } else {
                    SwiftMapBridge.smResize(width / density.toDouble(), height / density.toDouble())
                }
            }

            override fun onDrawFrame(gl: GL10?) {
                SwiftMapBridge.smRender()
            }
        })
        renderMode = RENDERMODE_WHEN_DIRTY
    }

    // MARK: gestures — drag pans, pinch zooms about the focal point,
    // double-tap zooms in a level.

    private val scaleDetector = ScaleGestureDetector(
        context,
        object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScale(detector: ScaleGestureDetector): Boolean {
                val delta = log2(detector.scaleFactor.toDouble())
                val x = detector.focusX / density.toDouble()
                val y = detector.focusY / density.toDouble()
                queueEvent { SwiftMapBridge.smZoom(delta, x, y) }
                return true
            }
        },
    )

    private val gestureDetector = GestureDetector(
        context,
        object : GestureDetector.SimpleOnGestureListener() {
            override fun onDoubleTap(event: MotionEvent): Boolean {
                val x = event.x / density.toDouble()
                val y = event.y / density.toDouble()
                queueEvent { SwiftMapBridge.smZoom(1.0, x, y) }
                return true
            }

            override fun onSingleTapConfirmed(event: MotionEvent): Boolean {
                val x = event.x / density.toDouble()
                val y = event.y / density.toDouble()
                queueEvent { SwiftMapBridge.smTap(x, y) }
                return true
            }
        },
    )

    override fun onTouchEvent(event: MotionEvent): Boolean {
        scaleDetector.onTouchEvent(event)
        gestureDetector.onTouchEvent(event)
        val x = event.x / density.toDouble()
        val y = event.y / density.toDouble()
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN ->
                queueEvent { SwiftMapBridge.smPointer(0, x, y) }
            // A second finger starts a pinch: end the drag.
            MotionEvent.ACTION_POINTER_DOWN ->
                queueEvent { SwiftMapBridge.smPointer(2, x, y) }
            MotionEvent.ACTION_MOVE ->
                if (event.pointerCount == 1 && !scaleDetector.isInProgress) {
                    queueEvent { SwiftMapBridge.smPointer(1, x, y) }
                }
            // Back to one finger: restart the drag from where it sits.
            MotionEvent.ACTION_POINTER_UP -> {
                if (event.pointerCount == 2) {
                    val remaining = if (event.actionIndex == 0) 1 else 0
                    val rx = event.getX(remaining) / density.toDouble()
                    val ry = event.getY(remaining) / density.toDouble()
                    queueEvent { SwiftMapBridge.smPointer(0, rx, ry) }
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL ->
                queueEvent { SwiftMapBridge.smPointer(2, x, y) }
        }
        return true
    }
}
