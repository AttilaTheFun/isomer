package dev.isomer.runtime

// The Kotlin face of the WAMR C engine (//shared/wamr_host via the JNI shim in
// //android/libraries/wasm_view/jni). This is Android's "wasm" delivery engine:
// WAMR is a C interpreter, so running a wasm feature bundle pulls NO compiled
// Swift into the app — the peer of Apple's WasmKit `WasmRuntime` and the web's
// native `WebAssembly`. One `WamrRuntime` wraps one live reactor instance.

/** Callbacks the running reactor drives back into the host. */
interface WamrHost {
    /** A fresh serialized render tree (tree.fbs). */
    fun renderTree(tree: ByteArray)
    /** "Schedule a frame soon" — bounce onto the UI loop and call [WamrRuntime.render]. */
    fun scheduleRender()
    /** Guest log(...) output. */
    fun log(message: String)
    // GPU (self-drawing) reactor services — a SwiftGPURenderer running inside
    // the module measures/rasterizes text on the host's text stack. Tree-
    // emitting hosts keep the defaults (their reactors never call these).

    /** Measure wrapped text; {width, height} in points (wrapWidth < 0 = unwrapped). */
    fun measureText(text: String, fontSize: Double, weight: Int, wrapWidth: Double): DoubleArray =
        HostServices.measureText(text, fontSize, weight, wrapWidth)
    /** Rasterize a SwiftGPURenderer spec to [w u32][h u32][premultiplied RGBA8...]. */
    fun rasterize(spec: String): ByteArray = HostServices.rasterizeSpec(spec)

    /** Generic swift_ffi dependency dispatch: run one method call on the
     *  app-registered dependency at `index` (see [WamrRuntime]'s create).
     *  `args` is the ordinal-led argument blob; return the blob-encoded
     *  result (empty for Void). The framework never interprets either. */
    fun dispatchDependency(index: Int, args: ByteArray): ByteArray = ByteArray(0)

    /** The guest queued Swift concurrency jobs (a `Task {}`, or an async
     *  service answer resuming a continuation): bounce onto the UI loop and
     *  call [WamrRuntime.runJobs]. */
    fun scheduleJobs() {}
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

/** Stateless JNI entry points; drive them through [WamrRuntime]. */
internal object WamrBridge {
    init { System.loadLibrary("iso_wamr_jni") }

    external fun nativeCreate(
        wasm: ByteArray,
        host: WamrHost,
        ffiPrefix: String?,
        depKeys: Array<String>?,
        depRegistryKeys: Array<String>?,
        depRegisterSymbols: Array<String>?,
        depLazy: BooleanArray?,
    ): Long
    external fun nativeStart(handle: Long, width: Double, height: Double)
    external fun nativeNextJobDelayMs(handle: Long): Long
    external fun nativeRender(handle: Long)
    external fun nativeResize(handle: Long, width: Double, height: Double)
    external fun nativeSetColorScheme(handle: Long, dark: Boolean)
    external fun nativeEvent(handle: Long, id: String, value: String)
    external fun nativeFfiCall(handle: Long, suffix: String, scalars: IntArray, payload: ByteArray?)
    external fun nativeRunJobs(handle: Long)
    external fun nativeSurfaceChanged(handle: Long, widthPx: Int, heightPx: Int, density: Double)
    external fun nativePointer(handle: Long, kind: Int, x: Double, y: Double): Int
    external fun nativeDestroy(handle: Long)
}

/**
 * One wasm feature reactor running under WAMR. Create it with the bundle bytes
 * and a [WamrHost]; drive [start]/[render]/[resize]/[event]; [destroy] frees
 * the interpreter and its instance. Not thread-safe — drive from one thread
 * (Android's main thread, matching the render pump).
 */
class WamrRuntime(
    wasm: ByteArray,
    host: WamrHost,
    ffiPrefix: String? = null,
    dependencies: List<WasmDependency> = emptyList(),
) : WasmEngine {
    private var handle: Long = WamrBridge.nativeCreate(
        wasm, host, ffiPrefix,
        if (dependencies.isEmpty()) null else dependencies.map { it.key }.toTypedArray(),
        if (dependencies.isEmpty()) null else dependencies.map { it.registryKey }.toTypedArray(),
        if (dependencies.isEmpty()) null else dependencies.map { it.registerSymbol }.toTypedArray(),
        if (dependencies.isEmpty()) null else dependencies.map { it.lazy }.toBooleanArray(),
    )

    override fun start(width: Double, height: Double) {
        if (handle != 0L) WamrBridge.nativeStart(handle, width, height)
    }

    override fun render() {
        if (handle != 0L) WamrBridge.nativeRender(handle)
    }

    override fun resize(width: Double, height: Double) {
        if (handle != 0L) WamrBridge.nativeResize(handle, width, height)
    }

    /** See [WasmEngine.setColorScheme]. */
    override fun setColorScheme(dark: Boolean) {
        if (handle != 0L) WamrBridge.nativeSetColorScheme(handle, dark)
    }

    override fun event(id: String, value: String) {
        if (handle != 0L) WamrBridge.nativeEvent(handle, id, value)
    }

    /** See [WasmEngine.ffiCall]. Call on the thread that drives the runtime. */
    override fun ffiCall(suffix: String, scalars: IntArray, payload: ByteArray?) {
        if (handle != 0L) WamrBridge.nativeFfiCall(handle, suffix, scalars, payload)
    }

    /** Run the guest's queued Swift concurrency jobs (see [WamrHost.scheduleJobs]). */
    fun runJobs() {
        if (handle != 0L) WamrBridge.nativeRunJobs(handle)
    }

    /** Milliseconds until the guest's next timed job (`Task.sleep`) is due;
     *  0 when one is due now, -1 when none waits. */
    fun nextJobDelayMs(): Long = if (handle != 0L) WamrBridge.nativeNextJobDelayMs(handle) else -1

    // GPU (self-drawing) reactor entry points — drive them on the GL thread
    // with the EGL context current (the reactor draws through native GL).

    /** Surface size/density changed (also signals a fresh EGL context). */
    fun surfaceChanged(widthPx: Int, heightPx: Int, density: Double) {
        if (handle != 0L) WamrBridge.nativeSurfaceChanged(handle, widthPx, heightPx, density)
    }

    /** Pointer input in logical points; kind: 0 down / 1 up / 2 move.
     *  Returns true when the reactor wants a redraw. */
    fun pointer(kind: Int, x: Double, y: Double): Boolean =
        handle != 0L && WamrBridge.nativePointer(handle, kind, x, y) != 0

    override fun destroy() {
        if (handle != 0L) {
            WamrBridge.nativeDestroy(handle)
            handle = 0L
        }
    }
}
