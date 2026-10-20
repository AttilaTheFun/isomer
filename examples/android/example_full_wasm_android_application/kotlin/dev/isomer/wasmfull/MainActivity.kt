package dev.isomer.wasmfull

// Level 4 adoption, the "full x wasm" cell of the Android matrix: the WHOLE
// shared SwiftUI @main App (//examples/shared/example_application) shipped as ONE wasm
// bundle and hosted full-screen by `WasmView`. The compiled twin is
// //examples/android/example_full_compiled_android_application — the SAME
// app, but its Swift is compiled into the APK as a .so. Here the app's code is
// a wasm reactor run in-process under WAMR (a C interpreter) and drawn by the
// Swift-free Compose interpreter, so the host APK carries NO compiled Swift.
//
// The trade-off (docs/adoption_levels.md): wasm delivery gives runtime-updatable
// code and a smaller/Swift-free host at some runtime cost; compiled gives peak
// performance. Nav, state, and every non-GPU tab run entirely inside the wasm.

import dev.isomer.platform.PlatformServicesWasm
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
        // The image chooser (ImagePickerService) registers its launcher here.
        dev.isomer.runtime.ImagePickerHost.attach(this)
        setContent { FullWasmApp() }
    }
}

@Composable
fun FullWasmApp() {
    val context = LocalContext.current
    // The whole app packaged as assets/example_full_release.wasm. Point
    // `hotReloadUrl` at a dev server for live reload (same protocol as Apple).
    val provider = remember {
        AppWasmBundleProvider(context, "example_full_release.wasm")
    }
    // The platform services (shared/platform_services) as blob dispatchers;
    // the view just carries them to the runtime.
    val mainHandler = androidx.compose.runtime.remember {
        android.os.Handler(android.os.Looper.getMainLooper())
    }
    WasmView(
        provider = provider,
        modifier = Modifier.fillMaxSize(),
        ffiPrefix = PlatformServicesWasm.FFI_PREFIX,
        dependencies = PlatformServicesWasm.all(
            mainHandler, "example_full_wasm", context.applicationContext,
            pickImage = dev.isomer.runtime.ImagePickerHost::pick),
    )
}
