package dev.isomer.runtime

// Foundation's HTTP on Android: what `URLSession`'s data, upload and
// download tasks send through (IsomerNetworkHost's `HTTPHost`, Swift's
// shared/isomer_network_host/NetworkHost.swift). One exchange over the
// platform's HttpURLConnection, on threads of its own, made the way
// URLSession makes it on Apple's platforms: redirects followed (http to
// https and back included, which HttpURLConnection will not do itself),
// an error status answered like any other, the body whole and its content
// coding undone, and a failure to get any answer reported as the
// `NetworkTransportError.Reason` it is.
//
// Swift-free (no generated `SwiftUIBridge`), so both of Android's
// deliveries use it: the compiled one through NetworkHosts.kt, the wasm one
// (WasmView) through WasmNetworkHosts.kt.

import android.Manifest
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.system.ErrnoException
import android.system.OsConstants
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.MalformedURLException
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.GZIPInputStream
import java.util.zip.InflaterInputStream
import javax.net.ssl.SSLException
import org.json.JSONArray
import org.json.JSONException

/**
 * A failure to get any answer, as IsomerNetworkHost reads it: the message
 * starts with the reason (`NetworkTransportError.Reason`'s raw value) and a
 * colon, then says what happened ("timedOut: Read timed out").
 */
class NetworkHostException(val reason: String, detail: String) : IOException("$reason: $detail") {
    companion object {
        /** `error` as the reason it is, kept as it is when it already is one. */
        fun from(error: Throwable): NetworkHostException =
            error as? NetworkHostException
                ?: NetworkHostException(reasonFor(error), error.message ?: error.javaClass.simpleName)

        /**
         * The reason for what Android's stack threw. Its exceptions are
         * checked most specific first: a SocketTimeoutException is also an
         * InterruptedIOException, an SSLHandshakeException an IOException.
         */
        fun reasonFor(error: Throwable): String {
            if (error is NetworkHostException) return error.reason
            // Unreachable networks show as errno beneath the exception.
            val errno = generateSequence(error) { it.cause }.filterIsInstance<ErrnoException>().firstOrNull()?.errno
            if (errno == OsConstants.ENETUNREACH || errno == OsConstants.ENETDOWN) return "notConnectedToInternet"
            return when (error) {
                is SocketTimeoutException -> "timedOut"
                // Without a network a host's name doesn't resolve either:
                // tell the two apart where the app may ask (ACCESS_NETWORK_STATE).
                is UnknownHostException -> if (offline()) "notConnectedToInternet" else "cannotFindHost"
                is ConnectException, is NoRouteToHostException ->
                    if (offline()) "notConnectedToInternet" else "cannotConnectToHost"
                is SSLException -> "secureConnectionFailed"
                // HttpURLConnection's word for an answer cut short, or for
                // one that isn't HTTP; otherwise for a request it won't make.
                is java.net.ProtocolException -> when {
                    error.message?.contains("end of stream") == true -> "networkConnectionLost"
                    error.message?.contains("status line") == true -> "badServerResponse"
                    else -> "unknown"
                }
                is InterruptedIOException, is InterruptedException,
                is java.util.concurrent.CancellationException -> "cancelled"
                // The connection broke after it was made: reset, a pipe
                // broken, the stream ended early.
                is SocketException, is EOFException -> "networkConnectionLost"
                else -> "unknown"
            }
        }

        /** Whether the device has no network at all; false when it can't tell. */
        private fun offline(): Boolean {
            val context = HostServices.appContext ?: return false
            if (context.checkSelfPermission(Manifest.permission.ACCESS_NETWORK_STATE) !=
                PackageManager.PERMISSION_GRANTED) return false
            val manager = context.getSystemService(ConnectivityManager::class.java) ?: return false
            return try { manager.activeNetwork == null } catch (_: SecurityException) { false }
        }
    }
}

/** Header fields as the JSON IsomerNetworkHost passes: `[["name", "value"], …]`. */
object NetworkHeaders {
    fun parse(json: String): List<Pair<String, String>> = try {
        val array = JSONArray(json)
        (0 until array.length()).mapNotNull { index ->
            val pair = array.optJSONArray(index)
            if (pair != null && pair.length() == 2) pair.getString(0) to pair.getString(1) else null
        }
    } catch (_: JSONException) {
        emptyList()
    }

    fun json(fields: List<Pair<String, String>>): String =
        JSONArray().apply { for ((name, value) in fields) put(JSONArray().put(name).put(value)) }.toString()

    /** A JSON array of strings (the subprotocols a WebSocket offers). */
    fun strings(json: String): List<String> = try {
        val array = JSONArray(json)
        (0 until array.length()).map { array.getString(it) }
    } catch (_: JSONException) {
        emptyList()
    }
}

object IsomerHTTP {
    /** What an exchange received: `url` is where it ended, "" when no
     *  redirect led away from the request's own. */
    class Response(val status: Int, val headers: List<Pair<String, String>>, val body: ByteArray, val url: String)

    /** How many redirects one exchange follows (OkHttp's and Chrome's 20). */
    const val MAX_REDIRECTS = 20

    private val serial = AtomicInteger(1)

    // Exchanges block their thread (HttpURLConnection is blocking): a thread
    // each, kept a minute for the next.
    private val exchanges = Executors.newCachedThreadPool { work ->
        Thread(work, "isomer-http-${serial.getAndIncrement()}").apply { isDaemon = true }
    }

