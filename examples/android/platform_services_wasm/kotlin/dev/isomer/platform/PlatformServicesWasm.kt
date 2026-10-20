// The Android WASM cells' side of shared/platform_services: the five
// dependencies as opaque blob dispatchers over the generic WAMR runtime
// (isomer ships only the DI pattern — keys, ordinals, and codecs are
// app-owned). Async methods (network, keychain) decode the leading call id,
// do their work off the main thread, and answer the guest through the fixed
// `swift_ffi_async_resume` export on the main thread.
//
// Wire format (swift_ffi's erased blob, little-endian; docs/abi.md): each
// value is an 8-byte (tag, aux) header + payload — ints as i64, strings and
// byte arrays as i64 length + bytes, lists as i64 count + items.

package dev.isomer.platform

import android.os.Handler
import dev.isomer.runtime.WasmDependency
import dev.isomer.runtime.WasmEngine
import java.net.URL
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

object PlatformServicesWasm {
    /** The swift_ffi module prefix of the `platform_services` namespace. */
    const val FFI_PREFIX = "swift_ffi_platform_services_"

    private const val TAG_VOID = 0; private const val TAG_INT = 1; private const val TAG_INT32 = 2
    private const val TAG_BOOL = 4; private const val TAG_STRING = 5; private const val TAG_BYTES = 6
    private const val TAG_LIST = 8; private const val TAG_ERROR = 10

    // ---- blob helpers ----
    private class Reader(bytes: ByteArray) {
        val buf: ByteBuffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        fun header() { buf.int; buf.int }
        fun int32(): Int { header(); return buf.long.toInt() }
        fun string(): String { header(); val n = buf.long.toInt(); val b = ByteArray(n); buf.get(b); return String(b, Charsets.UTF_8) }
        fun bytes(): ByteArray { header(); val n = buf.long.toInt(); val b = ByteArray(n); buf.get(b); return b }
    }

