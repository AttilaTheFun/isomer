package dev.isomer.runtime

// Foundation's networking in the compiled delivery: IsomerHTTP and
// IsomerWebSockets as the swift_ffi interfaces IsomerNetworkHost declares
// (`HTTPHost`, `WebSocketHost`, generated into SwiftUIBridge), handed to
// Swift through `installIsomerNetworkHosts` before the runtime starts
// (IsomerRuntime.prepare). An app that injects its own under
// `NetworkHostKey`'s keys (its services installer runs before the runtime
// starts too) has those instead: nativeStart installs what was injected
// over these.
//
// The generated dispatcher starts each `suspend` method on the thread Swift
// called from (the runtime's) and answers Swift when it returns; the work
// itself is on IsomerHTTP's and IsomerWebSockets' threads, so the runtime's
// thread never waits on the network.

import kotlin.coroutines.suspendCoroutine

object NetworkHosts {
    private var installed = false

    /** Installs Android's HTTP and WebSocket hosts as Foundation's transports; once. */
    @Synchronized
    fun install() {
        if (installed) return
        installed = true
        SwiftUIBridge.installIsomerNetworkHosts(http = AndroidHTTPHost(), webSocket = AndroidWebSocketHost())
    }
}

/** `HTTPHost` over HttpURLConnection (IsomerHTTP). */
class AndroidHTTPHost : HTTPHost {
    override suspend fun send(
        method: String, url: String, headers: String, body: ByteArray, timeout: Double,
    ): HTTPHostResponse = suspendCoroutine { continuation ->
        IsomerHTTP.send(method, url, NetworkHeaders.parse(headers), body, timeout) { result ->
            continuation.resumeWith(result.map { HTTPHostResponse(it.status, NetworkHeaders.json(it.headers), it.body, it.url) })
        }
    }
}

/** `WebSocketHost` over the runtime's RFC 6455 client (IsomerWebSockets). */
class AndroidWebSocketHost : WebSocketHost {
    override suspend fun open(url: String, protocols: String, headers: String, timeout: Double): Int =
        suspendCoroutine { continuation ->
            IsomerWebSockets.open(url, NetworkHeaders.strings(protocols), NetworkHeaders.parse(headers), timeout) {
                continuation.resumeWith(it)
            }
        }

    override fun subprotocol(id: Int): String = IsomerWebSockets.subprotocol(id)

    override suspend fun sendText(id: Int, text: String): Unit = suspendCoroutine { continuation ->
        IsomerWebSockets.sendText(id, text) { continuation.resumeWith(it) }
    }

    override suspend fun sendData(id: Int, data: ByteArray): Unit = suspendCoroutine { continuation ->
        IsomerWebSockets.sendData(id, data) { continuation.resumeWith(it) }
    }

    override suspend fun next(id: Int): WebSocketHostEvent = suspendCoroutine { continuation ->
        IsomerWebSockets.next(id) { result ->
            continuation.resumeWith(result.map { WebSocketHostEvent(it.kind, it.text, it.data, it.code) })
        }
    }

    override fun disconnect(id: Int, code: Int, reason: String) = IsomerWebSockets.close(id, code, reason)
}
