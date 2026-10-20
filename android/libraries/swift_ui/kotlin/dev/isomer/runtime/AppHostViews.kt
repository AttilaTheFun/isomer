package dev.isomer.runtime

// App-authored host views under the Compose renderer: the composable drawn
// for a SwiftUI `PlatformViewRepresentable` whose `kind` the app registers
// here (the Playground's code editor and its run surface, say). The node's
// `v` is the representable's `value`, its `params` the representable's
// parameters; `edit` is the event id `sendEvent(edit, value)` reports a
// changed value through (the representable's `onValueChanged`). Register
// before the runtime starts (the services installer is the place).

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import org.json.JSONObject

object AppHostViews {
    val factories = mutableMapOf<String, @Composable (node: JSONObject, modifier: Modifier, edit: String) -> Unit>()

    /** Reports a representable's changed value (its `onValueChanged`). */
    fun report(edit: String, value: String) {
        if (edit.isEmpty()) return
        IsoEventRouter.lastEventAt = android.os.SystemClock.uptimeMillis()
        IsoEventRouter.sink(edit, value)
    }
}
