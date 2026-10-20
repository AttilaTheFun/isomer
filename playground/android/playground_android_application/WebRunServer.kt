// "Run on the web" on Android: a tiny in-app HTTP server (a ServerSocket on
// the loopback interface) serving the bundled playground site — the same
// index.html, react renderer and generic iso_hot host the iOS Playground
// serves — plus /app.wasm, the latest build, and the project's sandbox; the
// page is opened in a Chrome Custom Tab, Android's SFSafariViewController.
// The browser instantiates the reactor with its own WebAssembly engine and
// mounts it as real DOM through the react renderer.

package dev.isomer.runtime

import android.content.Context
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.zip.ZipInputStream
import kotlin.concurrent.thread

class WebRunServer(private val context: Context) {
    private val site = File(context.filesDir, "web_site")
    private var server: ServerSocket? = null
    @Volatile private var wasm: File? = null
    @Volatile private var sandbox: File? = null
    val port: Int get() = server?.localPort ?: 0

    val packaged: Boolean get() = try { context.assets.open("web_site.zip").close(); true } catch (_: Exception) { false }

    /** Publishes [build] as /app.wasm, starts the server if needed, returns the page's URL. */
    @Synchronized fun publish(build: File, projectSandbox: File?): String {
        unpackSite()
        wasm = build
        sandbox = projectSandbox
        if (server == null || server!!.isClosed) {
            // 127.0.0.1 by the numbers: the loopback address Java reports here
            // is ::1, which the page's URL does not name.
            val socket = ServerSocket(0, 8, InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)))
            server = socket
            thread(name = "playground-web", isDaemon = true) {
                while (!socket.isClosed) {
                    val client = try { socket.accept() } catch (_: Exception) { break }
                    thread(isDaemon = true) { serve(client) }
                }
            }
        }
        // (Logged for tests/e2e, which loads the page from the host.)
        android.util.Log.i("Playground", "[web-run] http://127.0.0.1:$port/index.html")
        return "http://127.0.0.1:$port/index.html"
    }

    fun open(url: String) {
        val intent = CustomTabsIntent.Builder().setShowTitle(false).build()
        intent.intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        intent.launchUrl(context, Uri.parse(url))
    }

    /** The site from assets/web_site.zip, once per installed build. */
    private fun unpackSite() {
        val marker = File(site, ".version")
        val version = context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime.toString()
        if (marker.exists() && marker.readText() == version) return
        site.deleteRecursively()
        site.mkdirs()
        ZipInputStream(context.assets.open("web_site.zip")).use { zip ->
            var entry = zip.nextEntry
            while (entry != null) {
                val target = File(site, entry.name)
                if (!target.canonicalPath.startsWith(site.canonicalPath)) throw IllegalStateException("bad path ${entry.name}")
                if (entry.isDirectory) target.mkdirs() else { target.parentFile?.mkdirs(); target.outputStream().use { zip.copyTo(it) } }
                entry = zip.nextEntry
            }
        }
        marker.writeText(version)
    }

    private fun serve(client: Socket) {
        client.use { socket ->
            val input = socket.getInputStream().bufferedReader()
            val request = input.readLine() ?: return
            while (true) { val line = input.readLine(); if (line.isNullOrEmpty()) break }
            val target = request.split(" ").getOrNull(1) ?: "/"
            val path = if (target == "/") "/index.html" else target.substringBefore("?")
            val output = socket.getOutputStream()
            fun respond(status: String, type: String, body: ByteArray) {
                output.write("HTTP/1.1 $status\r\nContent-Type: $type\r\nContent-Length: ${body.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".toByteArray())
                output.write(body)
                output.flush()
            }
            if (path.contains("..")) { respond("400 Bad Request", "text/plain", ByteArray(0)); return }
            if (path == "/app.wasm") {
                val build = wasm
                if (build == null || !build.exists()) respond("404 Not Found", "text/plain", "no build".toByteArray())
                else respond("200 OK", "application/wasm", build.readBytes())
                return
            }
            // The project sandbox (imported assets): /sandbox/<path>, and
            // /sandbox-list/<dir> as newline-separated names.
            if (path.startsWith("/sandbox/") || path.startsWith("/sandbox-list/")) {
                val listing = path.startsWith("/sandbox-list/")
                val relative = path.removePrefix(if (listing) "/sandbox-list/" else "/sandbox/")
                val root = sandbox
                if (root == null) { respond("404 Not Found", "text/plain", "no sandbox".toByteArray()); return }
                val file = File(root, relative)
                if (listing) {
                    val names = (file.list() ?: emptyArray()).sorted().joinToString("\n")
                    respond("200 OK", "text/plain; charset=utf-8", names.toByteArray())
                } else if (file.isFile) {
                    respond("200 OK", contentType(file.extension), file.readBytes())
                } else {
                    respond("404 Not Found", "text/plain", ByteArray(0))
                }
                return
            }
            val file = File(site, path.removePrefix("/"))
            if (file.isFile) respond("200 OK", contentType(file.extension), file.readBytes())
            else respond("404 Not Found", "text/plain", "not found".toByteArray())
        }
    }

    private fun contentType(extension: String): String = when (extension) {
        "html" -> "text/html; charset=utf-8"
        "js" -> "text/javascript; charset=utf-8"
        "wasm" -> "application/wasm"
        "css" -> "text/css"
        "json" -> "application/json"
        "png" -> "image/png"
        "jpg", "jpeg" -> "image/jpeg"
        "svg" -> "image/svg+xml"
        else -> "application/octet-stream"
    }
}
