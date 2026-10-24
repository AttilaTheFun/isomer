package dev.isomer.runtime

import android.app.Activity
import android.app.ActivityManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.WindowInsetsController
import android.view.WindowManager

/**
 * The app-facing runtime facade. Embedding surfaces (`Isomer()`
 * composable, `IsomerFragment`, `IsomerView`) and generated
 * `MainActivity`s route through here: starting the Swift runtime, forwarding
 * the Activity lifecycle to `@Environment(\.scenePhase)`, delivering VIEW
 * intents to `.onOpenURL`, and applying `platformCommand`s (window title,
 * status-bar style, keep-screen-on) to the current Activity.
 */
object IsomerRuntime {
    private var started = false

    /**
     * What the app's Swift needs before any of it runs: its directories in
     * the environment, where Foundation's FileManager finds them
     * (AppDirectories), and Foundation's networking (NetworkHosts). Each
     * embedding surface calls it as it is made, on the main thread, and
     * the generated MainActivity first of all; once is enough.
     */
    fun prepare(context: Context) {
        AppDirectories.prepare(context)
        NetworkHosts.install()
    }

    /**
     * Boot the Swift runtime under the JetpackComposeRenderer.
     * Idempotent — the first embedding surface wires everything up. The GL
     * (SwiftGPU-drawn) path boots via `IsomerView` instead, on surface
     * creation.
     */
    fun startCompose(activity: Activity, embedded: Boolean = true) {
        prepare(activity)
        attach(activity, embedded)
        if (started) return
        started = true
        // The interpreter's event sink defaults to a no-op (Swift-free); the
        // native compiled-Swift path opts into the SwiftUIBridge-backed sink.
        installNativeEventSink()
        NativeBridge.appContext = activity.applicationContext
        NativeBridge.density = activity.resources.displayMetrics.density
        NativeBridge.onImageLoaded = {
            activity.runOnUiThread { ComposeTreeState.imageTick.value++ }
        }
        val metrics = activity.resources.displayMetrics
        NativeBridge.nativeStart(
            metrics.widthPixels / NativeBridge.density,
            metrics.heightPixels / NativeBridge.density,
            renderer = "jetpackCompose",
        )
    }

    /** Point platform commands (title, status bar, …) at this Activity.
     * Embedded surfaces (`embedded = true`, the default for the composable /
     * fragment) don't reconfigure the host's window title. */
    fun attach(activity: Activity, embedded: Boolean = true) {
        NativeBridge.platformCommandHandler = { key, value ->
            if (!(embedded && key == "windowTitle")) {
                activity.runOnUiThread { apply(activity, key, value) }
            }
        }
        // Initial system appearance; call [setColorScheme] again from
        // onConfigurationChanged for live dark-mode toggles.
        setColorScheme(activity.resources.configuration)
    }

    /** Forward the system appearance (initially via [attach]; on change from
     * the Activity's onConfigurationChanged). Maps `uiMode` night mode to the
     * runtime's adaptive semantic palette. */
    fun setColorScheme(configuration: android.content.res.Configuration) {
        val dark = (configuration.uiMode and
            android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
            android.content.res.Configuration.UI_MODE_NIGHT_YES
        NativeBridge.dispatchToRuntime { SwiftUIBridge.nativeSetColorScheme(dark) }
    }

    /**
     * Forward the Activity lifecycle: call with "active" from onResume,
     * "inactive" from onPause, "background" from onStop.
     */
    fun setScenePhase(phase: String) {
        NativeBridge.dispatchToRuntime { SwiftUIBridge.nativeSetScenePhase(phase) }
    }

    /** Deliver a VIEW intent's data URL to `.onOpenURL` handlers. */
    fun openURL(url: Uri?) {
        val value = url?.toString() ?: return
        NativeBridge.dispatchToRuntime { SwiftUIBridge.nativeOpenURL(value) }
    }

    /** The system's haptic nearest a SwiftUI feedback ("success",
     * "impact:heavy:1.0"…); the newer constants where the system has them. */
    private fun hapticConstant(name: String): Int {
        val parts = name.split(":")
        val api30 = Build.VERSION.SDK_INT >= 30
        val api34 = Build.VERSION.SDK_INT >= 34
        return when (parts[0]) {
            "success", "pathComplete" ->
                if (api30) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.VIRTUAL_KEY
            "error" -> if (api30) HapticFeedbackConstants.REJECT else HapticFeedbackConstants.LONG_PRESS
            "warning" -> HapticFeedbackConstants.LONG_PRESS
            "selection" -> HapticFeedbackConstants.CLOCK_TICK
            "increase", "decrease" ->
                if (api34) HapticFeedbackConstants.SEGMENT_TICK else HapticFeedbackConstants.CLOCK_TICK
            "alignment" ->
                if (api34) HapticFeedbackConstants.SEGMENT_FREQUENT_TICK else HapticFeedbackConstants.CLOCK_TICK
            "start" -> if (api30) HapticFeedbackConstants.GESTURE_START else HapticFeedbackConstants.VIRTUAL_KEY
            "stop" -> if (api30) HapticFeedbackConstants.GESTURE_END else HapticFeedbackConstants.VIRTUAL_KEY
            "levelChange" -> HapticFeedbackConstants.CONTEXT_CLICK
            "impact" -> when (parts.getOrNull(1)) {
                "light", "soft" -> HapticFeedbackConstants.KEYBOARD_TAP
                "heavy", "rigid" -> HapticFeedbackConstants.LONG_PRESS
                else -> HapticFeedbackConstants.VIRTUAL_KEY
            }
            else -> HapticFeedbackConstants.VIRTUAL_KEY
        }
    }

    private fun apply(activity: Activity, key: String, value: String) {
        when (key) {
            // `ShareLink`: the system's share sheet.
            "share" -> {
                val send = android.content.Intent(android.content.Intent.ACTION_SEND)
                    .setType("text/plain")
                    .putExtra(android.content.Intent.EXTRA_TEXT, value)
                activity.startActivity(android.content.Intent.createChooser(send, null))
            }
            "windowTitle" -> {
                activity.title = value
                @Suppress("DEPRECATION")
                activity.setTaskDescription(ActivityManager.TaskDescription(value))
            }
            "statusBarStyle" -> if (Build.VERSION.SDK_INT >= 30) {
                activity.window.insetsController?.setSystemBarsAppearance(
                    if (value != "dark") WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS else 0,
                    WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS,
                )
            }
            "keepScreenOn" -> {
                if (value == "1") {
                    activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
            }
            // `UIPasteboard.general.string = …`: the system clipboard.
            "copy" -> {
                val clipboard = activity.getSystemService(ClipboardManager::class.java)
                clipboard?.setPrimaryClip(ClipData.newPlainText("", value))
            }
            // `.sensoryFeedback`: the view's haptic, as the system's
            // settings allow.
            "haptic" -> activity.window.decorView.performHapticFeedback(hapticConstant(value))
            // Unknown keys are ignored by design (forward-compatible channel).
        }
    }
}
