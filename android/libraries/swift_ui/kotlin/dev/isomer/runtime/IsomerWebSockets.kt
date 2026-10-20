package dev.isomer.runtime

// Foundation's WebSockets on Android: what `URLSessionWebSocketTask` opens
// (IsomerNetworkHost's `WebSocketHost`). Android has no WebSocket client of
// its own and isomer adds no library for one, so this is an RFC 6455 client
// over a Socket (an SSLSocket for wss): the opening handshake with the
// subprotocols offered and the app's header fields, masked frames out, text
// and binary messages in (fragmented ones put together), pings answered,
// the closing handshake either way. Each connection has a thread reading
// it and one writing it; what arrives waits in the connection's queue until
// `next` takes it.
//
// Closing. The app's close (`close`) is the connection's end at once: what
// had arrived can still be taken, then `next` answers the close (the app's
// code and reason) to every call, and a `next` already waiting answers it
// then. The close frame goes out; the server's answer ends the socket (or,
// after five seconds without one, the client does). A close the server
// starts is answered with its code and is the connection's end, as it said
// it. A connection that breaks without a close answers one `next` with the
// error (`networkConnectionLost: …`), then a close with code 1006.
//
// Swift-free, like IsomerHTTP: both deliveries use it.

import android.security.NetworkSecurityPolicy
import android.util.Base64
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.net.URISyntaxException
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

object IsomerWebSockets {
    /** What a connection received: `kind` 0 text, 1 data, 2 closed (then
     *  `code`, and the reason in `text`). */
    class Event(val kind: Int, val text: String = "", val data: ByteArray = ByteArray(0), val code: Int = 0) {
        companion object {
            fun closed(code: Int, reason: String) = Event(2, text = reason, code = code)
        }
    }

    /** The largest message taken, in bytes; a larger one fails the connection
     *  (1009). Foundation's own limit (`maximumMessageSize`, 1 MiB unless an
     *  app raises it) applies after this one. */
    const val MAX_MESSAGE = 64 * 1024 * 1024

    /** How long a close the client started waits for the server's answer. */
    private const val CLOSE_WAIT_SECONDS = 5L

    private val connections = ConcurrentHashMap<Int, Connection>()
    private val ids = AtomicInteger(1)
    private val random = SecureRandom()

