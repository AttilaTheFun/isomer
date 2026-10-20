package dev.isomer.runtime

// Foundation's networking in the wasm delivery: IsomerHTTP and
// IsomerWebSockets (//android/libraries/swift_ui:foundation_hosts_kotlin)
// as dependencies WasmView injects into a reactor under IsomerNetworkHost's
// keys (`isomerHTTP`, `isomerWebSocket`), which a reactor on the full
// SwiftUI installs as Foundation's transports when it starts
// (`installInjectedNetworkHosts` in iso_hot_start). The compiled delivery
// hands the same two to Swift through its generated bindings
// (NetworkHosts.kt); here there are none (no compiled Swift), so the calls
// arrive as swift_ffi's blobs (docs/swift_ffi/abi.md): the method's ordinal,
// an async method's call id, then the arguments. Synchronous methods answer
// from the dispatch; async ones answer later through the guest's
// `swift_ffi_async_resume`, on the main thread, which drives the reactor.

import android.os.Handler
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

object WasmNetworkHosts {
    /** Both hosts, answering on `main` (the thread that drives the reactor). */
    fun dependencies(main: Handler): List<WasmDependency> = listOf(http(main), webSocket(main))

    /** The keys they take in the guest's `dependencies` (NetworkHostKey's raw values). */
    val keys = setOf("isomerHTTP", "isomerWebSocket")

    /** `HTTPHost` (ordinal 0: `send(method:url:headers:body:timeout:) async throws -> HTTPHostResponse`). */
    fun http(main: Handler) = WasmDependency(
        key = "isomerHTTP",
        registryKey = "swift_ffi_isomer_HTTPHost",
        registerSymbol = "swift_ffi_isomer_register_HTTPHost",
        lazy = false,
    ) { engine, args ->
        val r = Reader(args)
        when (r.int32()) {
            0 -> {
                val call = r.int32()
                val method = r.string()
                val url = r.string()
                val headers = r.string()
                val body = r.bytes()
                val timeout = r.double()
                IsomerHTTP.send(method, url, NetworkHeaders.parse(headers), body, timeout) { result ->
                    answer(main, engine, call, result.fold({
                        Writer().struct("HTTPHostResponse", 4)
                            .int32(it.status).string(NetworkHeaders.json(it.headers)).bytes(it.body).string(it.url).data()
                    }, { error(it) }))
                }
                Writer().void().data()
            }
            else -> Writer().error("HTTPHost has no such method").data()
        }
    }

    /** `WebSocketHost`: 0 `open`, 1 `subprotocol`, 2 `sendText`, 3 `sendData`, 4 `next`, 5 `disconnect`. */
    fun webSocket(main: Handler) = WasmDependency(
        key = "isomerWebSocket",
        registryKey = "swift_ffi_isomer_WebSocketHost",
        registerSymbol = "swift_ffi_isomer_register_WebSocketHost",
        lazy = false,
    ) { engine, args ->
        val r = Reader(args)
        val method = r.int32()
        when (method) {
            0 -> { // open(url:protocols:headers:timeout:) async throws -> Int32
                val call = r.int32()
                val url = r.string()
                val protocols = r.string()
                val headers = r.string()
                val timeout = r.double()
                IsomerWebSockets.open(url, NetworkHeaders.strings(protocols), NetworkHeaders.parse(headers), timeout) { result ->
                    answer(main, engine, call, result.fold({ Writer().int32(it).data() }, { error(it) }))
                }
                Writer().void().data()
            }
            1 -> Writer().string(IsomerWebSockets.subprotocol(r.int32())).data()
            2, 3 -> { // sendText(id:text:) / sendData(id:data:) async throws
                val call = r.int32()
                val id = r.int32()
                val done = { result: Result<Unit> ->
                    answer(main, engine, call, result.fold({ Writer().void().data() }, { error(it) }))
                }
                if (method == 2) IsomerWebSockets.sendText(id, r.string(), done)
                else IsomerWebSockets.sendData(id, r.bytes(), done)
                Writer().void().data()
            }
            4 -> { // next(id:) async throws -> WebSocketHostEvent
                val call = r.int32()
                IsomerWebSockets.next(r.int32()) { result ->
                    answer(main, engine, call, result.fold({
                        Writer().struct("WebSocketHostEvent", 4)
                            .int32(it.kind).string(it.text).bytes(it.data).int32(it.code).data()
                    }, { error(it) }))
                }
                Writer().void().data()
            }
            5 -> { // disconnect(id:code:reason:)
                IsomerWebSockets.close(r.int32(), r.int32(), r.string())
                Writer().void().data()
            }
            else -> Writer().error("WebSocketHost has no such method").data()
        }
    }

    /** An async call's answer, delivered where the reactor runs. A reactor
     *  replaced meanwhile (destroyed) takes none. */
    private fun answer(main: Handler, engine: WasmEngine?, call: Int, blob: ByteArray) {
        main.post { engine?.ffiCall("swift_ffi_async_resume", intArrayOf(call), blob) }
    }

    private fun error(error: Throwable): ByteArray =
        Writer().error(error.message ?: error.toString()).data()

    // swift_ffi's blob, as much of it as these two interfaces use: each value
    // an (i32 tag, i32 aux) header and its payload, little-endian; numbers as
    // i64, strings and bytes as an i64 length and the bytes, a struct as its
    // name (aux its length), an i64 field count and the fields.

    private const val VOID = 0
    private const val INT32 = 2
    private const val STRING = 5
    private const val BYTES = 6
    private const val STRUCT = 7
    private const val ERROR = 10

    private class Reader(bytes: ByteArray) {
        private val buffer: ByteBuffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)

        private fun payload(): ByteArray {
            buffer.int
            buffer.int
            return ByteArray(buffer.long.toInt()).also { buffer.get(it) }
        }

        fun int32(): Int {
            buffer.int
            buffer.int
            return buffer.long.toInt()
        }

        fun double(): Double {
            buffer.int
            buffer.int
            return Double.fromBits(buffer.long)
        }

        fun string(): String = String(payload(), Charsets.UTF_8)

        fun bytes(): ByteArray = payload()
    }

    private class Writer {
        private val out = ByteArrayOutputStream()

        private fun i32(value: Int) = out.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array())

        private fun i64(value: Long) = out.write(ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(value).array())

        private fun header(tag: Int, aux: Int = 0) {
            i32(tag)
            i32(aux)
        }

        fun void() = apply { header(VOID) }

        fun int32(value: Int) = apply {
            header(INT32)
            i64(value.toLong())
        }

        fun string(value: String) = apply {
            val bytes = value.toByteArray(Charsets.UTF_8)
            header(STRING)
            i64(bytes.size.toLong())
            out.write(bytes)
        }

        fun bytes(value: ByteArray) = apply {
            header(BYTES)
            i64(value.size.toLong())
            out.write(value)
        }

        /** A struct's header; its `fields` follow. */
        fun struct(name: String, fields: Int) = apply {
            val bytes = name.toByteArray(Charsets.UTF_8)
            header(STRUCT, bytes.size)
            out.write(bytes)
            i64(fields.toLong())
        }

        fun error(message: String) = apply {
            val bytes = message.toByteArray(Charsets.UTF_8)
            header(ERROR)
            i64(bytes.size.toLong())
            out.write(bytes)
        }

        fun data(): ByteArray = out.toByteArray()
    }
}