    /** Makes the exchange on a thread of its own and answers `done` there. */
    fun send(
        method: String, url: String, headers: List<Pair<String, String>>, body: ByteArray, timeout: Double,
        done: (Result<Response>) -> Unit,
    ) {
        exchanges.execute {
            val result = try {
                Result.success(exchange(method, url, headers, body, timeout))
            } catch (error: Throwable) {
                Result.failure(NetworkHostException.from(error))
            }
            done(result)
        }
    }

    /**
     * One exchange, blocking. `timeout` (seconds) bounds the connection and
     * each wait for more of the answer, as `URLRequest.timeoutInterval`
     * does; 0 or less waits as long as the server takes.
     */
    fun exchange(
        method: String, url: String, headers: List<Pair<String, String>>, body: ByteArray, timeout: Double,
    ): Response {
        var current = try { URL(url) } catch (_: MalformedURLException) {
            throw NetworkHostException("unknown", "not a URL: $url")
        }
        var verb = method.ifEmpty { "GET" }
        var fields = headers
        var payload = body
        val millis = if (timeout.isFinite() && timeout > 0) (timeout * 1000).toLong().coerceIn(1, Int.MAX_VALUE.toLong()).toInt() else 0
        var redirects = 0
        while (true) {
            val connection = current.openConnection() as HttpURLConnection
            connection.connectTimeout = millis
            connection.readTimeout = millis
            // Followed below: HttpURLConnection never follows a redirect to
            // another scheme, and URLSession does.
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.requestMethod = verb
            val named = HashSet<String>()
            for ((name, value) in fields) {
                // The length is the body's, set below.
                if (name.equals("Content-Length", ignoreCase = true)) continue
                if (named.add(name.lowercase())) connection.setRequestProperty(name, value)
                else connection.addRequestProperty(name, value)
            }
            // A GET or HEAD sends no body (HttpURLConnection would turn the
            // request into a POST to send one).
            val sends = payload.isNotEmpty() && verb != "GET" && verb != "HEAD"
            if (sends) {
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(payload.size)
                connection.outputStream.use { it.write(payload) }
            }
            val status = connection.responseCode
            if (status == -1) throw NetworkHostException("badServerResponse", "the answer from $current is not HTTP")
            val location = connection.getHeaderField("Location")
            val next = if (status in REDIRECTS && location != null) {
                try { URL(current, location) } catch (_: MalformedURLException) { null }
            } else {
                null
            }
            if (next != null && (next.protocol == "http" || next.protocol == "https")) {
                if (++redirects > MAX_REDIRECTS) {
                    connection.disconnect()
                    throw NetworkHostException("unknown", "more than $MAX_REDIRECTS redirects from $url")
                }
                // Read to the end, so the connection can carry the next request.
                try { read(connection, status) } catch (_: IOException) { connection.disconnect() }
                // A 303, and a 301 or 302 answering a POST, become a GET with
                // no body, as browsers and URLSession make them; 307 and 308
                // repeat the request as it was.
                if ((status == 303 && verb != "HEAD") || ((status == 301 || status == 302) && verb == "POST")) {
                    verb = "GET"
                    payload = ByteArray(0)
                    fields = fields.filterNot { (name, _) -> name.lowercase() in BODY_FIELDS }
                }
                // Credentials stay with the host they were meant for.
                if (!next.host.equals(current.host, ignoreCase = true)) {
                    fields = fields.filterNot { (name, _) -> name.equals("Authorization", ignoreCase = true) }
                }
                current = next
                continue
            }
            val answer = fields(connection)
            val raw = read(connection, status)
            return Response(status, answer, decoded(raw, answer), if (redirects > 0) current.toString() else "")
        }
    }

    private val REDIRECTS = setOf(301, 302, 303, 307, 308)

    /** What describes a body, dropped with it when a redirect turns the request into a GET. */
    private val BODY_FIELDS = setOf("content-type", "content-encoding", "content-language", "content-location")

    /** The answer's header fields in the order they came, each repeat its own pair. */
    private fun fields(connection: HttpURLConnection): List<Pair<String, String>> {
        val fields = ArrayList<Pair<String, String>>()
        var index = 0
        while (true) {
            val value = connection.getHeaderField(index) ?: break
            val name = connection.getHeaderFieldKey(index)
            index++
            // Index 0 is the status line (no name); Android's stack adds
            // fields of its own (X-Android-Sent-Millis…) the server never sent.
            if (name == null || name.startsWith("X-Android-", ignoreCase = true)) continue
            fields.add(name to value)
        }
        return fields
    }

    /** The whole body: an error status's through `errorStream`. */
    private fun read(connection: HttpURLConnection, status: Int): ByteArray {
        val stream: InputStream? = if (status >= 400) connection.errorStream else connection.inputStream
        return stream?.use { it.readBytes() } ?: ByteArray(0)
    }

    /**
     * The body with its content coding undone. HttpURLConnection undoes
     * gzip itself (and drops the field) when it asked for it; a request
     * that named its own Accept-Encoding gets the coded body, undone here.
     */
    private fun decoded(body: ByteArray, fields: List<Pair<String, String>>): ByteArray {
        if (body.isEmpty()) return body
        val coding = fields.lastOrNull { it.first.equals("Content-Encoding", ignoreCase = true) }
            ?.second?.trim()?.lowercase() ?: return body
        val stream = when (coding) {
            "gzip", "x-gzip" -> GZIPInputStream(body.inputStream())
            "deflate" -> InflaterInputStream(body.inputStream())
            else -> return body
        }
        return try {
            stream.use { it.readBytes() }
        } catch (error: IOException) {
            throw NetworkHostException("unknown", "cannot decode the $coding body: ${error.message}")
        }
    }
}
