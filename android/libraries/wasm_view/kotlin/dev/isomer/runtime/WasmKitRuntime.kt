package dev.isomer.runtime

// The Kotlin face of Android's wasm engine: WasmKit, the Swift interpreter,
// reached through its generated bridge (WasmEngineBridge). The engine is a
// Swift library of its own (android/libraries/wasm_view:
// wasm_engine_bindings, libwasm_engine_bindings.so) in an app that runs
// reactors alone, or bound in a compiled app's own library
// (`isomer_android_app(wasm_view = True)`), whose Swift runtime it then
// shares. Never both: two libraries of Swift are two Swift runtimes and two
// libdispatches in one process. One `WasmKitRuntime` wraps one live
// reactor. The peer of Apple's WasmView
// engine (the same `WasmKitRuntime` under the same `WasmFeatureRuntime`
// core) and the web's native `WebAssembly`.

/** Callbacks the running reactor drives back into the host. */
interface WasmEngineCallbacks {
    /** A fresh serialized render tree (tree.proto). */
    fun renderTree(tree: ByteArray)
    /** "Schedule a frame soon" — bounce onto the UI loop and call [WasmEngine.render]. */
    fun scheduleRender()
    /** Guest log(...) output. */
    fun log(message: String)

    /** Generic swift_ffi dependency dispatch: run one method call on the
     *  app-registered dependency at `index` (the order they were given).
     *  `args` is the ordinal-led argument blob; return the blob-encoded
     *  result (empty for Void). The framework never interprets either. */
    fun dispatchDependency(index: Int, args: ByteArray): ByteArray = ByteArray(0)
}

/** One app-owned swift_ffi dependency: installed under `key` in the guest's
 *  dictionary; `registryKey`/`registerSymbol` are the interface's identity
 *  and its guest register export (swift_ffi v3 — docs/abi.md); method calls
 *  arrive as opaque blobs on `dispatch`, together with the live engine (for
 *  async completions via [WasmEngine.ffiCall]). */
class WasmDependency(
    val key: String,
    val registryKey: String,
    val registerSymbol: String,
    val lazy: Boolean,
    val dispatch: (WasmEngine?, ByteArray) -> ByteArray,
)

/**
 * One wasm feature running on WasmKit: a reactor, or a side module over a
 * runtime module. Create it with the bundle and the host's
 * [WasmEngineCallbacks]; [start] instantiates and starts it; drive
 * [render]/[resize]/[event]; [destroy] frees it. Drive it from the main
 * thread: the guest's jobs are posted to libdispatch's main queue, which the
 * main looper drains.
 *
 * A module in a file or an asset is read by the engine's Swift, never by the
 * JVM; a side-module bundle ([WasmServiceBundle.sideModuleOf]) runs over
 * [runtimeModule], interpreted (mixed mode's native part isn't in the
 * engine's library). [context] resolves assets.
 */
