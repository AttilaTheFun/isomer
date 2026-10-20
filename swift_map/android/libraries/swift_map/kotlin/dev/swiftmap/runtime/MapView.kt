package dev.swiftmap.runtime

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.TextView

/**
 * The drop-in map widget: the GL surface plus the required OpenStreetMap
 * attribution (ODbL) overlaid bottom-right.
 */
class MapView(
    context: Context,
    latitude: Double = 37.7749,
    longitude: Double = -122.4194,
    zoom: Double = 12.0,
    bearing: Double = 0.0,
    tilt: Double = 0.0,
) : FrameLayout(context) {
    val surface = MapSurfaceView(context, latitude, longitude, zoom, bearing, tilt)

    /** See MapSurfaceView.setAnnotations / setPolygons / setPolylines. */
    fun setAnnotations(spec: String) = surface.setAnnotations(spec)

    fun setPolygons(spec: String) = surface.setPolygons(spec)

    fun setPolylines(spec: String) = surface.setPolylines(spec)

    /** The tapped annotation's callout: native text repositioned every
     * frame from the engine's projected anchor. */
    private val callout = TextView(context).apply {
        textSize = 12f
        setTextColor(Color.BLACK)
        background = GradientDrawable().apply {
            setColor(0xF2FFFFFF.toInt())
            cornerRadius = 6f * context.resources.displayMetrics.density
            setStroke(1, 0x33000000)
        }
        val pad = (6 * context.resources.displayMetrics.density).toInt()
        setPadding(pad, pad / 2, pad, pad / 2)
        visibility = GONE
    }

    init {
        addView(surface, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        val attribution = TextView(context).apply {
            text = "© OpenStreetMap contributors"
            textSize = 10f
            setTextColor(0x99000000.toInt())
            setBackgroundColor(0xB3FFFFFF.toInt())
            setPadding(8, 2, 8, 2)
        }
        addView(
            attribution,
            LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.END),
        )
        addView(callout, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
        val density = context.resources.displayMetrics.density
        surface.onCalloutChanged = { title, x, y ->
            callout.text = title
            callout.measure(MeasureSpec.UNSPECIFIED, MeasureSpec.UNSPECIFIED)
            // Anchor is in dp; center the bubble above the marker.
            callout.translationX = (x * density - callout.measuredWidth / 2).toFloat()
            callout.translationY = (y * density - callout.measuredHeight - 14 * density).toFloat()
            callout.visibility = VISIBLE
        }
        surface.onCalloutHidden = { callout.visibility = GONE }
    }
}
