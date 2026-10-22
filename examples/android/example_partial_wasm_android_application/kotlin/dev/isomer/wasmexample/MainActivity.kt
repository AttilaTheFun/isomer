package dev.isomer.wasmexample

// A NORMAL Kotlin/Compose app (Level 3 incremental adoption) that embeds one
// wasm feature BUNDLE with the Android `WasmView` @Composable — the peer of
// Apple's WasmView / web's <Isomer>. The card's contents are a Swift UI
// compiled to wasm (the same hot_demo reactor the Apple hot-reload example
// runs), executed in-process on WasmKit; everything else is plain Compose.
//
// The feature reads a native feature flag over the swift_ffi dependency DI
// (`Host.flag("promo_banner")`); we answer it true here, so a natively-decided
// promo banner renders inside the wasm surface — the on-device proof that the
// DI round-trips through the JNI bridge.

import dev.isomer.platform.PlatformServicesWasm
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import dev.isomer.runtime.AppWasmBundleProvider
import dev.isomer.runtime.WasmView

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { WasmDemoScreen() }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WasmDemoScreen() {
    val context = LocalContext.current
    // The platform services answer async calls on the main thread.
    val mainHandler = remember { android.os.Handler(android.os.Looper.getMainLooper()) }
    // The packaged reactor renders immediately; a hot-reload server shadows
    // it live when the launch intent carries its URL (the emulator reaches
    // the host Mac at 10.0.2.2):
    //
    //   adb shell am start -n dev.isomer.wasmexample/.MainActivity \
    //       --es hotReloadServer http://10.0.2.2:8787
    // LocalContext is a ContextThemeWrapper in Compose — unwrap to the
    // Activity to reach the launch intent.
    val hotReloadUrl = remember {
        var c: android.content.Context = context
        while (c is android.content.ContextWrapper) {
            if (c is android.app.Activity) break
            c = c.baseContext
        }
        (c as? android.app.Activity)?.intent?.getStringExtra("hotReloadServer")
    }
    val provider = remember {
        AppWasmBundleProvider(context, "hot_demo_release.wasm", hotReloadUrl = hotReloadUrl)
    }
    MaterialTheme {
        Scaffold(
            topBar = { CenterAlignedTopAppBar(title = { Text("Wasm Feature Demo") }) },
        ) { padding ->
            Column(Modifier.fillMaxSize().padding(padding)) {
                Text(
                    "The card below is a SwiftUI feature compiled to wasm, run " +
                        "in-process on WasmKit and rendered with Compose:",
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(16.dp),
                )
                Card(
                    modifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth(),
                    elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
                ) {
                    WasmView(
                        provider = provider,
                        modifier = Modifier.height(420.dp),
                        ffiPrefix = PlatformServicesWasm.FFI_PREFIX,
                        dependencies = PlatformServicesWasm.all(mainHandler, "example_partial_wasm", context.applicationContext),
                    )
                }
            }
        }
    }
}
