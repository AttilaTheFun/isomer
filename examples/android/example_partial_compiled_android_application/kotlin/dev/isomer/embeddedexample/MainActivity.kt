package dev.isomer.embeddedexample

// A NORMAL Kotlin/Compose app (Level 3 incremental adoption): everything on
// this screen is plain Material 3 owned by the host — except the "Order
// status" card, which is SwiftUI (examples/shared/embedded_example) hosted by the
// `Isomer()` composable. The SwiftUI side keeps its own @State; the
// host app never sees it.

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.isomer.runtime.Isomer

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { AcmeStoreScreen() }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AcmeStoreScreen() {
    MaterialTheme {
        Scaffold(
            topBar = { CenterAlignedTopAppBar(title = { Text("Acme Store") }) },
        ) { padding ->
            LazyColumn(Modifier.fillMaxSize().padding(padding)) {
                item {
                    Text(
                        "Account",
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.padding(16.dp),
                    )
                }
                item {
                    Column {
                        ListItem(
                            headlineContent = { Text("Payment methods") },
                            supportingContent = { Text("Visa ending 4242") },
                        )
                        HorizontalDivider()
                        ListItem(
                            headlineContent = { Text("Addresses") },
                            supportingContent = { Text("Home, Work") },
                        )
                    }
                }
                item {
                    Text(
                        "Latest order (SwiftUI)",
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.padding(16.dp),
                    )
                }
                item {
                    // The embedded SwiftUI surface. The host sizes the frame;
                    // SwiftUI owns everything inside it.
                    Card(
                        modifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth(),
                        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
                    ) {
                        Isomer(Modifier.height(340.dp))
                    }
                }
                item {
                    Text(
                        "Everything above the card and below it is plain Kotlin " +
                            "Compose; the card's contents are SwiftUI.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(16.dp),
                    )
                }
            }
        }
    }
}
