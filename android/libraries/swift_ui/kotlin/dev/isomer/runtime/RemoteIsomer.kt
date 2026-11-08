package dev.isomer.runtime

// Android's thin client for a remote session (shared/wire/session.proto): the
// app's SwiftUI runs on a server, built headless; the phone holds only the
// Compose renderer, the tree reader and a WebSocket (IsomerWebSockets). No
// Swift and no native library: what the person does goes to the server as a
// ClientMessage, each frame comes back as a tree.proto Patch.
//
//   setContent { IsomerRemote("ws://10.0.2.2:8090/session") }
//
// One session a process: the frames go to the interpreter's one tree
// (ComposeTreeState), as a WasmView's do. The system's back goes to the app,
// which can't answer whether it went back in time for the system to act: an
// app at its root stays.

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import java.io.ByteArrayOutputStream

/** session.proto's ClientMessage, written by hand as FlatTree reads tree.proto:
 *  field numbers MUST match session.proto's. */
object SessionMessages {
    private class Writer {
        val out = ByteArrayOutputStream()
        fun varint(value: Long) {
            var n = value
            while (n and 0x7fL.inv() != 0L) {
                out.write(((n and 0x7f) or 0x80).toInt())
                n = n ushr 7
            }
            out.write(n.toInt())
        }
        fun tag(field: Int, type: Int) = varint(((field shl 3) or type).toLong())
        fun uint(field: Int, value: Int) = apply { tag(field, 0); varint(value.toLong()) }
        fun bool(field: Int, value: Boolean) = apply { tag(field, 0); varint(if (value) 1 else 0) }
        fun double(field: Int, value: Double) = apply {
            tag(field, 1)
            val bits = java.lang.Double.doubleToRawLongBits(value)
            for (i in 0 until 8) out.write(((bits ushr (8 * i)) and 0xff).toInt())
        }
        fun bytes(field: Int, data: ByteArray) = apply { tag(field, 2); varint(data.size.toLong()); out.write(data) }
        fun string(field: Int, text: String) = bytes(field, text.toByteArray(Charsets.UTF_8))
        fun message(field: Int, sub: Writer) = bytes(field, sub.out.toByteArray())
        fun done(): ByteArray = out.toByteArray()
    }

    private fun size(width: Double, height: Double) = Writer().double(1, width).double(2, height)
    private fun event(id: String, value: String) = Writer().string(1, id).string(2, value)

    fun start(width: Double, height: Double, displayScale: Double, dark: Boolean, environment: Map<String, String>): ByteArray {
        val start = Writer().message(1, size(width, height)).double(2, displayScale).bool(3, dark)
        for ((key, value) in environment) start.message(4, Writer().string(1, key).string(2, value))
        start.string(5, "compose")
        return Writer().message(1, start).done()
    }
    fun resize(width: Double, height: Double) = Writer().message(2, size(width, height)).done()
    fun event(id: String, value: String, key: Boolean = false) = Writer().message(if (key) 4 else 3, event(id, value)).done()
    fun dark(dark: Boolean) = Writer().bool(8, dark).done()
    /** 0 active, 1 inactive, 2 background. */
    fun scenePhase(phase: Int) = Writer().uint(10, phase).done()
    fun back() = Writer().message(12, Writer()).done()
}

/** One session with a gateway: its socket, and the frames it brings into
 *  the interpreter's tree. */
class RemoteSession(private val url: String, private val environment: Map<String, String>) {
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    @Volatile private var socket = 0
    @Volatile private var closed = false
    /** What was sent before the socket opened, sent once it is. */
    private val waiting = mutableListOf<ByteArray>()

    var onCommand: (String, String) -> Unit = { _, _ -> }
    var onClosed: () -> Unit = {}

    fun open(start: ByteArray) {
        ComposeTreeState.clear()
        IsoEventRouter.sink = { id, value -> send(SessionMessages.event(id, value)) }
        // The app's answer comes too late to keep a key from its field.
        IsoEventRouter.keySink = { id, value -> send(SessionMessages.event(id, value, key = true)); false }
        IsomerWebSockets.open(url, emptyList(), emptyList(), 30.0) { result ->
            val id = result.getOrNull()
            if (id == null || closed) {
                if (id != null) IsomerWebSockets.close(id, 1000, "")
                main.post { onClosed() }
                return@open
            }
            IsomerWebSockets.sendData(id, start) {}
            synchronized(waiting) {
                socket = id
                for (message in waiting) IsomerWebSockets.sendData(id, message) {}
                waiting.clear()
            }
            receive(id)
        }
    }

