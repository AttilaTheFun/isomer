package dev.isomer.runtime

// Wasm pages inside a compiled Isomer app: a SwiftUI
// `PlatformViewRepresentable` of the registered kind is drawn as a
// `WasmView`, each page in a tree of its own (an IsoTreeState), so its tree
// and its taps never meet the app's. The engine is bound in the app's own
// library (`isomer_android_app(wasm_view = True)`), whose Swift runtime it
// shares. Register before the runtime starts (the services installer).

import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import org.json.JSONObject

object WasmPages {
    /** Draws the representables of [kind] as wasm pages. The bundle comes
     *  from [provider], given the node (its `v` is the representable's
     *  `value`); by default the packaged asset `v` names, refreshed from a
     *  hot-reload server as `AppWasmBundleProvider` is. A page is made again
     *  when its `value` changes. */
    fun register(
        kind: String = "wasm:page",
        ffiPrefix: String? = null,
        dependencies: List<WasmDependency> = emptyList(),
        provider: (android.content.Context, JSONObject) -> WasmBundleProvider =
            { context, node -> AppWasmBundleProvider(context, node.optString("v")) },
    ) {
        AppHostViews.factories[kind] = { node, modifier, _ ->
            val context = LocalContext.current
            val page = node.optString("v")
            val treeState = remember(page) { IsoTreeState() }
            val bundles = remember(page) { provider(context, node) }
            androidx.compose.runtime.key(page) {
                WasmView(
                    provider = bundles,
                    modifier = modifier,
                    treeState = treeState,
                    ffiPrefix = ffiPrefix,
                    dependencies = dependencies,
                )
            }
        }
    }
}
