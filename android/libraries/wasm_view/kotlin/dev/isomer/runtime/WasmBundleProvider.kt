package dev.isomer.runtime

// Where a wasm feature's bundle comes from on Android — the Kotlin mirror of the
// Apple `BundleProvider` and the web `bundle_provider.js`. A provider yields an
// initial bundle (the app-packaged asset, or the newest cached dynamic-delivery
// download) plus a Flow of newer bundles that arrive while running (a dev
// hot-reload shadow, or a production dynamic-delivery update); `WasmView`
// re-instantiates the reactor on each (or, for a side module, launches its
// runtime module again with the new side module over it).

import android.content.Context
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withContext

/** Where a wasm module's bytes come from: the JVM's memory, or a file (or
 *  an asset) the engine's Swift reads itself when it launches the module.
 *  A large module (a runtime module is tens of megabytes) belongs in a
 *  file or an asset: read into a `ByteArray` and copied through JNI, one ran
 *  an Android 6 emulator out of the JVM's memory. */
sealed class WasmModuleSource {
    /** The module's bytes, in the JVM: fine for a reactor or a feature's
     *  side module, a few hundred kilobytes. */
    class Bytes(val bytes: ByteArray) : WasmModuleSource()

    /** [length] bytes of the file at [path] from [offset] (-1: to its end),
     *  read by the engine's Swift. */
    data class File(val path: String, val offset: Long = 0, val length: Long = -1) : WasmModuleSource()

    /** The app's asset [name] (`assets/<name>`), read by the engine's Swift
     *  in place in the APK when it is stored uncompressed (list `.wasm` among
     *  the app's uncompressed extensions), else from a copy the host streams
     *  into the app's no-backup files once per install (never whole in the
     *  JVM). */
    data class Asset(val name: String) : WasmModuleSource()
}

/** The runtime module side-module bundles run over (docs/side_modules.md):
 *  its [name], which a side module's bundle names ([WasmServiceBundle.sideModuleOf]),
 *  and where its bytes are. `WasmView` takes it once; each bundle loaded (a
 *  reload too) launches it again in a fresh engine, with the bundle's side
 *  module over it. */
class WasmRuntimeModule(val name: String, val source: WasmModuleSource)

/** A wasm feature's module plus its small co-versioned assets (localized
 *  strings, tiny images). Large assets go through services or the main app
 *  bundle. The module is a self-contained reactor ([sideModuleOf] null), or
 *  a side module linked against the runtime module named [sideModuleOf]. */
data class WasmServiceBundle(
    val label: String,
    val module: WasmModuleSource,
    val assets: Map<String, ByteArray> = emptyMap(),
    val sideModuleOf: String? = null,
) {
    /** A reactor, its bytes in the JVM (the bundle before modules had sources). */
    constructor(label: String, wasm: ByteArray, assets: Map<String, ByteArray> = emptyMap()) :
        this(label, WasmModuleSource.Bytes(wasm), assets)

    /** The module's bytes in the JVM: a [WasmModuleSource.Bytes]'s, or a
     *  [WasmModuleSource.File]'s read now. An asset's aren't read here (the
     *  engine reads it); hand the bundle to the engine instead. */
    val wasm: ByteArray
        get() = when (val source = module) {
            is WasmModuleSource.Bytes -> source.bytes
            is WasmModuleSource.File -> java.io.RandomAccessFile(source.path, "r").use { file ->
                val length = if (source.length < 0) file.length() - source.offset else source.length
                ByteArray(length.toInt()).also { file.seek(source.offset); file.readFully(it) }
            }
            is WasmModuleSource.Asset ->
                throw IllegalStateException("${source.name} is an asset the engine reads; it has no bytes here")
        }
}

/** A module's source as the engine's Swift takes it: [bytes], or the file at
 *  [path] (its [length] bytes from [offset]) when [path] isn't empty. Open
 *  until closed: an asset read in place is its APK's descriptor, which the
 *  engine reads through /proc/self/fd while it launches. */
