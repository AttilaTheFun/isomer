package dev.isomer.runtime

// The system pickers behind SwiftUI's `.fileImporter`, `.photosPicker` and
// `.cameraCapture` on Android: the document picker, the photo picker and
// the camera, registered on the activity at creation (activity-result
// launchers must be). What was picked is copied into the app's cache
// (cache/iso-import/<n>/<name>), where the guest's Foundation reads it, and
// the paths go back newline-separated ("" when cancelled). `.fileExporter`
// asks the other way: the system's "save to" picker, the document's bytes
// written where the person chose, its content: URI the answer.

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Base64
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResult
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import java.io.File
import kotlin.concurrent.thread

object MediaPickerHost {
    private var activity: ComponentActivity? = null
    private var files: ActivityResultLauncher<Array<String>>? = null
    private var file: ActivityResultLauncher<Array<String>>? = null
    private var photos: ActivityResultLauncher<PickVisualMediaRequest>? = null
    private var photo: ActivityResultLauncher<PickVisualMediaRequest>? = null
    private var camera: ActivityResultLauncher<Uri>? = null
    private var save: ActivityResultLauncher<Intent>? = null
    private var saving: ByteArray? = null
    private var pending: ((String) -> Unit)? = null
    private var cameraTarget: Uri? = null
    private var serial = 0
    private val main = Handler(Looper.getMainLooper())

    /** Registers the pickers on `activity` (call from onCreate). */
    fun attach(activity: ComponentActivity) {
        this.activity = activity
        files = activity.registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { deliver(it) }
        file = activity.registerForActivityResult(ActivityResultContracts.OpenDocument()) { deliver(listOfNotNull(it)) }
        photos = activity.registerForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(20)) { deliver(it) }
        photo = activity.registerForActivityResult(ActivityResultContracts.PickVisualMedia()) { deliver(listOfNotNull(it)) }
        camera = activity.registerForActivityResult(ActivityResultContracts.TakePicture()) { taken ->
            val target = cameraTarget
            cameraTarget = null
            deliver(if (taken && target != null) listOf(target) else emptyList(), removeAfter = target)
        }
        // Not CreateDocument: its MIME type is fixed when it is registered.
        save = activity.registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { saved(it) }
    }

    /** Saves a document where the person chooses: `name` suggested, `type`
     *  its MIME type, `data` its bytes in base64. Answers the content: URI it
     *  was written to, "" when cancelled or not written. */
    fun export(name: String, type: String, data: String, callback: (String) -> Unit) {
        main.post {
            if (pending != null) { callback(""); return@post }
            pending = callback
            try {
                saving = Base64.decode(data, Base64.DEFAULT)
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
                    .addCategory(Intent.CATEGORY_OPENABLE)
                    .setType(type.ifEmpty { "application/octet-stream" })
                    .putExtra(Intent.EXTRA_TITLE, name)
                save?.launch(intent) ?: saved(null)
            } catch (error: Exception) {
                android.util.Log.w("Isomer", "saving failed", error)
                saved(null)
            }
        }
    }

    private fun saved(result: ActivityResult?) {
        val callback = pending
        val bytes = saving
        pending = null
        saving = null
        val uri = result?.data?.data
        val resolver = activity?.contentResolver
        if (callback == null) return
        if (uri == null || bytes == null || resolver == null) { callback(""); return }
        thread(name = "iso-save") {
            val written = try {
                resolver.openOutputStream(uri, "wt")?.use { it.write(bytes) } != null
            } catch (error: Exception) {
                android.util.Log.w("Isomer", "writing a saved document failed", error); false
            }
            main.post { callback(if (written) uri.toString() else "") }
        }
    }

    /** Presents a picker: `kind` is "files", "photos" or "camera"; `accept`
     *  the MIME types, comma-separated (any type when empty). */
    fun request(kind: String, accept: String, multiple: Boolean, callback: (String) -> Unit) {
        main.post {
            if (pending != null) { callback(""); return@post }
            pending = callback
            val types = accept.split(",").map { it.trim() }.filter { it.isNotEmpty() }.ifEmpty { listOf("*/*") }
            try {
                when (kind) {
                    "files" -> if (multiple) files?.launch(types.toTypedArray()) else file?.launch(types.toTypedArray())
                    "photos" -> {
                        val only = when {
                            types.all { it.startsWith("image/") } -> ActivityResultContracts.PickVisualMedia.ImageOnly
                            types.all { it.startsWith("video/") } -> ActivityResultContracts.PickVisualMedia.VideoOnly
                            else -> ActivityResultContracts.PickVisualMedia.ImageAndVideo
                        }
                        val request = PickVisualMediaRequest.Builder().setMediaType(only).build()
                        if (multiple) photos?.launch(request) else photo?.launch(request)
                    }
                    "camera" -> {
                        val target = cameraUri()
                        if (target == null) { deliver(emptyList()); return@post }
                        cameraTarget = target
                        camera?.launch(target)
                    }
                    else -> deliver(emptyList())
                }
            } catch (error: Exception) {
                android.util.Log.w("Isomer", "picker failed", error)
                deliver(emptyList())
            }
        }
    }

    /** Where the camera writes: an entry of our own in the media store (no
     *  permission needed from Android 10), removed once copied. Not a
     *  pending one: the camera app can't open another app's pending entry. */
    private fun cameraUri(): Uri? {
        val resolver = activity?.contentResolver ?: return null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "photo-${System.currentTimeMillis()}.jpg")
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
        }
        return resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
    }

    private fun deliver(uris: List<Uri>, removeAfter: Uri? = null) {
        val callback = pending
        pending = null
        val activity = activity
        if (callback == null || activity == null || uris.isEmpty()) {
            removeAfter?.let { uri -> thread { runCatching { activity?.contentResolver?.delete(uri, null, null) } } }
            callback?.invoke("")
            return
        }
        thread(name = "iso-pick-copy") {
            val paths = uris.mapNotNull { uri ->
                try { copy(activity, uri) } catch (error: Exception) {
                    android.util.Log.w("Isomer", "copying a pick failed", error); null
                }
            }
            removeAfter?.let { runCatching { activity.contentResolver.delete(it, null, null) } }
            main.post { callback(paths.joinToString("\n")) }
        }
    }

    private fun copy(activity: ComponentActivity, uri: Uri): String? {
        val resolver = activity.contentResolver
        var name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        } ?: uri.lastPathSegment ?: "file"
        name = name.replace("/", "_")
        serial += 1
        val folder = File(activity.cacheDir, "iso-import/$serial").apply { mkdirs() }
        val out = File(folder, name)
        resolver.openInputStream(uri)?.use { input -> out.outputStream().use { input.copyTo(it) } } ?: return null
        return out.absolutePath
    }
}
