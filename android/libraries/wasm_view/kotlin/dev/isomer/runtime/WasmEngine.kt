package dev.isomer.runtime

// The Android engine seam — the Kotlin peer of Apple's `WasmRuntimeRegistry`:
// `WasmView` drives whatever engine its factory produces. `WasmKitRuntime` is
// the batteries-included default; an app may supply its own.
interface WasmEngine {
    fun start(width: Double, height: Double)
    fun render()
    fun resize(width: Double, height: Double)
    /** The host's system appearance (re-renders); engines without the export
     * ignore it. */
    fun setColorScheme(dark: Boolean) {}
    fun event(id: String, value: String)
    /** Generic app-export call — the FULL export name
     *  (`swift_ffi_[<ns>_]<name>(scalars..., [ptr, len])`) with an optional
     *  staged byte payload, then a re-render (the shape of any async
     *  completion delivery). What the export means belongs to the app;
     *  engines without the swift_ffi transport ignore it. */
    fun ffiCall(suffix: String, scalars: IntArray, payload: ByteArray? = null) {}
    fun destroy()
}
