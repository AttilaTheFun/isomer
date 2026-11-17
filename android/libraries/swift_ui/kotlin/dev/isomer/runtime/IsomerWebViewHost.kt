package dev.isomer.runtime

// An app in web-view mode on Android (docs/modes.md): its Swift runs as wasm
// in a page (an isomer_web_app site's webview.html, runtime/session_host.js),
// by the system WebView's V8 and its JIT, in a WebView this app owns and
// keeps out of sight; the app draws it with the Compose renderer
// (IsomerRemote) over the session protocol, as it draws an app on a server.
// This is the session's transport: the web view's message port instead of a
// socket. Kotlin only: no Swift and no native library in the app.
//
//   setContent { IsomerWebViewApp(site = "site") }
//
// - The site is in the APK's assets (assets/<site>/: isomer_application's
//   Android app in web-view mode puts it there), served from
//   https://appassets.androidplatform.net/<site>/ (the origin AndroidX's
//   WebViewAssetLoader reserves for an app's own files) by
//   shouldInterceptRequest: a secure context (ES modules, wasm streaming,
//   OffscreenCanvas, Cache Storage) and a stable origin, so what the page
//   keeps (the app's files, in IndexedDB) is there at the next launch.
// - The channel is a WebMessagePort (Android 6.0, API 23): once the page has
//   loaded, the app hands it one end of a message channel
//   (`postWebMessage("isomer", [port])`); the page answers `{"ready":true}`
//   on it, then each message either way is one session message's bytes as
//   base64 (`{"error":…}` if the app ends it).
// - The web view sits behind what the app draws, 1 × 1 dp and nearly
//   transparent, attached to the window: a WebView that isn't attached gets
//   no animation frames (session_host.js falls back to a timer, a frame
//   later).
//
// Why a WebView and not JavaScriptSandbox (androidx.javascriptengine, the
// same V8 without a view): the page measures and lays out text with a canvas
// (OffscreenCanvas) and keeps the app's files in IndexedDB, neither of which
// the sandbox has; nor has it ES modules or fetch, which the site's runtime
// is made of; and it is asynchronous only, with no gain over a port here.

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import android.webkit.ConsoleMessage
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebMessage
import android.webkit.WebMessagePort
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import java.io.ByteArrayInputStream
import java.io.IOException

/**
 * The web view an app in web-view mode runs in, and the session's channel to
 * it. One session at a time: each `open` loads the page afresh (a new guest,
 * whose first frame is its whole tree).
 *
 * `site` is the folder of the APK's assets holding the app's web site (its
 * webview.html, runtime/ and app.wasm); `pageQuery` more of the page's query
 * (webview.html's: `reactorCache` "0" compiles the reactor without the
 * page's Cache Storage, to compare).
 */
