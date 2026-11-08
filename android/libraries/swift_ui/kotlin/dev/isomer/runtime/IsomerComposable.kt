package dev.isomer.runtime

// Incremental adoption (Level 3) for Compose host apps: the `Isomer()`
// composable drops a SwiftUI surface into an existing Compose hierarchy —
// the Compose analogue of `UIHostingController`. The Swift side decides what
// renders (its `@main` App, or whatever a `IsomerHostingController`
// installed); this composable boots the runtime on first composition and
// forwards the host lifecycle to `@Environment(\.scenePhase)`.

import android.app.Activity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver

/** Install the native compiled-Swift event sink: node events feed the in-process
 * Swift runtime through SwiftUIBridge, then the tree re-renders and Choreographer
 * frames keep coming while a transition runs. The interpreter's default sink is a
 * no-op (it must not reference SwiftUIBridge — that keeps it Swift-free for the
 * wasm cell); the native path opts in here. */
internal fun installNativeEventSink() {
    IsoEventRouter.sink = { id, value ->
        android.os.Trace.beginSection("iso:event")
        try { SwiftUIBridge.nativeHostEvent(id, value) } finally { android.os.Trace.endSection() }
        // Render only what the event changed (a scrolled list's row report
        // usually changes nothing).
        if (SwiftUIBridge.nativeWantsRender()) {
            NativeBridge.render()
            NativeBridge.pumpFramesIfNeeded()
        }
    }
    IsoEventRouter.keySink = { id, value ->
        val handled = SwiftUIBridge.nativeKeyEvent(id, value)
        if (SwiftUIBridge.nativeWantsRender()) {
            NativeBridge.render()
            NativeBridge.pumpFramesIfNeeded()
        }
        handled
    }
}

/** The native compiled-Swift Compose entry: renders the shared tree and wires
 * system back into the runtime. (The wasm path renders `IsoNode` directly with
 * its own theming; see //android/libraries/wasm_view WasmView.) */
@Composable
fun IsoTree() {
    val activity = LocalContext.current as? Activity
    // The window's size, told to the runtime whenever it changes. The runtime
    // starts once, with the size it had then; turned, the phone makes the
    // Activity again but the runtime runs on, and it built for the old width
    // (its size class too) while the columns here were laid out for the new:
    // a regular split view around a compact sidebar.
    val configuration = LocalConfiguration.current
    LaunchedEffect(configuration.screenWidthDp, configuration.screenHeightDp) {
        val metrics = (activity ?: return@LaunchedEffect).resources.displayMetrics
        val width = metrics.widthPixels / metrics.density
        val height = metrics.heightPixels / metrics.density
        NativeBridge.dispatchToRuntime { NativeBridge.nativeResize(width, height) }
    }
    // Depend on imageTick so async image loads recompose.
    @Suppress("UNUSED_VARIABLE") val tick = ComposeTreeState.imageTick.value
    val root = ComposeTreeState.tree.value ?: return
    val dark = isSystemInDarkTheme()
    val scheme = isoColorScheme(dark)
    MaterialGrounds.scheme = scheme
    MaterialGrounds.dark = dark
    MaterialTheme(colorScheme = scheme) {
        BackHandler {
            if (NativeBridge.nativeBack()) {
                NativeBridge.render()
                NativeBridge.pumpFramesIfNeeded()
            } else {
                activity?.finish()
            }
        }
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            IsoRoot(root)
        }
    }
}

@Composable
fun Isomer(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    remember {
        (context as? Activity)?.let { IsomerRuntime.startCompose(it) }
        true
    }
    // Host lifecycle -> @Environment(\.scenePhase).
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> IsomerRuntime.setScenePhase("active")
                Lifecycle.Event.ON_PAUSE -> IsomerRuntime.setScenePhase("inactive")
                Lifecycle.Event.ON_STOP -> IsomerRuntime.setScenePhase("background")
                else -> {}
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    Box(modifier.fillMaxSize()) { IsoTree() }
}
