package dev.isomer.runtime

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * The pure-Kotlin host services the Compose interpreter needs — image loading,
 * the display scale, and openURL — with NO dependency on the native
 * `SwiftUIBridge` (compiled Swift). This is what lets the interpreter
 * (FlatTree + ComposeRenderer/IsoNode) compile and run in the "wasm" delivery
 * cell, where the app carries no Swift.
 *
 * The native compiled-Swift path (NativeBridge) reads and reuses this same
 * image cache and scale; the wasm path (WasmView) sets [appContext]/[density]
 * itself. [onImageLoaded] is the universal "an async image landed, recompose"
 * hook (the GL path points it at `requestRender`; Compose/wasm bump recomposition).
 */
object HostServices {
    /** Logical-points-per-pixel scale, set by the host before start. */
    var density: Float = 1f

    var appContext: Context? = null

    /** Fires when an async image finishes loading (recompose / re-render). */
    var onImageLoaded: (() -> Unit)? = null

    // MARK: Images

    private class ImageEntry {
        @Volatile var state = 0 // 0 loading, 1 ready, 2 failed
        @Volatile var bitmap: Bitmap? = null
    }

    private val images = ConcurrentHashMap<String, ImageEntry>()

    /** Loading and decoding happen here, never on the main thread: a few
     *  threads (not one per picture), so a screenful of pictures arriving
     *  at once doesn't starve the main thread of a core. */
    private val loader = Executors.newFixedThreadPool(3) { runnable ->
        Thread(runnable, "isomer-image").apply {
            isDaemon = true
            priority = Thread.NORM_PRIORITY - 1
        }
    }

    /** Encoded bytes handed over by `IsomerImages.register` (by source). */
    private val registered = ConcurrentHashMap<String, ByteArray>()

    private fun imageEntry(source: String, isRemote: Boolean): ImageEntry =
        images.getOrPut(source) {
            ImageEntry().also { created ->
                loader.execute {
                    val bitmap = loadBitmap(source, isRemote)
                    // Start the texture upload now, on the render thread,
                    // rather than at the first frame that draws it.
                    bitmap?.prepareToDraw()
                    created.bitmap = bitmap
                    created.state = if (bitmap != null) 1 else 2
                    onImageLoaded?.invoke()
                }
            }
        }

