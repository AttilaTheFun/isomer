package dev.isomer.remote

// Isomer's Android thin client as an app: an app's SwiftUI runs on a server
// (an app built headless, serving itself: ISO_DRIVE_LISTEN), and this
// APK, with no Swift and no native library, draws it with the Compose
// renderer over a WebSocket (dev.isomer.runtime.IsomerRemote).
//
//   adb shell am start -n dev.isomer.remote/.MainActivity \
//       -e url ws://10.0.2.2:8090/session -e ISO_STORYBOOK_STORY controls.toggle
//
// `url` is the app's session (the emulator's 10.0.2.2 is its host's
// loopback); every ISO_ extra is the app's launch environment.

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import dev.isomer.runtime.IsomerRemote

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.getStringExtra("url") ?: "ws://10.0.2.2:8090/session"
        val extras = intent.extras
        val environment = extras?.keySet().orEmpty()
            .filter { it.startsWith("ISO_") }
            .associateWith { extras?.get(it)?.toString() ?: "" }
        setContent {
            IsomerRemote(url, environment = environment, onCommand = { key, value ->
                if (key == "windowTitle") title = value
            })
        }
    }
}