    fun send(message: ByteArray) {
        synchronized(waiting) {
            if (socket == 0) waiting.add(message) else IsomerWebSockets.sendData(socket, message) {}
        }
    }

    fun close() {
        closed = true
        if (socket != 0) IsomerWebSockets.close(socket, 1000, "")
    }

    private fun receive(id: Int) {
        IsomerWebSockets.next(id) { result ->
            val event = result.getOrNull()
            if (event == null || event.kind == 2) {
                main.post { onClosed() }
                return@next
            }
            if (event.kind == 1) main.post { handle(event.data) }
            receive(id)
        }
    }

    /** A ServerMessage, on the main thread. */
    private fun handle(bytes: ByteArray) {
        val r = FlatTree.Reader(bytes, 0, bytes.size)
        while (!r.done()) {
            val (field, type) = r.tag()
            when {
                field == 1 && type == 2 -> {
                    val span = r.span()
                    ComposeTreeState.applyPatch(bytes.copyOfRange(span.first, span.last + 1))
                }
                field == 2 && type == 2 -> {
                    val sub = r.sub(r.span())
                    var key = ""
                    var value = ""
                    while (!sub.done()) {
                        val (f, t) = sub.tag()
                        when {
                            f == 1 && t == 2 -> key = sub.string()
                            f == 2 && t == 2 -> value = sub.string()
                            else -> sub.skip(t)
                        }
                    }
                    onCommand(key, value)
                }
                field == 3 && type == 2 -> {
                    val sub = r.sub(r.span())
                    var source = ""
                    var data = ByteArray(0)
                    while (!sub.done()) {
                        val (f, t) = sub.tag()
                        when {
                            f == 1 && t == 2 -> source = sub.string()
                            f == 2 && t == 2 -> sub.span().let { data = bytes.copyOfRange(it.first, it.last + 1) }
                            else -> sub.skip(t)
                        }
                    }
                    HostServices.registerImageBytes(source, data)
                }
                field == 4 && type == 2 -> HostServices.openUrl(r.string())
                field == 8 && type == 2 -> android.util.Log.i("Isomer", "[swiftui] ${r.string()}")
                else -> r.skip(type)
            }
        }
    }
}

/**
 * An app's SwiftUI on a server, drawn here: connects to `url` (a gateway's
 * /session) once the view has its size, and draws each frame with the
 * Compose renderer. `environment` is the app's launch environment (its ISO_
 * entries: `ISO_STORYBOOK_STORY`).
 */
@Composable
fun IsomerRemote(
    url: String,
    modifier: Modifier = Modifier,
    environment: Map<String, String> = emptyMap(),
    onCommand: (String, String) -> Unit = { _, _ -> },
) {
    val context = LocalContext.current
    val density = LocalDensity.current.density
    val dark = isSystemInDarkTheme()
    var size by remember { mutableStateOf(0 to 0) }
    HostServices.appContext = context.applicationContext
    HostServices.density = density
    HostServices.onImageLoaded = {
        android.os.Handler(android.os.Looper.getMainLooper()).post { ComposeTreeState.imageTick.value++ }
    }
    val session = remember(url, environment) { RemoteSession(url, environment) }
    session.onCommand = onCommand
    DisposableEffect(session) { onDispose { session.close() } }
    var started by remember(session) { mutableStateOf(false) }
    LaunchedEffect(session, size) {
        val (width, height) = size
        if (width == 0 || height == 0) return@LaunchedEffect
        if (!started) {
            started = true
            session.open(SessionMessages.start(width / density.toDouble(), height / density.toDouble(), density.toDouble(), dark, environment))
        } else {
            session.send(SessionMessages.resize(width / density.toDouble(), height / density.toDouble()))
        }
    }
    LaunchedEffect(session, dark) { if (started) session.send(SessionMessages.dark(dark)) }

    Box(modifier.fillMaxSize().onSizeChanged { size = it.width to it.height }) {
        @Suppress("UNUSED_VARIABLE") val tick = ComposeTreeState.imageTick.value
        val root = ComposeTreeState.tree.value
        val scheme = isoColorScheme(dark)
        MaterialGrounds.scheme = scheme
        MaterialGrounds.dark = dark
        MaterialTheme(colorScheme = scheme) {
            BackHandler { session.send(SessionMessages.back()) }
            Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                if (root != null) IsoRoot(root)
            }
        }
    }
}
