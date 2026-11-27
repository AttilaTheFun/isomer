package dev.isomer.runtime

// The app's window as it is on screen, a PNG, for the Isomer module's
// `IsomerScreenshot.capture()`: PixelCopy of the window from Android 8 (what
// the display composited, Compose's hardware layers and video included),
// the decor view drawn into a bitmap below it. Encoded off the main thread.

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import java.io.ByteArrayOutputStream
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

internal object ScreenCapture {
    /** The PNG's bytes, or empty when there is no window to take. */
    suspend fun capture(activity: Activity?): ByteArray {
        val bitmap = suspendCoroutine<Bitmap?> { done ->
            val main = Handler(Looper.getMainLooper())
            main.post { take(activity, main) { done.resume(it) } }
        } ?: return ByteArray(0)
        return suspendCoroutine { done ->
            Thread {
                val png = ByteArrayOutputStream()
                val encoded = bitmap.compress(Bitmap.CompressFormat.PNG, 100, png)
                bitmap.recycle()
                done.resume(if (encoded) png.toByteArray() else ByteArray(0))
            }.start()
        }
    }

    /** On the main thread: the window's pixels, to [taken]. */
    private fun take(activity: Activity?, main: Handler, taken: (Bitmap?) -> Unit) {
        val window = activity?.window
        val decor = window?.peekDecorView()
        if (window == null || decor == null || decor.width == 0 || decor.height == 0) return taken(null)
        val bitmap = Bitmap.createBitmap(decor.width, decor.height, Bitmap.Config.ARGB_8888)
        if (Build.VERSION.SDK_INT >= 26) {
            PixelCopy.request(window, bitmap, { result ->
                if (result == PixelCopy.SUCCESS) taken(bitmap) else { bitmap.recycle(); taken(null) }
            }, main)
        } else {
            decor.draw(Canvas(bitmap))
            taken(bitmap)
        }
    }
}
