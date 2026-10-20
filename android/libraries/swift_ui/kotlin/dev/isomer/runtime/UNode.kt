package dev.isomer.runtime

import androidx.compose.runtime.Immutable
import org.json.JSONObject

/**
 * A retained render-tree node. `json` holds the node's OWN attributes (the
 * former {k, v, ...} shape the interpreters walk — never the children);
 * `children` are the retained child nodes; `sig` is a deterministic signature of
 * the own attributes (children excluded) used to diff cheaply.
 *
 * Marked [Immutable] so `IsoNode(n: UNode, ...)` is a *skippable* composable:
 * when the diff/reconcile keeps a subtree's `UNode` reference unchanged, Compose
 * skips recomposing it — only the changed views redraw. The immutability promise
 * is honored: a UNode is never mutated after construction; a changed node yields
 * a fresh UNode and an unchanged one is reused by reference.
 *
 * (A Compose-free twin once existed for the removed classic-Views renderer.)
 */
@Immutable
class UNode(
    val json: JSONObject,
    val children: List<UNode>,
    val sig: String,
) {
    /** A GeometryReader is this node or in its content (not in a
     *  `.background`/`.overlay` layer): it takes all the space it is
     *  offered, so this node does too, as in SwiftUI. */
    val holdsReader: Boolean by lazy(LazyThreadSafetyMode.NONE) {
        val params = json.optJSONObject("params")
        !params?.optString("geo").isNullOrEmpty() ||
            children.any { it.json.optJSONObject("params")?.optString("layer").isNullOrEmpty() && it.holdsReader }
    }
}