@SuppressLint("SetJavaScriptEnabled")
class IsomerWebViewHost(
    context: Context,
    private val site: String = "site",
    pageQuery: Map<String, String> = emptyMap(),
) {
    companion object {
        /** The site's origin: AndroidX's WebViewAssetLoader's, reserved for an
         *  app's own files. */
        const val ORIGIN = "https://appassets.androidplatform.net"
        private const val TAG = "Isomer"
    }

    /** The page's view: kept in the app's window, behind what it draws
     *  (IsomerWebViewApp). */
    val webView: WebView = WebView(context)
    /** The session over this web view, for IsomerRemote. */
    val channel: IsomerSessionChannel = Channel()

    private val assets = context.applicationContext.assets
    private val main = Handler(Looper.getMainLooper())
    private val page: String
    private val root = "/$site/"

    /** The open session's: its callbacks, its port, and what waits for the
     *  page to be ready (the start first). */
    private var onMessage: ((ByteArray) -> Unit)? = null
    private var onClosed: (() -> Unit)? = null
    private var port: WebMessagePort? = null
    private var ready = false
    private val waiting = ArrayList<String>()
    private var loadedAt = 0L
    private var firstMessage = true
    private var destroyed = false

    init {
        val info = context.applicationContext.applicationInfo
        if (info.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) WebView.setWebContentsDebuggingEnabled(true)
        val packageInfo = try {
            context.packageManager.getPackageInfo(context.packageName, 0)
        } catch (_: Exception) {
            null
        }
        @Suppress("DEPRECATION")
        val build = packageInfo?.let { if (Build.VERSION.SDK_INT >= 28) it.longVersionCode else it.versionCode.toLong() }
        val query = listOf(
            "bundleIdentifier" to context.packageName,
            "bundleName" to info.loadLabel(context.packageManager).toString(),
            "bundleVersion" to packageInfo?.versionName,
            "bundleBuild" to build?.toString(),
        ).filter { it.second != null }
            .plus(pageQuery.toList())
            .joinToString("&") { (name, value) -> "$name=${Uri.encode(value)}" }
        page = "$ORIGIN${root}webview.html?$query"

        webView.settings.apply {
            javaScriptEnabled = true
            // The page's localStorage (the files' journal, UserDefaults).
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
        }
        // It is never the person's to touch or type into.
        webView.isFocusable = false
        webView.isFocusableInTouchMode = false
        webView.importantForAccessibility = android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        webView.webViewClient = Client()
        webView.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(message: ConsoleMessage): Boolean {
                Log.i(TAG, "[page] ${message.message()}")
                return true
            }
        }
    }

    /** The web view's end, with the composable that showed it. */
    fun destroy() {
        if (destroyed) return
        end()
        destroyed = true
        webView.destroy()
    }

    private fun open(start: ByteArray, onMessage: (ByteArray) -> Unit, onClosed: () -> Unit) {
        if (destroyed) {
            onClosed()
            return
        }
        end()
        this.onMessage = onMessage
        this.onClosed = onClosed
        waiting.add(Base64.encodeToString(start, Base64.NO_WRAP))
        loadedAt = SystemClock.elapsedRealtime()
        firstMessage = true
        webView.loadUrl(page)
    }

    private fun send(bytes: ByteArray) {
        if (onClosed == null) return
        val message = Base64.encodeToString(bytes, Base64.NO_WRAP)
        val port = port
        if (ready && port != null) port.postMessage(WebMessage(message)) else waiting.add(message)
    }

    /** The head's end of the session: the guest's too. */
    private fun close() {
        if (onClosed == null) return
        end()
        if (!destroyed) webView.loadUrl("about:blank")
    }

    /** The session over: its port closed, its callbacks dropped; `closed` told
     *  when the app or the page ended it. */
    private fun end(failure: String? = null) {
        val closed = onClosed
        onMessage = null
        onClosed = null
        port?.close()
        port = null
        ready = false
        waiting.clear()
        if (failure != null) {
            Log.w(TAG, "[webview] the session ended: $failure")
            closed?.invoke()
        }
    }

    /** The page loaded: hand it its end of the session's message channel. */
    private fun connect() {
        if (onClosed == null || port != null) return
        val (ours, theirs) = webView.createWebMessageChannel()
        port = ours
        ours.setWebMessageCallback(object : WebMessagePort.WebMessageCallback() {
            override fun onMessage(source: WebMessagePort, message: WebMessage) {
                if (source !== port) return
                received(message.data ?: return)
            }
        }, main)
        webView.postWebMessage(WebMessage("isomer", arrayOf(theirs)), Uri.parse(ORIGIN))
    }

    private fun received(data: String) {
        if (data.startsWith("{")) {
            val message = try {
                org.json.JSONObject(data)
            } catch (_: Exception) {
                return
            }
            if (message.has("ready")) {
                Log.i(TAG, "[webview] page ready ${SystemClock.elapsedRealtime() - loadedAt} ms after its load began")
                ready = true
                for (queued in waiting) port?.postMessage(WebMessage(queued))
                waiting.clear()
            } else if (message.has("error")) {
                end("the app ended the session: ${message.optString("error")}")
            }
            return
        }
        if (firstMessage) {
            firstMessage = false
            Log.i(TAG, "[webview] the app's first message ${SystemClock.elapsedRealtime() - loadedAt} ms after the page's load began")
        }
        val bytes = try {
            Base64.decode(data, Base64.NO_WRAP)
        } catch (_: IllegalArgumentException) {
            return
        }
        onMessage?.invoke(bytes)
    }

    private inner class Channel : IsomerSessionChannel {
        override fun open(start: ByteArray, onMessage: (ByteArray) -> Unit, onClosed: () -> Unit) {
            main.post { this@IsomerWebViewHost.open(start, onMessage, onClosed) }
        }

        override fun send(message: ByteArray) {
            main.post { this@IsomerWebViewHost.send(message) }
        }

        override fun close() {
            main.post { this@IsomerWebViewHost.close() }
        }
    }

    private inner class Client : WebViewClient() {
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            val url = request.url
            if (url.scheme != "https" || url.host != Uri.parse(ORIGIN).host) return null
            return serve(url.path ?: "/")
        }

        override fun onPageFinished(view: WebView, url: String) {
            if (url.startsWith(ORIGIN + root)) connect()
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            if (request.isForMainFrame && onClosed != null) end("the page didn't load: ${error.description}")
        }

        /** The page's process went (its memory taken back, or a crash): the
         *  guest with it. The web view can't be used again; the app's next
         *  session is a new host's. */
        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            end("the web view's process ended")
            destroyed = true
            return true
        }
    }

    /** A file of the site, from the APK's assets, as a browser needs it: its
     *  type (JavaScript for a module, application/wasm for WebAssembly's
     *  streaming compile). Nothing outside the site is served. */
    private fun serve(path: String): WebResourceResponse {
        val segments = path.split('/').filter { it.isNotEmpty() }
        if (!path.startsWith(root) || segments.any { it == ".." || it == "." }) return missing()
        var name = segments.joinToString("/")
        if (path.endsWith("/")) name += "/index.html"
        return try {
            val stream = assets.open(name)
            WebResourceResponse(type(name), null, 200, "OK", mapOf(
                // The APK's files change only with the app.
                "Cache-Control" to "no-cache",
            ), stream)
        } catch (_: IOException) {
            missing()
        }
    }

    private fun missing() =
        WebResourceResponse("text/plain", "utf-8", 404, "Not Found", emptyMap(), ByteArrayInputStream(ByteArray(0)))

    private fun type(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
        "html", "htm" -> "text/html"
        "js", "mjs" -> "text/javascript"
        "wasm" -> "application/wasm"
        "json" -> "application/json"
        "css" -> "text/css"
        "png" -> "image/png"
        "jpg", "jpeg" -> "image/jpeg"
        "gif" -> "image/gif"
        "svg" -> "image/svg+xml"
        "webp" -> "image/webp"
        "ttf" -> "font/ttf"
        "otf" -> "font/otf"
        "woff" -> "font/woff"
        "woff2" -> "font/woff2"
        "txt" -> "text/plain"
        else -> "application/octet-stream"
    }
}

/**
 * A whole Isomer app in web-view mode (docs/modes.md), as a composable: its
 * Swift runs as wasm in a web view this keeps out of sight (the app's web
 * site, in the APK's assets under `site`), and the Compose renderer draws it
 * over the session protocol (IsomerRemote). `environment` is the app's
 * launch environment (its ISO_ entries: `ISO_STORYBOOK_STORY`), `pageQuery`
 * more of the page's query (IsomerWebViewHost).
 */
@Composable
fun IsomerWebViewApp(
    site: String = "site",
    modifier: Modifier = Modifier,
    environment: Map<String, String> = emptyMap(),
    pageQuery: Map<String, String> = emptyMap(),
    onCommand: (String, String) -> Unit = { _, _ -> },
) {
    val context = LocalContext.current
    val host = remember(site) { IsomerWebViewHost(context, site, pageQuery) }
    DisposableEffect(host) { onDispose { host.destroy() } }
    Box(modifier.fillMaxSize()) {
        AndroidView(factory = { host.webView }, modifier = Modifier.size(1.dp).alpha(0.01f))
        IsomerRemote(host.channel, Modifier.fillMaxSize(), environment, onCommand)
    }
}