class WasmKitRuntime(
    private val bundle: WasmServiceBundle,
    host: WasmEngineCallbacks,
    private val ffiPrefix: String? = null,
    dependencies: List<WasmDependency> = emptyList(),
    /** The guest's home (/home/app: its Documents, Application Support,
     *  Caches and UserDefaults); empty gives it none. */
    private val homeDirectory: String = "",
    private val bundleIdentifier: String = "",
    private val runtimeModule: WasmRuntimeModule? = null,
    private val context: android.content.Context? = null,
) : WasmEngine {
    /** A reactor from its bytes (the engine before bundles had sources). */
    constructor(
        wasm: ByteArray,
        host: WasmEngineCallbacks,
        ffiPrefix: String? = null,
        dependencies: List<WasmDependency> = emptyList(),
        homeDirectory: String = "",
        bundleIdentifier: String = "",
    ) : this(WasmServiceBundle("reactor", wasm), host, ffiPrefix, dependencies, homeDirectory, bundleIdentifier)

    private var dark = false
    private var handle: Long = WasmEngineBridge.wasmKitCreate(object : WasmKitHost {
        override fun renderTree(tree: ByteArray) = host.renderTree(tree)
        override fun scheduleRender() = host.scheduleRender()
        override fun log(message: String) = host.log(message)
        override fun dispatchDependency(index: Int, args: ByteArray): ByteArray = host.dispatchDependency(index, args)
    })

    init {
        MainQueue.watch()
        dependencies.forEachIndexed { index, dependency ->
            WasmEngineBridge.wasmKitAddDependency(
                handle, index, dependency.key, dependency.registryKey, dependency.registerSymbol, dependency.lazy,
            )
        }
    }

    override fun start(width: Double, height: Double) {
        if (handle == 0L) return
        val module = bundle.module
        val failure = if (module is WasmModuleSource.Bytes && bundle.sideModuleOf == null) {
            WasmEngineBridge.wasmKitLaunch(handle, module.bytes, ffiPrefix ?: "", homeDirectory, bundleIdentifier, width, height, dark)
        } else {
            // Both sources stay open until the engine has read them, during
            // the launch (an asset read in place is the APK's descriptor).
            val runtime = runtimeModule?.let { resolveModule(it.source, context) }
            try {
                resolveModule(module, context).use { feature ->
                    if (runtimeModule != null && runtime != null) {
                        WasmEngineBridge.wasmKitSetRuntimeModule(
                            handle, runtimeModule.name, runtime.bytes, runtime.path, runtime.offset, runtime.length)
                    }
                    WasmEngineBridge.wasmKitLaunchModule(
                        handle, bundle.label, feature.bytes, feature.path, feature.offset, feature.length,
                        bundle.sideModuleOf ?: "", ffiPrefix ?: "", homeDirectory, bundleIdentifier, width, height, dark)
                }
            } finally {
                runtime?.close()
            }
        }
        if (failure.isNotEmpty()) throw IllegalStateException(failure)
    }

    override fun render() {
        if (handle != 0L) WasmEngineBridge.wasmKitRender(handle)
    }

    override fun resize(width: Double, height: Double) {
        if (handle != 0L) WasmEngineBridge.wasmKitResize(handle, width, height)
    }

    /** See [WasmEngine.setColorScheme]. */
    override fun setColorScheme(dark: Boolean) {
        this.dark = dark
        if (handle != 0L) WasmEngineBridge.wasmKitSetColorScheme(handle, dark)
    }

    override fun event(id: String, value: String) {
        if (handle != 0L) WasmEngineBridge.wasmKitEvent(handle, id, value)
    }

    /** See [WasmEngine.ffiCall]. Call on the main thread. */
    override fun ffiCall(suffix: String, scalars: IntArray, payload: ByteArray?) {
        if (handle == 0L) return
        val packed = java.nio.ByteBuffer.allocate(scalars.size * 4).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        scalars.forEach { packed.putInt(it) }
        WasmEngineBridge.wasmKitCall(handle, suffix, packed.array(), payload ?: ByteArray(0))
    }

    override fun destroy() {
        if (handle != 0L) {
            WasmEngineBridge.wasmKitDestroy(handle)
            handle = 0L
        }
    }
}

/** libdispatch's main queue in the engine's library, where WasmKit posts the
 *  guest's jobs: nothing in an Android process drains it, so the main looper
 *  watches its wake handle and drains it when it fires. Main-thread only.
 *  Bound in a compiled app's library, the queue is the app's too, which
 *  NativeBridge watches as well: the eventfd is non-blocking, so whichever
 *  listener runs second reads nothing and drains an empty queue. */
internal object MainQueue {
    private var watch: android.os.ParcelFileDescriptor? = null

    fun watch() {
        if (watch != null || android.os.Looper.myLooper() != android.os.Looper.getMainLooper()) return
        val handle = WasmEngineBridge.wasmKitMainQueueHandle()
        if (handle < 0) return
        val descriptor = android.os.ParcelFileDescriptor.fromFd(handle)
        watch = descriptor
        val wakes = java.io.FileInputStream(descriptor.fileDescriptor)
        val input = android.os.MessageQueue.OnFileDescriptorEventListener.EVENT_INPUT
        android.os.Looper.getMainLooper().queue.addOnFileDescriptorEventListener(descriptor.fileDescriptor, input) { _, _ ->
            // An eventfd: reading it clears the wake.
            try { wakes.read(ByteArray(8)) } catch (_: java.io.IOException) {}
            WasmEngineBridge.wasmKitDrainMainQueue()
            input
        }
    }
}