    /** ImageIO's thumbnail: decode `bytes` now, on the calling thread (not
     *  the main one), no larger than `maxPixelSize` on its longest side (0:
     *  whole), upright when `transform` (EXIF orientation); the bitmap is
     *  cached as `source`, ready for the first frame that draws it. */
    fun decodeNow(source: String, bytes: ByteArray, maxPixelSize: Int, transform: Boolean): Bitmap? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            val longest = maxOf(bounds.outWidth, bounds.outHeight)
            var sample = 1
            if (maxPixelSize > 0) while (longest / (sample * 2) >= maxPixelSize) sample *= 2
            var bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size,
                BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
            val decodedLongest = maxOf(bitmap.width, bitmap.height)
            if (maxPixelSize in 1 until decodedLongest) {
                val scale = maxPixelSize.toFloat() / decodedLongest
                bitmap = Bitmap.createScaledBitmap(bitmap,
                    maxOf(1, (bitmap.width * scale).toInt()), maxOf(1, (bitmap.height * scale).toInt()), true)
            }
            if (transform) {
                val orientation = try {
                    android.media.ExifInterface(java.io.ByteArrayInputStream(bytes))
                        .getAttributeInt(android.media.ExifInterface.TAG_ORIENTATION, android.media.ExifInterface.ORIENTATION_NORMAL)
                } catch (_: Exception) { android.media.ExifInterface.ORIENTATION_NORMAL }
                val matrix = android.graphics.Matrix()
                when (orientation) {
                    android.media.ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
                    android.media.ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
                    android.media.ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
                    android.media.ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.setRotate(90f); matrix.postScale(-1f, 1f) }
                    android.media.ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
                    android.media.ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.setRotate(-90f); matrix.postScale(-1f, 1f) }
                    android.media.ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
                }
                if (!matrix.isIdentity) bitmap = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
            }
            bitmap.prepareToDraw()
            images[source] = ImageEntry().also { it.bitmap = bitmap; it.state = 1 }
            onImageLoaded?.invoke()
            bitmap
        } catch (error: Exception) {
            android.util.Log.w("Isomer", "image decode failed: $source", error)
            null
        }
    }

    /** A picture's encoded bytes for `source` (`IsomerImages.register`):
     *  decoded off the main thread now, so it is ready by the time a row
     *  draws it. Empty bytes forget it. */
    fun registerImageBytes(source: String, bytes: ByteArray) {
        if (bytes.isEmpty()) {
            registered.remove(source)
            images.remove(source)
            return
        }
        registered[source] = bytes
        images.remove(source)
        imageEntry(source, false)
    }

    /** Loading state (0/1/2) and dimensions of a source, kicking off the load. */
    fun imageInfo(source: String, isRemote: Boolean): Triple<Int, Double, Double> {
        val entry = imageEntry(source, isRemote)
        val bitmap = entry.bitmap
        return when {
            entry.state == 1 && bitmap != null ->
                Triple(1, bitmap.width.toDouble(), bitmap.height.toDouble())
            entry.state == 2 -> Triple(2, 0.0, 0.0)
            else -> Triple(0, 0.0, 0.0)
        }
    }

    fun bitmapFor(source: String): Bitmap? = images[source]?.bitmap

    /** Compose renderer: query (and trigger) the shared image cache. */
    fun imageBitmap(source: String, isRemote: Boolean): Bitmap? =
        imageEntry(source, isRemote).bitmap

    /** Decodes encoded bytes no larger than the screen needs: a phone
     *  photo or a desktop screenshot decoded whole is tens of megabytes, and
     *  its texture upload stalls the frame that first draws it. */
    private fun decodeScaled(bytes: ByteArray): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val metrics = appContext?.resources?.displayMetrics
        val limit = maxOf(metrics?.widthPixels ?: 2048, metrics?.heightPixels ?: 2048)
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= limit || bounds.outHeight / (sample * 2) >= limit) sample *= 2
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
    }

    private fun loadBitmap(source: String, isRemote: Boolean): Bitmap? {
        return try {
            val handed = registered[source]
            if (handed != null) {
                decodeScaled(handed)
            } else if (source.startsWith("isomer-image://")) {
                // Released, or never handed over.
                null
            } else if (source.startsWith("file://")) {
                // A local file (the image picker's copy, an imported asset).
                decodeScaled(java.io.File(source.removePrefix("file://")).readBytes())
            } else if (source.startsWith("data:")) {
                // data:<mime>;base64,<payload> (the image picker's result).
                val comma = source.indexOf(',')
                if (comma < 0) return null
                val bytes = android.util.Base64.decode(source.substring(comma + 1), android.util.Base64.DEFAULT)
                decodeScaled(bytes)
            } else if (isRemote) {
                val connection = URL(source).openConnection() as HttpURLConnection
                // An identifying User-Agent: tile.openstreetmap.org (the `Map`
                // view's tiles ride this loader) rejects default Java clients
                // (https://operations.osmfoundation.org/policies/tiles/).
                connection.setRequestProperty(
                    "User-Agent",
                    "Isomer/0.1 (+https://github.com/AttilaTheFun/isomer)",
                )
                connection.connectTimeout = 15000
                connection.readTimeout = 15000
                connection.instanceFollowRedirects = true
                connection.inputStream.use { decodeScaled(it.readBytes()) }
            } else {
                val assets = appContext?.assets ?: return null
                for (candidate in listOf(source, "$source.png", "$source.jpg")) {
                    try {
                        assets.open(candidate).use { return BitmapFactory.decodeStream(it) }
                    } catch (_: Exception) {
                        // try next candidate
                    }
                }
                null
            }
        } catch (error: Exception) {
            android.util.Log.w("Isomer", "image load failed: $source", error)
            null
        }
    }

    /** Plain HTTP(S) GET for the wasm cells' fetch DI; null on failure. Call
     *  off the main thread. */
    fun httpGet(url: String): String? {
        return try {
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.connectTimeout = 15000
            connection.readTimeout = 15000
            connection.instanceFollowRedirects = true
            connection.setRequestProperty("User-Agent", "Isomer-Example/1.0")
            if (connection.responseCode in 200..299) {
                connection.inputStream.bufferedReader().use { it.readText() }
            } else {
                null
            }
        } catch (error: Exception) {
            android.util.Log.w("Isomer", "fetch failed: $url", error)
            null
        }
    }

    /** Open a URL in the browser (SwiftUI Link / openURL). */
    fun openUrl(url: String) {
        val context = appContext ?: return
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    // MARK: Text measurement + SwiftGPU rasterization
    //
    // Pure-Kotlin (Paint/Canvas), free of Compose and of the compiled path
    // (NativeBridge / AndroidHost), so any self-drawing host can share it.

    const val LINE_HEIGHT = 1.3f

    private val measurePaint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)

    fun configurePaint(paint: android.graphics.Paint, sizePoints: Float, weight: Int) {
        paint.textSize = sizePoints * density
        paint.typeface = android.graphics.Typeface.create(
            android.graphics.Typeface.DEFAULT, weight, false)
    }

    /** Measure wrapped text; returns {width, height} in logical points.
     *  `wrapWidth` in points, < 0 = unwrapped. */
    fun measureText(text: String, fontSize: Double, weight: Int, wrapWidth: Double): DoubleArray {
        configurePaint(measurePaint, fontSize.toFloat(), weight)
        val wrapPx = if (wrapWidth < 0) null else wrapWidth.toFloat() * density
        val lines = wrapLines(measurePaint, text, wrapPx)
        var maxWidth = 0f
        for (line in lines) {
            maxWidth = maxOf(maxWidth, measurePaint.measureText(line))
        }
        return doubleArrayOf(
            (maxWidth / density).toDouble(),
            lines.size * fontSize * LINE_HEIGHT,
        )
    }

    /** Greedy word wrap, mirroring the web renderer's layoutLines(). */
    fun wrapLines(paint: android.graphics.Paint, text: String, wrapWidthPx: Float?): List<String> {
        val lines = mutableListOf<String>()
        for (paragraph in text.split("\n")) {
            if (wrapWidthPx == null || paint.measureText(paragraph) <= wrapWidthPx) {
                lines.add(paragraph)
                continue
            }
            var current = ""
            for (word in paragraph.split(" ")) {
                val candidate = if (current.isEmpty()) word else "$current $word"
                if (paint.measureText(candidate) <= wrapWidthPx || current.isEmpty()) {
                    current = candidate
                } else {
                    lines.add(current)
                    current = word
                }
            }
            lines.add(current)
        }
        return lines
    }

    private fun argbColor(r: Double, g: Double, b: Double, a: Double): Int {
        return ((a * 255).toInt() shl 24) or ((r * 255).toInt() shl 16) or
            ((g * 255).toInt() shl 8) or (b * 255).toInt()
    }

    private fun gradientShader(spec: org.json.JSONObject, w: Float, h: Float): android.graphics.Shader? {
        val stopsArray = spec.getJSONArray("stops")
        val colors = IntArray(stopsArray.length())
        val locs = FloatArray(stopsArray.length())
        for (i in 0 until stopsArray.length()) {
            val stop = stopsArray.getJSONObject(i)
            val c = stop.getJSONArray("c")
            colors[i] = argbColor(c.getDouble(0), c.getDouble(1), c.getDouble(2), c.getDouble(3))
            locs[i] = stop.getDouble("l").toFloat()
        }
        if (colors.size < 2) return null
        return when (spec.getString("kind")) {
            "linear" -> {
                val p0 = spec.getJSONArray("p0"); val p1 = spec.getJSONArray("p1")
                android.graphics.LinearGradient(
                    p0.getDouble(0).toFloat() * w, p0.getDouble(1).toFloat() * h,
                    p1.getDouble(0).toFloat() * w, p1.getDouble(1).toFloat() * h,
                    colors, locs, android.graphics.Shader.TileMode.CLAMP,
                )
            }
            "radial" -> {
                val c = spec.getJSONArray("c")
                android.graphics.RadialGradient(
                    c.getDouble(0).toFloat() * w, c.getDouble(1).toFloat() * h,
                    maxOf(spec.getDouble("er").toFloat(), 0.01f),
                    colors, locs, android.graphics.Shader.TileMode.CLAMP,
                )
            }
            "angular" -> {
                val c = spec.getJSONArray("c")
                android.graphics.SweepGradient(
                    c.getDouble(0).toFloat() * w, c.getDouble(1).toFloat() * h, colors, locs,
                )
            }
            else -> null
        }
    }

    /** The SwiftGPU renderer's raster callback: spec JSON in,
     * [w u32 LE][h u32 LE][premultiplied RGBA8...] out (Android bitmaps are
     * premultiplied natively). Kinds mirror SwiftGPURenderer.swift. */
    fun rasterizeSpec(spec: String): ByteArray {
        val json = org.json.JSONObject(spec)
        val scale = density
        fun pack(bitmap: Bitmap): ByteArray {
            val buffer = java.nio.ByteBuffer.allocate(8 + bitmap.width * bitmap.height * 4)
                .order(java.nio.ByteOrder.LITTLE_ENDIAN)
            buffer.putInt(bitmap.width)
            buffer.putInt(bitmap.height)
            bitmap.copyPixelsToBuffer(buffer)
            bitmap.recycle()
            return buffer.array()
        }
        fun canvasBitmap(cssW: Double, cssH: Double): Pair<Bitmap, android.graphics.Canvas> {
            val bitmap = Bitmap.createBitmap(
                maxOf(1, (cssW * scale).toInt()), maxOf(1, (cssH * scale).toInt()),
                Bitmap.Config.ARGB_8888,
            )
            val canvas = android.graphics.Canvas(bitmap)
            canvas.scale(scale, scale)
            return bitmap to canvas
        }
        when (json.getString("kind")) {
            "text" -> {
                val text = json.getString("text")
                val size = json.getDouble("size").toFloat()
                val weight = json.getInt("weight")
                val wrap = json.getDouble("wrap").toFloat()
                // configurePaint scales textSize by density: the paint
                // measures and draws in DEVICE PIXELS (no canvas scale).
                val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
                configurePaint(paint, size, weight)
                paint.color = argbColor(json.getDouble("r"), json.getDouble("g"), json.getDouble("b"), json.getDouble("a"))
                // +1px epsilon: the wrap width is usually the measured
                // width itself; density rounding must not re-wrap it.
                val lines = wrapLines(paint, text, if (wrap > 0) wrap * scale + 1f else null)
                var maxWidthPx = 1f
                for (line in lines) maxWidthPx = maxOf(maxWidthPx, paint.measureText(line))
                val lineHeightPx = size * LINE_HEIGHT * scale
                val bitmap = Bitmap.createBitmap(
                    maxOf(1, maxWidthPx.toInt() + 1),
                    maxOf(1, (lines.size * lineHeightPx).toInt()),
                    Bitmap.Config.ARGB_8888,
                )
                val canvas = android.graphics.Canvas(bitmap)
                val metrics = paint.fontMetrics
                lines.forEachIndexed { index, line ->
                    val middle = (index + 0.5f) * lineHeightPx
                    canvas.drawText(line, 0f, middle - (metrics.ascent + metrics.descent) / 2, paint)
                }
                return pack(bitmap)
            }
            "gradient" -> {
                val w = json.getDouble("w")
                val h = json.getDouble("h")
                val radius = minOf(json.getDouble("radius"), w / 2, h / 2).toFloat()
                val (bitmap, canvas) = canvasBitmap(w, h)
                val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
                paint.shader = gradientShader(json.getJSONObject("gradient"), w.toFloat(), h.toFloat())
                val path = android.graphics.Path()
                path.addRoundRect(0f, 0f, w.toFloat(), h.toFloat(), radius, radius, android.graphics.Path.Direction.CW)
                canvas.drawPath(path, paint)
                return pack(bitmap)
            }
            "shadow" -> {
                val w = json.getDouble("w")
                val h = json.getDouble("h")
                val blur = json.getDouble("blur").toFloat()
                val radius = minOf(json.getDouble("corner"), w / 2, h / 2).toFloat()
                val pad = blur * 2
                val (bitmap, canvas) = canvasBitmap(w + pad * 2, h + pad * 2)
                val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
                paint.color = argbColor(json.getDouble("r"), json.getDouble("g"), json.getDouble("b"), json.getDouble("a"))
                if (blur > 0) {
                    paint.maskFilter = android.graphics.BlurMaskFilter(
                        blur * scale, android.graphics.BlurMaskFilter.Blur.NORMAL)
                }
                val path = android.graphics.Path()
                path.addRoundRect(pad, pad, pad + w.toFloat(), pad + h.toFloat(), radius, radius, android.graphics.Path.Direction.CW)
                canvas.drawPath(path, paint)
                return pack(bitmap)
            }
            "image" -> {
                val src = json.getString("source")
                val remote = json.getBoolean("remote")
                val (state, _, _) = imageInfo(src, remote)
                val source = bitmapFor(src) ?: return ByteArray(0)
                if (state != 1) return ByteArray(0)
                val buffer = java.nio.ByteBuffer.allocate(8 + source.width * source.height * 4)
                    .order(java.nio.ByteOrder.LITTLE_ENDIAN)
                buffer.putInt(source.width)
                buffer.putInt(source.height)
                val copy = source.copy(Bitmap.Config.ARGB_8888, false) ?: return ByteArray(0)
                copy.copyPixelsToBuffer(buffer)
                copy.recycle()
                return buffer.array()
            }
        }
        return ByteArray(0)
    }
}
