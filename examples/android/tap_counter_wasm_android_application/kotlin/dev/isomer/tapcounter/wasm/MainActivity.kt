package dev.isomer.tapcounter.wasm

// The wasm-delivered cell of the minimal counter benchmark: the SAME shared
// TapCounter.swift @main App shipped as ONE wasm reactor and hosted full-screen by
// `WasmView`, run in-process on WasmKit and drawn by the Swift-free Compose
// interpreter — none of the app's Swift is compiled into the APK (its one
// native library is the engine's, libwasm_engine_bindings.so).
// Its compiled twin is //examples/android/tap_counter_compiled_android_application.
// See docs/benchmarks.md.

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import dev.isomer.runtime.AppWasmBundleProvider
import dev.isomer.runtime.WasmView

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Init-threading A/B (benchmark): `--ez offMainInit true` moves the
        // reactor instantiate + first render off the main thread.
        val offMainInit = intent.getBooleanExtra("offMainInit", false)
        setContent { CounterWasmApp(offMainInit) }
        // Uniform benchmark content signal: the first draw that includes the
        // reactor's decoded tree.
        dev.isomer.runtime.ContentFrame.install(window.decorView) {
            dev.isomer.runtime.ComposeTreeState.tree.value != null
        }
        dev.isomer.runtime.TapProbe.install(this)
    }

    override fun dispatchTouchEvent(ev: android.view.MotionEvent): Boolean {
        dev.isomer.runtime.TapProbe.onTouch(this, ev)
        return super.dispatchTouchEvent(ev)
    }
}

@Composable
fun CounterWasmApp(offMainInit: Boolean = false) {
    val context = LocalContext.current
    // The counter packaged as assets/tap_counter_release.wasm.
    val provider = remember {
        AppWasmBundleProvider(context, "tap_counter_release.wasm")
    }
    WasmView(provider = provider, modifier = Modifier.fillMaxSize(), offMainInit = offMainInit)
}
