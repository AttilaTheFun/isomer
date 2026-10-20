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
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.ui.graphics.Color
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

/** The Material scheme for the system's appearance, as Swift is told it:
 * Material 3's tonal roles (its surfaces and containers, not iOS's white and
 * grey), seeded from the accent SwiftUI resolves (`Color.accentColor`, the
 * system blue) so Material's own controls and the app's tinted views agree.
 * Swift's named grounds (a grouped list's, a cell's, a sheet's) are drawn in
 * these roles too (`MaterialGrounds`). */
fun isoColorScheme(dark: Boolean): ColorScheme =
    if (dark) darkColorScheme(
        primary = Color(0xFF9ECAFF), onPrimary = Color(0xFF003258),
        primaryContainer = Color(0xFF00497D), onPrimaryContainer = Color(0xFFD1E4FF),
        secondary = Color(0xFFBBC7DB), onSecondary = Color(0xFF253140),
        secondaryContainer = Color(0xFF3B4858), onSecondaryContainer = Color(0xFFD7E3F7),
        tertiary = Color(0xFFD6BEE4), onTertiary = Color(0xFF3B2948),
        tertiaryContainer = Color(0xFF523F5F), onTertiaryContainer = Color(0xFFF2DAFF),
        background = Color(0xFF111418), onBackground = Color(0xFFE1E2E8),
        surface = Color(0xFF111418), onSurface = Color(0xFFE1E2E8),
        surfaceVariant = Color(0xFF42474E), onSurfaceVariant = Color(0xFFC2C7CF),
        surfaceContainerLowest = Color(0xFF0C0E13), surfaceContainerLow = Color(0xFF191C20),
        surfaceContainer = Color(0xFF1D2024), surfaceContainerHigh = Color(0xFF282A2F),
        surfaceContainerHighest = Color(0xFF33353A), surfaceBright = Color(0xFF37393E), surfaceDim = Color(0xFF111418),
        outline = Color(0xFF8C9199), outlineVariant = Color(0xFF42474E),
        inverseSurface = Color(0xFFE1E2E8), inverseOnSurface = Color(0xFF2E3135), inversePrimary = Color(0xFF0061A4),
    )
    else lightColorScheme(
        primary = Color(0xFF0061A4), onPrimary = Color(0xFFFFFFFF),
        primaryContainer = Color(0xFFD1E4FF), onPrimaryContainer = Color(0xFF001D36),
        secondary = Color(0xFF535F70), onSecondary = Color(0xFFFFFFFF),
        secondaryContainer = Color(0xFFD7E3F7), onSecondaryContainer = Color(0xFF101C2B),
        tertiary = Color(0xFF6B5778), onTertiary = Color(0xFFFFFFFF),
        tertiaryContainer = Color(0xFFF2DAFF), onTertiaryContainer = Color(0xFF251431),
        background = Color(0xFFF8F9FF), onBackground = Color(0xFF191C20),
        surface = Color(0xFFF8F9FF), onSurface = Color(0xFF191C20),
        surfaceVariant = Color(0xFFDFE2EB), onSurfaceVariant = Color(0xFF42474E),
        surfaceContainerLowest = Color(0xFFFFFFFF), surfaceContainerLow = Color(0xFFF2F3FA),
        surfaceContainer = Color(0xFFECEEF4), surfaceContainerHigh = Color(0xFFE6E8EE),
        surfaceContainerHighest = Color(0xFFE0E2E8), surfaceBright = Color(0xFFF8F9FF), surfaceDim = Color(0xFFD8DAE0),
        outline = Color(0xFF73777F), outlineVariant = Color(0xFFC2C7CF),
        inverseSurface = Color(0xFF2E3135), inverseOnSurface = Color(0xFFEFF0F7), inversePrimary = Color(0xFF9ECAFF),
    )

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
