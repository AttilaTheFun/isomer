package dev.isomer.runtime

import android.app.Activity
import android.app.DatePickerDialog
import android.content.Context
import android.view.View
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.FrameLayout
import android.widget.Spinner
import android.widget.TextView
import org.json.JSONArray
import java.util.Calendar

/**
 * Reconciles native host-view widgets (Picker -> Spinner, DatePicker -> a
 * field that opens a DatePickerDialog) over the GL surface, keyed by id —
 * the Android analogue of the web DOM overlay in boot.js. Changes are sent
 * back to the runtime via NativeBridge.nativeHostEvent on the main thread.
 */
class HostViewManager(
    private val activity: Activity,
    private val root: FrameLayout,
    private val surface: MainThreadGLSurface,
) : NativeBridge.HostViews {

    private class Entry(val kind: String, val view: View)

    private val entries = HashMap<String, Entry>()

    private companion object {
        const val ACCENT = 0xFF0A84FF.toInt()
        const val BAR_BG_LIGHT = 0xFAF9F9F9.toInt()
        const val BAR_BG_DARK = 0xF21C1C1E.toInt()
        const val TITLE_LIGHT = 0xD9000000.toInt()
        const val TITLE_DARK = 0xF2FFFFFF.toInt()
        const val TAB_INACTIVE_LIGHT = 0x8C000000.toInt()
        const val TAB_INACTIVE_DARK = 0x8CFFFFFF.toInt()
    }

    override fun sync(json: String) {
        activity.runOnUiThread { reconcile(json) }
    }

    /** A borderless native ripple for tappable bar buttons. */
    private fun rippleBackground(ctx: Context): android.graphics.drawable.Drawable? {
        val outValue = android.util.TypedValue()
        ctx.theme.resolveAttribute(android.R.attr.selectableItemBackgroundBorderless, outValue, true)
        return if (outValue.resourceId != 0) ctx.getDrawable(outValue.resourceId) else null
    }

    private fun sendEvent(id: String, value: String) {
        surface.queueEvent {
            if (NativeBridge.nativeHostEvent(id, value)) {
                surface.requestRender()
            }
        }
    }

    private fun reconcile(json: String) {
        val density = NativeBridge.density
        val specs = JSONArray(json)
        val seen = HashSet<String>()
        for (i in 0 until specs.length()) {
            val spec = specs.getJSONObject(i)
            val id = spec.getString("id")
            val kind = spec.getString("kind")
            seen.add(id)

            var entry = entries[id]
            if (entry == null || entry.kind != kind) {
                entry?.let { root.removeView(it.view) }
                entry = Entry(kind, makeView(id, kind))
                entries[id] = entry
                root.addView(entry.view)
            }

            val params = FrameLayout.LayoutParams(
                (spec.getDouble("w") * density).toInt(),
                (spec.getDouble("h") * density).toInt(),
            )
            params.leftMargin = (spec.getDouble("x") * density).toInt()
            params.topMargin = (spec.getDouble("y") * density).toInt()
            entry.view.layoutParams = params
            updateView(id, entry.view, kind, spec)
        }
        val iterator = entries.entries.iterator()
        while (iterator.hasNext()) {
            val e = iterator.next()
            if (!seen.contains(e.key)) {
                root.removeView(e.value.view)
                iterator.remove()
            }
        }
    }

    private fun makeView(id: String, kind: String): View = when (kind) {
        "picker" -> Spinner(activity).also { spinner ->
            spinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, lid: Long) {
                    sendEvent(id, pos.toString())
                }

                override fun onNothingSelected(p: AdapterView<*>?) {}
            }
        }
        "menu" -> Spinner(activity).also { spinner ->
            // First entry is the label; selecting an action (pos > 0) fires it
            // and snaps the selection back to the label, matching the web.
            spinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, lid: Long) {
                    if (pos > 0) {
                        sendEvent(id, pos.toString())
                        spinner.setSelection(0)
                    }
                }

                override fun onNothingSelected(p: AdapterView<*>?) {}
            }
        }
        "webview" -> android.webkit.WebView(activity).also { web ->
            web.settings.javaScriptEnabled = true
            web.settings.domStorageEnabled = true
            web.webViewClient = android.webkit.WebViewClient()
        }
        "video" -> android.widget.VideoView(activity).also { video ->
            val controller = android.widget.MediaController(activity)
            controller.setAnchorView(video)
            video.setMediaController(controller)
        }
        "image" -> android.widget.ImageView(activity).also { iv ->
            iv.scaleType = android.widget.ImageView.ScaleType.FIT_CENTER
        }
        "tabbar" -> android.widget.LinearLayout(activity).also { bar ->
            bar.orientation = android.widget.LinearLayout.HORIZONTAL
            bar.setBackgroundColor(0xFAF9F9F9.toInt())
        }
        "navbar" -> android.widget.LinearLayout(activity).also { bar ->
            bar.orientation = android.widget.LinearLayout.HORIZONTAL
            bar.gravity = android.view.Gravity.CENTER_VERTICAL
            bar.setBackgroundColor(0xFAF9F9F9.toInt())
            val side = (48 * NativeBridge.density).toInt()
            // A bare, bold back chevron (no "Back" label), like other Android apps.
            val back = TextView(activity).apply {
                text = "‹"
                setTextColor(TITLE_LIGHT)
                textSize = 30f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                gravity = android.view.Gravity.CENTER
                isClickable = true
                background = rippleBackground(activity)
                setOnClickListener { sendEvent(id, "back") }
            }
            val title = TextView(activity).apply {
                textSize = 16f
                setTextColor(0xD9000000.toInt())
                gravity = android.view.Gravity.CENTER
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            }
            // Trailing item (a `.toolbar { Button … }`); also balances the back
            // button (min width = side) so the title stays centered when empty.
            val pad = (12 * NativeBridge.density).toInt()
            val trailing = TextView(activity).apply {
                textSize = 16f
                setTextColor(ACCENT)
                gravity = android.view.Gravity.CENTER
                minWidth = side
                setPadding(pad, 0, pad, 0)
                isClickable = true
                background = rippleBackground(activity)
                setOnClickListener { sendEvent(id, "trailing") }
            }
            bar.addView(back, android.widget.LinearLayout.LayoutParams(side, side))
            bar.addView(title, android.widget.LinearLayout.LayoutParams(0, -2, 1f))
            bar.addView(trailing, android.widget.LinearLayout.LayoutParams(-2, side))
            bar.tag = arrayOf(back, title, trailing)
        }
        "datepicker" -> TextView(activity).also { field ->
            field.setPadding(16, 12, 16, 12)
            field.setBackgroundColor(0x11000000)
            field.setOnClickListener { showDatePicker(id, field.text.toString()) }
        }
        else -> TextView(activity)
    }

    private fun updateView(id: String, view: View, kind: String, spec: org.json.JSONObject) {
        when (kind) {
            "picker" -> {
                val spinner = view as Spinner
                val options = spec.getJSONArray("options")
                val labels = ArrayList<String>(options.length())
                for (i in 0 until options.length()) labels.add(options.getString(i))
                val current = (spinner.adapter as? ArrayAdapter<*>)
                val needsAdapter = current == null || current.count != labels.size ||
                    (0 until labels.size).any { current.getItem(it) != labels[it] }
                if (needsAdapter) {
                    val adapter = ArrayAdapter(
                        activity, android.R.layout.simple_spinner_dropdown_item, labels
                    )
                    spinner.adapter = adapter
                }
                val index = spec.getString("value").toIntOrNull() ?: 0
                if (spinner.selectedItemPosition != index) spinner.setSelection(index)
            }
            "menu" -> {
                val spinner = view as Spinner
                val options = spec.getJSONArray("options")
                val labels = ArrayList<String>(options.length())
                for (i in 0 until options.length()) labels.add(options.getString(i))
                val current = (spinner.adapter as? ArrayAdapter<*>)
                val needsAdapter = current == null || current.count != labels.size ||
                    (0 until labels.size).any { current.getItem(it) != labels[it] }
                if (needsAdapter) {
                    val adapter = ArrayAdapter(
                        activity, android.R.layout.simple_spinner_dropdown_item, labels
                    )
                    spinner.adapter = adapter
                }
                if (spinner.selectedItemPosition != 0) spinner.setSelection(0)
            }
            "webview" -> {
                val web = view as android.webkit.WebView
                val url = spec.getString("value")
                if (web.url != url && url.isNotEmpty()) web.loadUrl(url)
            }
            "video" -> {
                val video = view as android.widget.VideoView
                val url = spec.getString("value")
                if (video.tag != url && url.isNotEmpty()) {
                    video.tag = url
                    video.setVideoURI(android.net.Uri.parse(url))
                }
            }
            "image" -> {
                // Raster formats decode here; animated GIF / SVG would need a
                // dedicated loader (Glide/Coil) — a follow-up.
                val iv = view as android.widget.ImageView
                val url = spec.getString("value")
                if (iv.tag != url && url.isNotEmpty()) {
                    iv.tag = url
                    kotlin.concurrent.thread {
                        try {
                            val stream = if (url.startsWith("http")) java.net.URL(url).openStream()
                            else activity.assets.open(url)
                            val bmp = stream.use { android.graphics.BitmapFactory.decodeStream(it) }
                            if (bmp != null) activity.runOnUiThread { iv.setImageBitmap(bmp) }
                        } catch (_: Exception) {}
                    }
                }
            }
            "navbar" -> {
                @Suppress("UNCHECKED_CAST")
                val views = view.tag as Array<TextView>
                val params = spec.getJSONObject("params")
                val dark = params.optString("dark", "0") == "1"
                view.setBackgroundColor(if (dark) BAR_BG_DARK else BAR_BG_LIGHT)
                views[1].text = params.optString("title", "")
                views[1].setTextColor(if (dark) TITLE_DARK else TITLE_LIGHT)
                views[0].setTextColor(if (dark) TITLE_DARK else TITLE_LIGHT)
                // Large-title mode: the inline bar title crossfades in only as
                // the big title scrolls under the bar.
                val large = params.optString("large", "0") == "1"
                views[1].alpha = if (large) (params.optString("inlineAlpha", "1").toFloatOrNull() ?: 1f) else 1f
                views[0].visibility = if (params.optString("back", "0") == "1") View.VISIBLE else View.INVISIBLE
                val trailing = params.optString("trailing", "")
                views[2].text = trailing
                views[2].visibility = if (trailing.isEmpty()) View.INVISIBLE else View.VISIBLE
            }
            "tabbar" -> {
                val bar = view as android.widget.LinearLayout
                val params = spec.getJSONObject("params")
                val count = params.optString("count", "0").toIntOrNull() ?: 0
                val selected = params.optString("selected", "0").toIntOrNull() ?: 0
                if (bar.childCount != count) {
                    bar.removeAllViews()
                    for (i in 0 until count) {
                        val cell = android.widget.LinearLayout(activity).apply {
                            orientation = android.widget.LinearLayout.VERTICAL
                            gravity = android.view.Gravity.CENTER
                            setOnClickListener { sendEvent(id, i.toString()) }
                        }
                        cell.addView(android.widget.ImageView(activity), android.widget.LinearLayout.LayoutParams(60, 60))
                        cell.addView(TextView(activity).apply {
                            textSize = 11f
                            gravity = android.view.Gravity.CENTER
                        })
                        bar.addView(cell, android.widget.LinearLayout.LayoutParams(0, -1, 1f))
                    }
                }
                val dark = params.optString("dark", "0") == "1"
                bar.setBackgroundColor(if (dark) BAR_BG_DARK else BAR_BG_LIGHT)
                for (i in 0 until count) {
                    val cell = bar.getChildAt(i) as android.widget.LinearLayout
                    val img = cell.getChildAt(0) as android.widget.ImageView
                    val lbl = cell.getChildAt(1) as TextView
                    val icon = params.optString("icon$i", "")
                    lbl.text = params.optString("label$i", "")
                    if (img.tag != icon) {
                        img.tag = icon
                        try {
                            activity.assets.open("$icon.png").use {
                                img.setImageBitmap(android.graphics.BitmapFactory.decodeStream(it))
                            }
                        } catch (_: Exception) {}
                    }
                    val active = i == selected
                    // Tint the (template) icon so it reads on either background.
                    img.setColorFilter(
                        if (active) ACCENT
                        else if (dark) TAB_INACTIVE_DARK else TAB_INACTIVE_LIGHT)
                    cell.alpha = 1f
                    lbl.setTextColor(
                        if (active) ACCENT
                        else if (dark) TAB_INACTIVE_DARK else TAB_INACTIVE_LIGHT)
                }
            }
            "datepicker" -> {
                (view as TextView).text = spec.getString("value")
            }
        }
    }

    private fun showDatePicker(id: String, iso: String) {
        val calendar = Calendar.getInstance()
        val parts = iso.split("-")
        if (parts.size == 3) {
            calendar.set(parts[0].toInt(), parts[1].toInt() - 1, parts[2].toInt())
        }
        DatePickerDialog(
            activity,
            { _, year, month, day ->
                val value = "%04d-%02d-%02d".format(year, month + 1, day)
                sendEvent(id, value)
            },
            calendar.get(Calendar.YEAR),
            calendar.get(Calendar.MONTH),
            calendar.get(Calendar.DAY_OF_MONTH),
        ).show()
    }
}
