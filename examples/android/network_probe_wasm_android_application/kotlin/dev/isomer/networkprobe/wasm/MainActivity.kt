package dev.isomer.networkprobe.wasm

// The network probe as a wasm reactor under WasmView. The app injects
// nothing of its own: an `ffiPrefix` turns the swift_ffi transport on, and
// WasmView adds Foundation's networking (WasmNetworkHosts) to the
// reactor's dependencies by itself.

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import dev.isomer.runtime.AppWasmBundleProvider
import dev.isomer.runtime.WasmView

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            val context = LocalContext.current
            val provider = remember { AppWasmBundleProvider(context, "network_probe.wasm") }
            WasmView(provider = provider, modifier = Modifier.fillMaxSize(), ffiPrefix = "swift_ffi_")
        }
    }
}
