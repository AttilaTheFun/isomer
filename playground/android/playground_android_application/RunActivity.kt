// The running build: the compiled program (a `iso_hot` reactor) in a
// WasmView, full screen, in a process of its own (`:run` in the manifest).
// Its own process because the Compose renderer's tree state is one per
// process — the Playground's own screens and the program it runs cannot
// share it — and so a program that crashes takes only this window down.
// Back closes it, as does a shake (the accelerometer; a dialog asks first,
// as the iOS run cover's shake does); the Playground learns of that through
// a broadcast and takes its run cover down.

package dev.isomer.runtime

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import dev.isomer.platform.PlatformServicesWasm
import java.io.File

class RunActivity : ComponentActivity() {
    companion object {
        const val EXTRA_WASM = "wasm"
        const val ACTION_STOPPED = "dev.isomer.playground.RUN_STOPPED"
    }

    private var askingToLeave by mutableStateOf(false)
    private var lastShake = 0L
    private val shakes = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            val (x, y, z) = event.values
            val g = Math.sqrt((x * x + y * y + z * z).toDouble()) / SensorManager.GRAVITY_EARTH
            val now = System.currentTimeMillis()
            if (g > 2.7 && now - lastShake > 1500) { lastShake = now; askingToLeave = true }
        }
        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
    }

    override fun onResume() {
        super.onResume()
        val sensors = getSystemService(SENSOR_SERVICE) as SensorManager
        sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let { sensors.registerListener(shakes, it, SensorManager.SENSOR_DELAY_GAME) }
    }

    override fun onPause() {
        (getSystemService(SENSOR_SERVICE) as SensorManager).unregisterListener(shakes)
        super.onPause()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ImagePickerHost.attach(this)
        val wasm = File(intent.getStringExtra(EXTRA_WASM) ?: run { finish(); return })
        val main = Handler(Looper.getMainLooper())
        val dependencies = PlatformServicesWasm.all(
            main, "playground_run", applicationContext,
            pickImage = ImagePickerHost::pick,
        )
        setContent {
            WasmView(
                provider = FileWasmBundleProvider(wasm),
                modifier = Modifier.fillMaxSize(),
                ffiPrefix = PlatformServicesWasm.FFI_PREFIX,
                dependencies = dependencies,
            )
            // The dialog in the system's appearance (WasmView themes itself;
            // this content has no theme of its own otherwise).
            if (askingToLeave) MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()) {
                AlertDialog(
                    onDismissRequest = { askingToLeave = false },
                    title = { Text("Back to the Playground?") },
                    text = { Text("Shake any time to get back here.") },
                    confirmButton = { TextButton(onClick = { finish() }) { Text("Leave") } },
                    dismissButton = { TextButton(onClick = { askingToLeave = false }) { Text("Keep running") } },
                )
            }
        }
    }

    override fun onDestroy() {
        sendBroadcast(Intent(ACTION_STOPPED).setPackage(packageName))
        super.onDestroy()
    }
}

/** A bundle read from a file the compile wrote (no updates). */
class FileWasmBundleProvider(private val file: File) : WasmBundleProvider {
    override suspend fun initialBundle(): WasmServiceBundle? =
        if (file.exists()) WasmServiceBundle(file.name, file.readBytes()) else null
}
