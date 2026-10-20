package dev.swiftmap.runtime

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/** Fetches + decodes raster tiles on a small worker pool (platform APIs
 * only — no OkHttp/Glide, so the runtime adds no Maven dependencies). */
class TileFetcher {
    companion object {
        /** Tightly packed straight-alpha RGBA8 bytes (ARGB_8888 bitmaps
         * store their pixels in RGBA byte order). */
        fun rgbaBytes(bitmap: Bitmap): ByteArray {
            val buffer = ByteBuffer.allocate(bitmap.width * bitmap.height * 4)
            bitmap.copyPixelsToBuffer(buffer)
            return buffer.array()
        }
    }

    private val executor = Executors.newFixedThreadPool(4)

    fun fetch(key: String, url: String, callback: (Bitmap?) -> Unit) {
        executor.execute {
            var bitmap: Bitmap? = null
            try {
                val connection = URL(url).openConnection() as HttpURLConnection
                // tile.openstreetmap.org requires an identifying User-Agent
                // (https://operations.osmfoundation.org/policies/tiles/).
                connection.setRequestProperty(
                    "User-Agent",
                    "SwiftMap/0.1 (+https://github.com/AttilaTheFun/isomer)",
                )
                connection.connectTimeout = 15_000
                connection.readTimeout = 15_000
                connection.inputStream.use { bitmap = BitmapFactory.decodeStream(it) }
            } catch (_: Exception) {
                // fall through with bitmap == null
            }
            callback(bitmap)
        }
    }
}
