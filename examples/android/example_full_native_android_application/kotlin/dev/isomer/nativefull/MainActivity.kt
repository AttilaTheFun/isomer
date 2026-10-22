package dev.isomer.nativefull

// A hand-written, idiomatic Jetpack Compose app — the NATIVE baseline for the
// Android [full|partial] x [compiled|wasm] matrix. It is deliberately NOT part of
// that matrix: it shares no code with Isomer (no Swift, no wasm, no IsoNode
// interpreter), so it's the "ceiling" reference we benchmark our compiled-Swift
// and wasm-delivered renderers against — same look (an Apps list + a tap counter),
// pure-Compose feel. Compare tap->update latency here (logged as [native-tap],
// typically one frame) against the wasm reactor's [iso-tap] on the same device.

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
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Divider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.lightColorScheme
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private data class AppEntry(val title: String, val subtitle: String, val tint: Color)

private val APPS = listOf(
    AppEntry("Wikipedia", "Browse & search articles", Color(0xFF2196F3)),
    AppEntry("Pokédex", "Catalog every Pokémon", Color(0xFFF44336)),
    AppEntry("Hacker News", "Top stories & comments", Color(0xFFFF9800)),
    AppEntry("To-Do", "Tasks by day", Color(0xFF26C6DA)),
    AppEntry("Meme Creator", "Caption a photo", Color(0xFF4CAF50)),
    AppEntry("Date Planner", "Plan events by day", Color(0xFFAB47BC)),
    AppEntry("Map Explorer", "Pan, zoom, rotate & tilt", Color(0xFF5C6BC0)),
)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(colorScheme = lightColorScheme()) {
                RootScreen()
            }
        }
    }
}

@Composable
private fun RootScreen() {
    var tab by remember { mutableStateOf(0) }
    var selected by remember { mutableStateOf<AppEntry?>(null) }

    Scaffold(
        bottomBar = {
            NavigationBar {
                NavigationBarItem(
                    selected = tab == 0,
                    onClick = { tab = 0; selected = null },
                    icon = { Text("▦", fontSize = 20.sp) },
                    label = { Text("Apps") },
                )
                NavigationBarItem(
                    selected = tab == 1,
                    onClick = { tab = 1; selected = null },
                    icon = { Text("≡", fontSize = 20.sp) },
                    label = { Text("Gallery") },
                )
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                tab == 1 -> Placeholder("Gallery")
                selected != null -> DetailScreen(selected!!)
                else -> AppsList(onOpen = { selected = it })
            }
        }
    }
}

@Composable
private fun AppsList(onOpen: (AppEntry) -> Unit) {
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 20.dp)) {
        item {
            Text(
                "Apps",
                fontSize = 40.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(top = 24.dp, bottom = 12.dp),
            )
        }
        items(APPS) { app ->
            AppRow(app, onClick = { onOpen(app) })
            Divider(color = Color(0x11000000))
        }
    }
}

@Composable
private fun AppRow(app: AppEntry, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(52.dp).background(app.tint, RoundedCornerShape(12.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Text(app.title.take(1), color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(app.title, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
            Text(app.subtitle, fontSize = 16.sp, color = Color(0xFF888888))
        }
        Text("›", fontSize = 24.sp, color = Color(0xFFBBBBBB))
    }
}

@Composable
private fun DetailScreen(app: AppEntry) {
    var count by remember { mutableIntStateOf(0) }
    var enabled by remember { mutableStateOf(true) }
    // Measure tap->frame latency the way [iso-tap] does for the wasm path: the
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
        Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Text(app.title, fontSize = 36.sp, fontWeight = FontWeight.Bold)
        Text(app.subtitle, fontSize = 18.sp, color = Color(0xFF888888))
        Spacer(Modifier.height(24.dp))
        Text("Tapped $count times", fontSize = 20.sp, color = Color(0xFF888888))
        Button(onClick = { clickAt = SystemClock.uptimeMillis(); count++ }) {
            Text("Tap me", fontSize = 20.sp)
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Feature enabled", fontSize = 20.sp)
            Spacer(Modifier.width(12.dp))
            Switch(checked = enabled, onCheckedChange = { enabled = it })
        }
    }
}

@Composable
private fun Placeholder(name: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(name, fontSize = 28.sp, color = Color(0xFF888888), textAlign = TextAlign.Center)
    }
}