internal class ResolvedModule(
    val bytes: ByteArray,
    val path: String,
    val offset: Long,
    val length: Long,
    private val descriptor: android.content.res.AssetFileDescriptor? = null,
) : java.io.Closeable {
    override fun close() {
        descriptor?.close()
    }
}

/** [source] for the engine: an asset becomes its range in the APK, or a copy
 *  of it (see [WasmModuleSource.Asset]); [context] reads the assets. */
internal fun resolveModule(source: WasmModuleSource, context: Context?): ResolvedModule = when (source) {
    is WasmModuleSource.Bytes -> ResolvedModule(source.bytes, "", 0, -1)
    is WasmModuleSource.File -> ResolvedModule(ByteArray(0), source.path, source.offset, source.length)
    is WasmModuleSource.Asset -> {
        val assets = (context ?: throw IllegalStateException("the asset ${source.name} needs a Context")).assets
        try {
            // Stored uncompressed: a descriptor of the APK and the asset's range.
            val descriptor = assets.openFd(source.name)
            ResolvedModule(
                ByteArray(0), "/proc/self/fd/${descriptor.parcelFileDescriptor.fd}",
                descriptor.startOffset, descriptor.length, descriptor,
            )
        } catch (compressed: java.io.FileNotFoundException) {
            ResolvedModule(ByteArray(0), copiedAsset(context, source.name).path, 0, -1)
        }
    }
}

/** A compressed asset streamed into the app's no-backup files, once per
 *  install of the app (the copy is named by the APK's time; older copies of
 *  the asset go). */
private fun copiedAsset(context: Context, name: String): java.io.File {
    // The APK's time: a new install's APK is a new file.
    val installed = java.io.File(context.applicationInfo.sourceDir).lastModified()
    val directory = java.io.File(context.noBackupFilesDir, "isomer-wasm-modules")
    val suffix = "-" + name.replace('/', '_')
    val copy = java.io.File(directory, "$installed$suffix")
    if (copy.isFile) return copy
    directory.mkdirs()
    directory.listFiles()?.filter { it.name.endsWith(suffix) }?.forEach { it.delete() }
    val partial = java.io.File(directory, copy.name + ".partial")
    context.assets.open(name).use { input -> partial.outputStream().use { input.copyTo(it, 1 shl 16) } }
    if (!partial.renameTo(copy)) throw java.io.IOException("can't keep the copy of the asset $name")
    return copy
}

interface WasmBundleProvider {
    /** The bundle available at launch, or null if none is packaged. */
    suspend fun initialBundle(): WasmServiceBundle?

    /** Newer bundles arriving while running. A static provider returns an empty
     *  flow that completes immediately. */
    fun bundleUpdates(): Flow<WasmServiceBundle> = emptyFlow()
}

/** The app-packaged bundle read from `assets/<assetPath>` (no updates): a
 *  reactor, or a side module over the runtime module [sideModuleOf] names.
 *  With [engineReads] the engine's Swift reads the asset itself
 *  ([WasmModuleSource.Asset]), rather than the JVM. */
class PackagedWasmBundleProvider(
    private val context: Context,
    private val assetPath: String,
    private val label: String = assetPath,
    private val sideModuleOf: String? = null,
    private val engineReads: Boolean = false,
) : WasmBundleProvider {
    override suspend fun initialBundle(): WasmServiceBundle = withContext(Dispatchers.IO) {
        if (engineReads) {
            WasmServiceBundle(label, WasmModuleSource.Asset(assetPath), sideModuleOf = sideModuleOf)
        } else {
            context.assets.open(assetPath).use {
                WasmServiceBundle(label, WasmModuleSource.Bytes(it.readBytes()), sideModuleOf = sideModuleOf)
            }
        }
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
    /** The runtime module the packaged and served builds are side modules of
     *  (null: reactors); see [PackagedWasmBundleProvider]. */
    private val sideModuleOf: String? = null,
    engineReads: Boolean = false,
) : WasmBundleProvider {
    private val packaged = PackagedWasmBundleProvider(context, assetPath, label, sideModuleOf, engineReads)

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
                emit(WasmServiceBundle("server build $v", WasmModuleSource.Bytes(wasm), sideModuleOf = sideModuleOf))
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
