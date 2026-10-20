package dev.isomer.tapcounter.wasmgpu

// The wasm+GPU cell of the counter benchmark: the SAME shared TapCounter.swift
// @main App shipped as a GPU wasm reactor (SwiftGPURenderer runs inside the
// module and draws through native OpenGL ES via its env.gl* imports) hosted by
// `WasmGpuView`. The APK carries NO compiled Swift and NO Jetpack Compose —
// just this activity, the GLSurfaceView, and libiso_wamr_jni.so. Its Compose-
// interpreted twin is //examples/android/tap_counter_wasm_android_application.
// See docs/benchmarks.md.

import android.app.Activity
import android.os.Bundle
import dev.isomer.runtime.WasmGpuView

class MainActivity : Activity() {
    private var surface: WasmGpuView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Init-threading A/B (benchmark): the GL-thread model is off-main by
        // construction; `--ez mainThreadInit true` instead blocks onCreate on
        // the module load + instantiate (the toolkit cells' default shape).
        val mainThreadInit = intent.getBooleanExtra("mainThreadInit", false)
        surface = WasmGpuView(this, ::loadReactor, mainThreadInit).also { setContentView(it) }
    }

    /** The packaged reactor: the native `.aot` when present (`--config=release`
     *  builds), else the interpreted `.wasm`. */
    private fun loadReactor(): ByteArray {
        for (path in listOf("tap_counter_gpu_release.aot", "tap_counter_gpu_release.wasm")) {
            try {
                return assets.open(path).use { it.readBytes() }
            } catch (_: java.io.FileNotFoundException) {
                // try the next candidate
            }
        }
        throw IllegalStateException("no packaged gpu reactor asset")
    }

    override fun onResume() {
        super.onResume()
        surface?.onResume()
    }

    override fun onPause() {
        surface?.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        surface?.destroy()
        super.onDestroy()
    }
}