    /** The ends of the last connections that are gone, for a `next` that asks again. */
    private val gone = object : LinkedHashMap<Int, Event>() {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Int, Event>?) = size > 64
    }

    private val timers = Executors.newSingleThreadScheduledExecutor { work ->
        Thread(work, "isomer-websocket-timer").apply { isDaemon = true }
    }

    /**
     * Opens a connection and answers `done` with its id once the opening
     * handshake is done (on the connection's thread), or with why it could
     * not open. `timeout` (seconds) bounds the connection and the handshake.
     */
    fun open(
        url: String, protocols: List<String>, headers: List<Pair<String, String>>, timeout: Double,
        done: (Result<Int>) -> Unit,
    ) {
        val connection = Connection(ids.getAndIncrement())
        connections[connection.id] = connection
        Thread({
            try {
                connection.handshake(url, protocols, headers, timeout)
            } catch (error: Throwable) {
                connections.remove(connection.id)
                connection.closeSocket()
                connection.writer.shutdown()
                done(Result.failure(NetworkHostException.from(error)))
                return@Thread
            }
            done(Result.success(connection.id))
            connection.read()
        }, "isomer-websocket-${connection.id}").apply { isDaemon = true }.start()
    }

    /** The subprotocol the server chose; "" for none. */
    fun subprotocol(id: Int): String = connections[id]?.subprotocol ?: ""

    fun sendText(id: Int, text: String, done: (Result<Unit>) -> Unit) =
        send(id, 0x1, text.toByteArray(Charsets.UTF_8), done)

    fun sendData(id: Int, data: ByteArray, done: (Result<Unit>) -> Unit) = send(id, 0x2, data, done)

    private fun send(id: Int, opcode: Int, payload: ByteArray, done: (Result<Unit>) -> Unit) {
        val connection = connections[id]
        if (connection == null || connection.closing) {
            done(Result.failure(NetworkHostException("networkConnectionLost", "the WebSocket is closed")))
            return
        }
        connection.write(frame(opcode, payload), done)
    }

    /** The next message, or the close; answers `done` at once when one
     *  waits, else when one arrives. */
    fun next(id: Int, done: (Result<Event>) -> Unit) {
        val connection = connections[id]
        if (connection == null) {
            done(Result.success(synchronized(gone) { gone[id] } ?: Event.closed(1006, "")))
            return
        }
        connection.take(done)
    }

    /** Starts the closing handshake with `code` and `reason` (UTF-8, cut to 123 bytes). */
    fun close(id: Int, code: Int, reason: String) {
        connections[id]?.close(code, reason)
    }

    // MARK: Frames

    /** Close codes a close frame may carry (RFC 6455 7.4). */
    private fun sendable(code: Int) = code in 1000..4999 && code != 1004 && code != 1005 && code != 1006 && code != 1015

    private fun closePayload(code: Int, reason: String): ByteArray {
        if (!sendable(code)) return ByteArray(0)
        var bytes = reason.toByteArray(Charsets.UTF_8)
        if (bytes.size > 123) {
            // Cut at a character's start, not inside one.
            var end = 123
            while (end > 0 && (bytes[end].toInt() and 0xC0) == 0x80) end--
            bytes = bytes.copyOf(end)
        }
        return byteArrayOf((code shr 8).toByte(), code.toByte()) + bytes
    }

    /** A whole client frame, masked as a client's must be. */
    private fun frame(opcode: Int, payload: ByteArray): ByteArray {
        val length = payload.size
        val extended = if (length < 126) 0 else if (length < 65536) 2 else 8
        val out = ByteArray(2 + extended + 4 + length)
        out[0] = (0x80 or opcode).toByte()
        var at = 2
        when (extended) {
            0 -> out[1] = (0x80 or length).toByte()
            2 -> {
                out[1] = (0x80 or 126).toByte()
                out[2] = (length shr 8).toByte()
                out[3] = length.toByte()
                at = 4
            }
            else -> {
                out[1] = (0x80 or 127).toByte()
                for (index in 0 until 8) out[2 + index] = (length.toLong() shr (56 - 8 * index)).toByte()
                at = 10
            }
        }
        val mask = ByteArray(4).also { random.nextBytes(it) }
        System.arraycopy(mask, 0, out, at, 4)
        at += 4
        for (index in 0 until length) out[at + index] = (payload[index].toInt() xor mask[index and 3].toInt()).toByte()
        return out
    }

    /** The server broke the protocol: the connection fails with `code`. */
    private class ProtocolViolation(val code: Int, message: String) : Exception(message)

    // MARK: A connection

    private class Connection(val id: Int) {
        @Volatile var socket: Socket? = null
        @Volatile var subprotocol = ""
        private lateinit var input: DataInputStream
        private lateinit var output: OutputStream

        // Frames go out whole, in the order they were asked for.
        val writer: ExecutorService = Executors.newSingleThreadExecutor { work ->
            Thread(work, "isomer-websocket-$id-send").apply { isDaemon = true }
        }

        // Under `this`: what arrived and waits for `next` (messages, then the
        // close or the failure), the `next`s waiting for it, and the close
        // every `next` after those answers.
        private val arrived = ArrayDeque<Result<Event>>()
        private val waiting = ArrayDeque<(Result<Event>) -> Unit>()
        private var ended: Event? = null
        private var closeSent = false
        private var socketDone = false

        /** Whether the connection's end is known: nothing more is taken or sent. */
        val closing: Boolean get() = synchronized(this) { ended != null }

        fun handshake(url: String, protocols: List<String>, headers: List<Pair<String, String>>, timeout: Double) {
            val uri = try { URI(url) } catch (_: URISyntaxException) {
                throw NetworkHostException("unknown", "not a URL: $url")
            }
            val secure = when (uri.scheme?.lowercase()) {
                "wss", "https" -> true
                "ws", "http" -> false
                else -> throw NetworkHostException("unknown", "not a WebSocket URL: $url")
            }
            val host = uri.host ?: throw NetworkHostException("unknown", "no host in $url")
            val bare = host.removePrefix("[").removeSuffix("]")
            val port = if (uri.port > 0) uri.port else if (secure) 443 else 80
            // The app's network security policy, as HttpURLConnection keeps it
            // for http (and Apple's App Transport Security for ws).
            if (!secure && !NetworkSecurityPolicy.getInstance().isCleartextTrafficPermitted(bare)) {
                throw NetworkHostException(
                    "unknown", "CLEARTEXT communication to $bare not permitted by network security policy")
            }
            val millis = if (timeout.isFinite() && timeout > 0) (timeout * 1000).toLong().coerceIn(1, Int.MAX_VALUE.toLong()).toInt() else 0

            val plain = Socket()
            socket = plain
            plain.connect(InetSocketAddress(bare, port), millis)
            plain.soTimeout = millis
            plain.tcpNoDelay = true
            plain.keepAlive = true
            val connected = if (secure) {
                // Over the connected socket, so the timeout bounds the
                // connection; the host's name is the one TLS asks for (SNI)
                // and the one the certificate must have.
                val tls = (SSLSocketFactory.getDefault() as SSLSocketFactory)
                    .createSocket(plain, bare, port, true) as SSLSocket
                socket = tls
                tls.startHandshake()
                if (!HttpsURLConnection.getDefaultHostnameVerifier().verify(bare, tls.session)) {
                    throw NetworkHostException("secureConnectionFailed", "the server's certificate is not for $bare")
                }
                tls
            } else {
                plain
            }
            output = BufferedOutputStream(connected.getOutputStream())
            input = DataInputStream(BufferedInputStream(connected.getInputStream()))

            val key = Base64.encodeToString(ByteArray(16).also { random.nextBytes(it) }, Base64.NO_WRAP)
            val path = (uri.rawPath?.ifEmpty { null } ?: "/") + (uri.rawQuery?.let { "?$it" } ?: "")
            val authority = if (port == (if (secure) 443 else 80)) host else "$host:$port"
            val request = StringBuilder()
                .append("GET $path HTTP/1.1\r\n")
                .append("Host: $authority\r\n")
                .append("Upgrade: websocket\r\n")
                .append("Connection: Upgrade\r\n")
                .append("Sec-WebSocket-Key: $key\r\n")
                .append("Sec-WebSocket-Version: 13\r\n")
            if (protocols.isNotEmpty()) request.append("Sec-WebSocket-Protocol: ${protocols.joinToString(", ")}\r\n")
            for ((name, value) in headers) {
                // The handshake's own fields are the client's to write; no
                // extension is offered (none is spoken here).
                if (name.lowercase() in HANDSHAKE_FIELDS) continue
                if (name.any { it == '\r' || it == '\n' || it == ':' } || value.any { it == '\r' || it == '\n' }) continue
                request.append("$name: $value\r\n")
            }
            request.append("\r\n")
            output.write(request.toString().toByteArray(Charsets.UTF_8))
            output.flush()

            val head = readHead()
            val statusLine = head.firstOrNull().orEmpty()
            if (statusLine.split(' ').getOrNull(1) != "101") {
                throw NetworkHostException(
                    "badServerResponse", "the server answered the WebSocket handshake with \"$statusLine\"")
            }
            val fields = HashMap<String, String>()
            for (line in head.drop(1)) {
                val colon = line.indexOf(':')
                if (colon <= 0) continue
                val name = line.substring(0, colon).trim().lowercase()
                val value = line.substring(colon + 1).trim()
                fields[name] = fields[name]?.let { "$it, $value" } ?: value
            }
            if (!fields["upgrade"].equals("websocket", ignoreCase = true)) {
                throw NetworkHostException("badServerResponse", "the server's handshake does not upgrade to a WebSocket")
            }
            val accept = Base64.encodeToString(
                MessageDigest.getInstance("SHA-1").digest((key + ACCEPT_GUID).toByteArray(Charsets.US_ASCII)),
                Base64.NO_WRAP)
            if (fields["sec-websocket-accept"] != accept) {
                throw NetworkHostException("badServerResponse", "the server's Sec-WebSocket-Accept is not this handshake's")
            }
            val chosen = fields["sec-websocket-protocol"].orEmpty()
            if (chosen.isNotEmpty() && chosen !in protocols) {
                throw NetworkHostException("badServerResponse", "the server chose a subprotocol not offered: $chosen")
            }
            if (fields["sec-websocket-extensions"] != null) {
                throw NetworkHostException("badServerResponse", "the server named extensions none were offered")
            }
            subprotocol = chosen
            // Open: a connection waits for messages as long as they take.
            connected.soTimeout = 0
        }

        /** The handshake's answer up to its blank line, as lines. */
        private fun readHead(): List<String> {
            val bytes = ByteArrayOutputStream()
            var last = 0
            while (true) {
                val byte = input.read()
                if (byte < 0) throw EOFException("the server ended the connection during the handshake")
                bytes.write(byte)
                last = (last shl 8) or byte
                if (last == 0x0D0A0D0A) break
                if (bytes.size() > 65536) throw NetworkHostException("badServerResponse", "the handshake's answer has no end")
            }
            return bytes.toString("ISO-8859-1").split("\r\n").filter { it.isNotEmpty() }
        }

        /** Reads frames until the connection ends (the connection's thread). */
        fun read() {
            var kind = 0 // the opcode of the message being put together; 0 for none
            val message = ByteArrayOutputStream()
            try {
                while (true) {
                    val first = input.read()
                    if (first < 0) throw EOFException("the server ended the connection without closing it")
                    val fin = first and 0x80 != 0
                    val opcode = first and 0x0F
                    val second = input.readUnsignedByte()
                    var length = (second and 0x7F).toLong()
                    if (length == 126L) length = input.readUnsignedShort().toLong()
                    else if (length == 127L) length = input.readLong()
                    if (length < 0 || length > MAX_MESSAGE || message.size() + length > MAX_MESSAGE) {
                        throw ProtocolViolation(1009, "a message larger than $MAX_MESSAGE bytes")
                    }
                    // A server's frames are not masked; one that is is read all the same.
                    val mask = if (second and 0x80 != 0) ByteArray(4).also { input.readFully(it) } else null
                    val payload = ByteArray(length.toInt()).also { input.readFully(it) }
                    if (mask != null) {
                        for (index in payload.indices) payload[index] = (payload[index].toInt() xor mask[index and 3].toInt()).toByte()
                    }
                    when (opcode) {
                        0x0, 0x1, 0x2 -> {
                            if (opcode == 0x0 && kind == 0) throw ProtocolViolation(1002, "a continuation of no message")
                            if (opcode != 0x0 && kind != 0) throw ProtocolViolation(1002, "a message begun inside another")
                            if (opcode != 0x0) kind = opcode
                            message.write(payload)
                            if (fin) {
                                val bytes = message.toByteArray()
                                message.reset()
                                arrive(if (kind == 0x1) Event(0, text = String(bytes, Charsets.UTF_8)) else Event(1, data = bytes))
                                kind = 0
                            }
                        }
                        0x8 -> {
                            val code = if (payload.size >= 2) ((payload[0].toInt() and 0xFF) shl 8) or (payload[1].toInt() and 0xFF) else 1005
                            val reason = if (payload.size > 2) String(payload, 2, payload.size - 2, Charsets.UTF_8) else ""
                            closedByServer(code, reason)
                            return
                        }
                        0x9 -> write(frame(0xA, payload), null)
                        0xA -> {}
                        else -> throw ProtocolViolation(1002, "a frame of unknown kind $opcode")
                    }
                }
            } catch (violation: ProtocolViolation) {
                // Said to the server, then the connection fails.
                try { sendClose(violation.code, "")?.get(1, TimeUnit.SECONDS) } catch (_: Exception) {}
                finish(
                    Result.failure(NetworkHostException("badServerResponse", violation.message ?: "")),
                    Event.closed(1006, ""))
            } catch (error: Throwable) {
                // After the connection's end (the app's close shutting the
                // socket) a broken read is how it ends; before, it is lost.
                finish(Result.failure(NetworkHostException.from(error)), Event.closed(1006, ""))
            } finally {
                closeSocket()
                writer.shutdown()
                synchronized(this) { socketDone = true }
                retireIfDone()
            }
        }

        /** The server's close: answered with its code (unless it answers
         *  the client's), the connection's end as the server said it. */
        private fun closedByServer(code: Int, reason: String) {
            finish(Result.success(Event.closed(code, reason)), Event.closed(code, reason))
            // Wait for the answer to go out before the socket is shut.
            try { sendClose(code, "")?.get(1, TimeUnit.SECONDS) } catch (_: Exception) {}
        }

        /** The app's close: the connection's end at once; the server's
         *  answer (or the wait for it running out) ends the socket. */
        fun close(code: Int, reason: String) {
            finish(Result.success(Event.closed(if (sendable(code)) code else 1005, reason)), null)
            if (sendClose(code, reason) != null) {
                timers.schedule({ closeSocket() }, CLOSE_WAIT_SECONDS, TimeUnit.SECONDS)
            }
        }

        /** Sends the close frame unless one went out; the write's future, or null. */
        private fun sendClose(code: Int, reason: String): java.util.concurrent.Future<*>? {
            val first = synchronized(this) { !closeSent.also { closeSent = true } }
            if (!first) return null
            val bytes = frame(0x8, closePayload(code, reason))
            return try {
                writer.submit {
                    try {
                        output.write(bytes)
                        output.flush()
                    } catch (_: Exception) {
                    }
                }
            } catch (_: RejectedExecutionException) {
                null
            }
        }

        fun write(bytes: ByteArray, done: ((Result<Unit>) -> Unit)?) {
            try {
                writer.execute {
                    val result = try {
                        output.write(bytes)
                        output.flush()
                        Result.success(Unit)
                    } catch (error: Exception) {
                        Result.failure(NetworkHostException.from(error))
                    }
                    done?.invoke(result)
                }
            } catch (_: RejectedExecutionException) {
                done?.invoke(Result.failure(NetworkHostException("networkConnectionLost", "the WebSocket is closed")))
            }
        }

        fun closeSocket() {
            try { socket?.close() } catch (_: Exception) {}
        }

        /** A message, for the `next` waiting or the queue; none after the end. */
        private fun arrive(event: Event) {
            val waiter = synchronized(this) {
                if (ended != null) return
                waiting.removeFirstOrNull() ?: run {
                    arrived.addLast(Result.success(event))
                    null
                }
            } ?: return
            waiter(Result.success(event))
        }

        /**
         * The connection's end, once: `result` is what the next `next` takes
         * after what already arrived (the close, or the failure), `after`
         * what every one after that answers (the close itself when null).
         */
        private fun finish(result: Result<Event>, after: Event?) {
            val waiters = synchronized(this) {
                if (ended != null) return
                ended = after ?: result.getOrThrow()
                if (waiting.isEmpty()) {
                    arrived.addLast(result)
                    return
                }
                waiting.toList().also { waiting.clear() }
            }
            waiters.first()(result)
            val repeated = Result.success(after ?: result.getOrThrow())
            for (waiter in waiters.drop(1)) waiter(repeated)
        }

        fun take(done: (Result<Event>) -> Unit) {
            val answer = synchronized(this) {
                arrived.removeFirstOrNull() ?: ended?.let { Result.success(it) } ?: run {
                    waiting.addLast(done)
                    null
                }
            } ?: return
            done(answer)
            retireIfDone()
        }

        /** Gone from the open connections once the socket is shut and its end taken. */
        private fun retireIfDone() {
            val end = synchronized(this) { if (socketDone && arrived.isEmpty()) ended else null } ?: return
            if (connections.remove(id, this)) synchronized(gone) { gone[id] = end }
        }
    }

    private val HANDSHAKE_FIELDS = setOf(
        "host", "upgrade", "connection", "sec-websocket-key", "sec-websocket-version",
        "sec-websocket-protocol", "sec-websocket-extensions", "content-length",
    )

    private const val ACCEPT_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
}
