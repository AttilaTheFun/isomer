package dev.isomer.runtime

// The platform image chooser behind the `ImagePickerService` platform
// service: the system content picker (GetContent, image/*), registered on
// the activity at creation (activity-result launchers must be registered
// before the activity starts), decoded and scaled to `maxDimension`, and
// written as a JPEG into the cache dir and returned as a file:// URL.

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import java.io.ByteArrayOutputStream
import kotlin.concurrent.thread

object ImagePickerHost {
    private var launcher: ActivityResultLauncher<String>? = null
    private var activity: ComponentActivity? = null
    private var pending: ((String) -> Unit)? = null
    private var maxDimension = 1280
    private val main = Handler(Looper.getMainLooper())

    /** Registers the picker on `activity` (call from onCreate). */
    fun attach(activity: ComponentActivity) {
        this.activity = activity
        launcher = activity.registerForActivityResult(ActivityResultContracts.GetContent()) { uri ->
            val callback = pending
            pending = null
            if (uri == null) { callback?.invoke(""); return@registerForActivityResult }
            val max = maxDimension
            thread(name = "iso-image-pick") {
                val url = try { dataURL(uri, max) } catch (error: Exception) {
                    android.util.Log.w("Isomer", "image pick failed", error); ""
                }
                main.post { callback?.invoke(url) }
            }
        }
    }

    /** Presents the chooser; `callback` (main thread) gets the data URL or "". */
    fun pick(maxDimension: Int, callback: (String) -> Unit) {
        main.post {
            val launcher = launcher
            if (launcher == null || pending != null) { callback(""); return@post }
            pending = callback
            this.maxDimension = maxDimension
            launcher.launch("image/*")
        }
    }

    private fun dataURL(uri: Uri, maxDimension: Int): String {
        val resolver = activity?.contentResolver ?: return ""
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxDimension) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) } ?: return ""
        val longest = maxOf(decoded.width, decoded.height)
        val scale = minOf(1.0, maxDimension.toDouble() / maxOf(1, longest))
        val bitmap = if (scale < 1.0) Bitmap.createScaledBitmap(
            decoded, maxOf(1, (decoded.width * scale).toInt()), maxOf(1, (decoded.height * scale).toInt()), true) else decoded
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
        val folder = java.io.File(activity?.cacheDir ?: return "", "iso-picked").apply { mkdirs() }
        val file = java.io.File(folder, java.util.UUID.randomUUID().toString() + ".jpg")
        file.writeBytes(out.toByteArray())
        return "file://" + file.absolutePath
    }
}