    private class Writer {
        val out = java.io.ByteArrayOutputStream()
        private fun i32(v: Int) { out.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(v).array()) }
        private fun i64(v: Long) { out.write(ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(v).array()) }
        fun header(tag: Int) { i32(tag); i32(0) }
        fun void(): Writer { header(TAG_VOID); return this }
        fun bool(v: Boolean): Writer { header(TAG_BOOL); i64(if (v) 1 else 0); return this }
        fun string(v: String): Writer { header(TAG_STRING); val b = v.toByteArray(Charsets.UTF_8); i64(b.size.toLong()); out.write(b); return this }
        fun bytes(v: ByteArray): Writer { header(TAG_BYTES); i64(v.size.toLong()); out.write(v); return this }
        fun stringList(v: List<String>): Writer { header(TAG_LIST); i64(v.size.toLong()); v.forEach { string(it) }; return this }
        fun error(message: String): Writer { header(TAG_ERROR); val b = message.toByteArray(Charsets.UTF_8); i64(b.size.toLong()); out.write(b); return this }
        fun data(): ByteArray = out.toByteArray()
    }

    /** Answer an async call on the runtime's thread. */
    private fun resume(main: Handler, engine: WasmEngine?, callId: Int, blob: ByteArray) {
        main.post { engine?.ffiCall("swift_ffi_async_resume", intArrayOf(callId), blob) }
    }

    /** The full table for one feature: the keychain under
     *  `keychainNamespace`. Networking and files are Foundation's own
     *  (WasmView's network hosts, the app's directories). */
    fun all(
        main: Handler, keychainNamespace: String, context: android.content.Context?,
        pickImage: ((Int, (String) -> Unit) -> Unit)? = null,
    ): List<WasmDependency> =
        listOf(keychain(main, keychainNamespace, context), analytics(), configuration(), timer(main)) +
            (if (pickImage != null) listOf(imagePicker(main, pickImage)) else emptyList())

    /** One-shot delays on the main looper. */
    fun timer(main: Handler) = WasmDependency(
        key = "timer",
        registryKey = "swift_ffi_platform_services_TimerService",
        registerSymbol = "swift_ffi_platform_services_register_TimerService",
        lazy = true,
    ) { engine, args ->
        val r = Reader(args)
        when (r.int32()) {
            0 -> { // delay(milliseconds:) async
                val callId = r.int32(); val ms = r.int32()
                main.postDelayed({ resume(main, engine, callId, Writer().void().data()) }, ms.coerceAtLeast(0).toLong())
                Writer().void().data()
            }
            else -> Writer().error("unknown TimerService method").data()
        }
    }

    /**
     * The image chooser: `pickImage(maxDimension, callback)` presents it and
     * hands back a displayable URL or "" (the activity supplies
     * dev.isomer.runtime.ImagePickerHost::pick).
     */
    fun imagePicker(main: Handler, pickImage: (Int, (String) -> Unit) -> Unit) = WasmDependency(
        key = "imagePicker",
        registryKey = "swift_ffi_platform_services_ImagePickerService",
        registerSymbol = "swift_ffi_platform_services_register_ImagePickerService",
        lazy = true,
    ) { engine, args ->
        val r = Reader(args)
        when (r.int32()) {
            0 -> { // pickImage(maxDimension:) async throws -> String
                val callId = r.int32(); val maxDimension = r.int32()
                pickImage(maxDimension) { url ->
                    resume(main, engine, callId, Writer().string(url).data())
                }
                Writer().void().data()
            }
            else -> Writer().error("unknown ImagePickerService method").data()
        }
    }

    fun keychain(main: Handler, namespace: String, context: android.content.Context?) = WasmDependency(
        key = "keychain",
        registryKey = "swift_ffi_platform_services_KeychainService",
        registerSymbol = "swift_ffi_platform_services_register_KeychainService",
        lazy = true,
    ) { engine, args ->
        val prefs = context?.getSharedPreferences("iso-keychain-$namespace", android.content.Context.MODE_PRIVATE)
        val r = Reader(args)
        when (r.int32()) {
            0 -> { // get(key:) async throws -> [UInt8]
                val callId = r.int32(); val key = r.string()
                val stored = prefs?.getString(key, null)
                val blob = if (stored == null) Writer().error("no keychain value for $key").data()
                    else Writer().bytes(android.util.Base64.decode(stored, android.util.Base64.NO_WRAP)).data()
                resume(main, engine, callId, blob)
                Writer().void().data()
            }
            1 -> { // set(value:for:) async throws
                val callId = r.int32(); val value = r.bytes(); val key = r.string()
                val ok = prefs?.edit()?.putString(key, android.util.Base64.encodeToString(value, android.util.Base64.NO_WRAP))?.commit() == true
                resume(main, engine, callId, if (ok) Writer().void().data() else Writer().error("keychain write failed").data())
                Writer().void().data()
            }
            2 -> { // delete(key:) async throws
                val callId = r.int32(); val key = r.string()
                prefs?.edit()?.remove(key)?.commit()
                resume(main, engine, callId, Writer().void().data())
                Writer().void().data()
            }
            else -> Writer().error("unknown KeychainService method").data()
        }
    }

    fun analytics() = WasmDependency(
        key = "analytics",
        registryKey = "swift_ffi_platform_services_AnalyticsService",
        registerSymbol = "swift_ffi_platform_services_register_AnalyticsService",
        lazy = true,
    ) { _, args ->
        val r = Reader(args)
        if (r.int32() == 0) android.util.Log.i("Isomer", "[analytics] ${r.string()}")
        Writer().void().data()
    }

    fun configuration() = WasmDependency(
        key = "configuration",
        registryKey = "swift_ffi_platform_services_ConfigurationService",
        registerSymbol = "swift_ffi_platform_services_register_ConfigurationService",
        lazy = true,
    ) { _, args ->
        val r = Reader(args)
        if (r.int32() == 0) Writer().bool(r.string() == "promo_banner").data() else Writer().error("unknown ConfigurationService method").data()
    }
}
