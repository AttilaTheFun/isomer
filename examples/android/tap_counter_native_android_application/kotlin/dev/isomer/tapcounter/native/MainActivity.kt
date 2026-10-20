package dev.isomer.tapcounter.native

// The NATIVE Jetpack Compose baseline for the minimal "Tap me" counter benchmark
// (docs/benchmarks.md) — the performance ceiling. Shares no Isomer code (no
// Swift, no wasm, no IsoNode interpreter): just hand-written Compose rendering the
// exact same UI as its compiled-Swift, wasm, Valdi, and React Native twins — a
// counter label + a "Tap me" button. Compare its [native-tap] tap->frame latency
// against the wasm reactor's [wamr-event] on the same device.

import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.draw.clip
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(colorScheme = lightColorScheme()) {
                CounterScreen()
            }
        }
        // Uniform benchmark content signal: Compose composes during the first
        // traversal, so the first draw includes the counter.
        dev.isomer.runtime.ContentFrame.install(window.decorView) { true }
        dev.isomer.runtime.TapProbe.install(this)
    }

    override fun dispatchTouchEvent(ev: android.view.MotionEvent): Boolean {
        dev.isomer.runtime.TapProbe.onTouch(this, ev)
        return super.dispatchTouchEvent(ev)
    }
}

@Composable
private fun CounterScreen() {
    var count by remember { mutableIntStateOf(0) }
    // Measure tap->frame latency the way [wamr-event] does for the wasm path: the
    // click stamps a time, and the first frame that reflects the new count logs
    // how long the whole click->recompose->draw took (typically one ~16ms frame).
    var clickAt by remember { mutableStateOf(0L) }
    LaunchedEffect(count) {
        if (count > 0 && clickAt != 0L) {
            withFrameMillis { }
            Log.i("Isomer", "[native-tap] count=$count latency=${SystemClock.uptimeMillis() - clickAt}ms")
        }
    }

    Column(
        Modifier.fillMaxSize().padding(40.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            "Tapped $count time${if (count == 1) "" else "s"}",
            fontSize = 20.sp,
            color = Color(0xFF888888),
            modifier = Modifier.padding(bottom = 24.dp),
        )
        // Match the shared TapCounter.swift spec exactly (not the Material3 default
        // Button): #5A57D6 fill, 10dp corners, h28/v12 padding, white 17sp semibold.
        Box(
            modifier = Modifier
                .clip(RoundedCornerShape(10.dp))
                .background(Color(0xFF5A57D6))
                .clickable { clickAt = SystemClock.uptimeMillis(); count++; dev.isomer.runtime.TapProbe.markUpdated() }
                .padding(horizontal = 28.dp, vertical = 12.dp),
        ) {
            Text("Tap me", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
        }
    }
}
