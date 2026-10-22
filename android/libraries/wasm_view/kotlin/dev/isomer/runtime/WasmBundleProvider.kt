package dev.isomer.runtime

// Where a wasm feature's bundle comes from on Android — the Kotlin mirror of the
// Apple `BundleProvider` and the web `bundle_provider.js`. A provider yields an
// initial bundle (the app-packaged asset, or the newest cached dynamic-delivery
// download) plus a Flow of newer bundles that arrive while running (a dev
// hot-reload shadow, or a production dynamic-delivery update); `WasmView`
// re-instantiates the reactor on each.

import android.content.Context
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withContext

/** A wasm reactor plus its small co-versioned assets (localized strings, tiny
 *  images). Large assets go through services or the main app bundle. */
data class WasmServiceBundle(
    val label: String,
    val wasm: ByteArray,
    val assets: Map<String, ByteArray> = emptyMap(),
)

interface WasmBundleProvider {
    /** The bundle available at launch, or null if none is packaged. */
    suspend fun initialBundle(): WasmServiceBundle?

    /** Newer bundles arriving while running. A static provider returns an empty
     *  flow that completes immediately. */
    fun bundleUpdates(): Flow<WasmServiceBundle> = emptyFlow()
}

/** The app-packaged bundle read from `assets/<assetPath>` (no updates). */
class PackagedWasmBundleProvider(
    private val context: Context,
    private val assetPath: String,
    private val label: String = assetPath,
) : WasmBundleProvider {
    override suspend fun initialBundle(): WasmServiceBundle = withContext(Dispatchers.IO) {
        context.assets.open(assetPath).use { WasmServiceBundle(label, it.readBytes()) }
    }
}

/** The batteries-included default: the packaged asset, plus a dev hot-reload
 *  shadow when [hotReloadUrl] is set (the same `/version` + `/wasm` protocol the
 *  Apple `AppBundleProvider` and the web `appBundleProvider` poll). Point
 *  production dynamic delivery at the same shape. */
class AppWasmBundleProvider(
    context: Context,
    assetPath: String,
    private val hotReloadUrl: String? = null,
    label: String = assetPath,
) : WasmBundleProvider {
    private val packaged = PackagedWasmBundleProvider(context, assetPath, label)

    override suspend fun initialBundle(): WasmServiceBundle? = packaged.initialBundle()

    override fun bundleUpdates(): Flow<WasmServiceBundle> {
        val base = hotReloadUrl?.trimEnd('/') ?: return emptyFlow()
        return flow {
            var version = Int.MIN_VALUE
            while (true) {
                delay(500)
                val v = fetchText("$base/version")?.trim()?.toIntOrNull() ?: continue
                if (v == version) continue
                version = v
                val wasm = fetchBytes("$base/wasm") ?: continue
                emit(WasmServiceBundle("server build $v", wasm))
            }
        }
    }

    private suspend fun fetchText(url: String): String? = withContext(Dispatchers.IO) {
        runCatching {
            (URL(url).openConnection() as HttpURLConnection).run {
                connectTimeout = 5000; readTimeout = 5000
                inputStream.bufferedReader().use { it.readText() }
            }
        }.getOrNull()
    }

    private suspend fun fetchBytes(url: String): ByteArray? = withContext(Dispatchers.IO) {
        runCatching {
            (URL(url).openConnection() as HttpURLConnection).run {
                connectTimeout = 5000; readTimeout = 5000
                inputStream.use { it.readBytes() }
            }
        }.getOrNull()
    }
}
