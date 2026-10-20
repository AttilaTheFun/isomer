package dev.isomer.runtime

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.json.JSONArray
import org.json.JSONObject

// UNode (the retained node this decoder emits) lives in its own file:
// UNode.kt (@Immutable-annotated, skippable in Compose).

/**
 * Decodes the render-tree FlatBuffer (shared/renderers/tree.fbs) into a retained
 * [UNode] tree. Hand-written against the standard FlatBuffers wire format; the
 * field slot numbers MUST match the numbered comments in tree.fbs (append-only).
 */
object FlatTree {
    private val KINDS = arrayOf(
        "box", "text", "shape", "stack", "spacer", "divider", "scroll", "image",
        "textField", "slider", "gradient", "hostView", "progress", "presentation",
    )
    private val AXES = arrayOf("h", "v", "z")
    private val ALIGN_H = arrayOf("leading", "center", "trailing")
    private val ALIGN_V = arrayOf("top", "center", "bottom")
    private val SHAPES = arrayOf("rect", "circle", "capsule")
    private val STYLES = arrayOf("sheet", "popover", "alert")

    private fun indirect(buf: ByteBuffer, pos: Int): Int = pos + buf.getInt(pos)

    /** Absolute position of field `slot` inside the table at `table`, or 0. */
    private fun field(buf: ByteBuffer, table: Int, slot: Int): Int {
        val vtable = table - buf.getInt(table)
        val vtSize = buf.getShort(vtable).toInt() and 0xFFFF
        val entry = 4 + 2 * slot
        if (entry >= vtSize) return 0
        val offset = buf.getShort(vtable + entry).toInt() and 0xFFFF
        return if (offset == 0) 0 else table + offset
    }

    private fun string(buf: ByteBuffer, pos: Int): String {
        val data = indirect(buf, pos)
        val length = buf.getInt(data)
        val out = ByteArray(length)
        for (i in 0 until length) out[i] = buf.get(data + 4 + i)
        return String(out, Charsets.UTF_8)
    }

    private fun color(buf: ByteBuffer, pos: Int): JSONArray = JSONArray().apply {
        put(buf.getFloat(pos).toDouble())
        put(buf.getFloat(pos + 4).toDouble())
        put(buf.getFloat(pos + 8).toDouble())
        put(buf.getFloat(pos + 12).toDouble())
    }

    /**
     * Decodes the `Node` table at `table` into a [UNode]. Attributes go into the
     * JSONObject (slot order 0..43); children (slot 44) become retained [UNode]s.
     * The [StringBuilder] `sig` accumulates a deterministic own-signature: each
     * present field appends `slot:value;` in slot order, so two nodes with equal
     * own attributes produce byte-identical sigs regardless of hash-map order.
     */
    private fun node(buf: ByteBuffer, table: Int): UNode {
        val n = JSONObject()
        val sig = StringBuilder()
        fun sig(slot: Int, value: Any) { sig.append(slot).append(':').append(value).append(';') }

        val kindPos = field(buf, table, 0)
        val kind = KINDS.getOrElse(if (kindPos != 0) buf.get(kindPos).toInt() else 0) { "box" }
        n.put("k", kind)
        sig(0, kind)
        var pos = field(buf, table, 1)
        if (pos != 0) { val s = string(buf, pos); n.put("v", s); sig(1, s) }
        pos = field(buf, table, 2)
        if (pos != 0) { val d = buf.getDouble(pos); n.put("v", d); sig(2, d) } // numeric value
        pos = field(buf, table, 3)
        if (pos != 0) { val s = string(buf, pos); n.put("id", s); sig(3, s) }
        pos = field(buf, table, 4)
        if (pos != 0) { val d = buf.getDouble(pos); n.put("size", d); sig(4, d) }
        pos = field(buf, table, 5)
        if (pos != 0) { val i = buf.getInt(pos); n.put("weight", i); sig(5, i) }
        pos = field(buf, table, 6)
        if (pos != 0) { val c = color(buf, pos); n.put("color", c); sig(6, c) }
        pos = field(buf, table, 7)
        if (pos != 0) { val i = buf.getInt(pos); n.put("lines", i); sig(7, i) }
        pos = field(buf, table, 8)
        if (pos != 0) { val s = SHAPES[buf.get(pos).toInt()]; n.put("shape", s); sig(8, s) }
        pos = field(buf, table, 9)
        if (pos != 0) { val c = color(buf, pos); n.put("fill", c); sig(9, c) }
        pos = field(buf, table, 10)
        if (pos != 0) { val c = color(buf, pos); n.put("stroke", c); sig(10, c) }
        pos = field(buf, table, 11)
        if (pos != 0) { val d = buf.getDouble(pos); n.put("strokeWidth", d); sig(11, d) }
        pos = field(buf, table, 12)
        if (pos != 0) { val s = AXES[buf.get(pos).toInt()]; n.put("axis", s); sig(12, s) }
        else if (kind == "stack" || kind == "scroll") { n.put("axis", "h"); sig(12, "h") }
        pos = field(buf, table, 13)
        if (pos != 0) { val d = buf.getDouble(pos); n.put("spacing", d); sig(13, d) }
        pos = field(buf, table, 14)
        if (pos != 0) { val d = buf.getDouble(pos); n.put("min", d); sig(14, d) }
        pos = field(buf, table, 15)
        if (pos != 0) { val s = string(buf, pos); n.put("src", s); sig(15, s) }
        pos = field(buf, table, 16)
        if (pos != 0) { val b = buf.get(pos).toInt() != 0; n.put("remote", b); sig(16, b) }
        pos = field(buf, table, 17)
        if (pos != 0) { val b = buf.get(pos).toInt() != 0; n.put("resizable", b); sig(17, b) }
        pos = field(buf, table, 18)
        if (pos != 0) { val b = buf.get(pos).toInt() != 0; n.put("fit", b); sig(18, b) }
        pos = field(buf, table, 19)
        if (pos != 0) { val s = string(buf, pos); n.put("placeholder", s); sig(19, s) }
        pos = field(buf, table, 20)
        if (pos != 0) { val s = string(buf, pos); n.put("edit", s); sig(20, s) }
        pos = field(buf, table, 21)
        if (pos != 0) { val s = string(buf, pos); n.put("view", s); sig(21, s) }
        pos = field(buf, table, 22)
        if (pos != 0) {
            val vec = indirect(buf, pos)
            val count = buf.getInt(vec)
            val options = JSONArray()
            for (i in 0 until count) options.put(string(buf, vec + 4 + i * 4))
            n.put("options", options)
            sig(22, options)
        }
        pos = field(buf, table, 23)
        if (pos != 0) {
            val vec = indirect(buf, pos)
            val count = buf.getInt(vec)
            val params = JSONObject()
            for (i in 0 until count) {
                val kv = indirect(buf, vec + 4 + i * 4)
                params.put(string(buf, field(buf, kv, 0)), string(buf, field(buf, kv, 1)))
            }
            n.put("params", params)
            // Params keys are emitted sorted by the encoder, but JSONObject
            // iteration is unordered; sign each entry in a stable key order.
            val keys = params.keys().asSequence().sorted().toList()
            for (k in keys) sig.append("23.").append(k).append(':').append(params.opt(k)).append(';')
        }
        pos = field(buf, table, 24)
        if (pos != 0) { val b = buf.get(pos).toInt() != 0; n.put("growW", b); sig(24, b) }
        pos = field(buf, table, 25)
        if (pos != 0) { val b = buf.get(pos).toInt() != 0; n.put("growH", b); sig(25, b) }
        pos = field(buf, table, 26)
        if (pos != 0) { val s = ALIGN_H[buf.get(pos).toInt()]; n.put("alignH", s); sig(26, s) }
        pos = field(buf, table, 27)
        if (pos != 0) { val s = ALIGN_V[buf.get(pos).toInt()]; n.put("alignV", s); sig(27, s) }
        pos = field(buf, table, 28)
        if (pos != 0) {
            val shadow = JSONObject().apply {
                put("color", color(buf, pos))
                put("radius", buf.getFloat(pos + 16).toDouble())
                put("x", buf.getFloat(pos + 20).toDouble())
                put("y", buf.getFloat(pos + 24).toDouble())
            }
            n.put("shadow", shadow)
            sig(28, shadow)
        }
        pos = field(buf, table, 29)
        if (pos != 0) {
            val vec = indirect(buf, pos)
            val count = buf.getInt(vec)
            val padding = JSONArray()
            for (i in 0 until count) padding.put(buf.getDouble(vec + 4 + i * 8))
            n.put("padding", padding)
            sig(29, padding)
        }
        pos = field(buf, table, 30)
        if (pos != 0) { val d = buf.getDouble(pos); n.put("width", d); sig(30, d) }
        pos = field(buf, table, 31)
        if (pos != 0) { val d = buf.getDouble(pos); n.put("height", d); sig(31, d) }
        pos = field(buf, table, 32)
        if (pos != 0) { val b = buf.get(pos).toInt() != 0; n.put("expandW", b); sig(32, b) }
        pos = field(buf, table, 33)
        if (pos != 0) { val b = buf.get(pos).toInt() != 0; n.put("expandH", b); sig(33, b) }
        pos = field(buf, table, 34)
        if (pos != 0) { val d = buf.getDouble(pos); n.put("radius", d); sig(34, d) }
        pos = field(buf, table, 35)
        if (pos != 0) { val d = buf.getDouble(pos); n.put("opacity", d); sig(35, d) }
        pos = field(buf, table, 36)
        if (pos != 0) { val c = color(buf, pos); n.put("bg", c); sig(36, c) }
        pos = field(buf, table, 37)
        if (pos != 0) { val s = string(buf, pos); n.put("gradient", s); sig(37, s) }
        pos = field(buf, table, 38)
        if (pos != 0) { val s = string(buf, pos); n.put("tap", s); sig(38, s) }
        pos = field(buf, table, 39)
        if (pos != 0) { val i = buf.getInt(pos); n.put("feedback", i); sig(39, i) }
        pos = field(buf, table, 40)
        if (pos != 0) { val s = STYLES[buf.get(pos).toInt()]; n.put("style", s); sig(40, s) }
        pos = field(buf, table, 41)
        if (pos != 0) { val s = string(buf, pos); n.put("title", s); sig(41, s) }
        pos = field(buf, table, 42)
        if (pos != 0) { val s = string(buf, pos); n.put("message", s); sig(42, s) }
        pos = field(buf, table, 43)
        if (pos != 0) { val s = string(buf, pos); n.put("dismiss", s); sig(43, s) }
        // Visual transforms (slots 45-47) and a drag gesture's handler (48).
        pos = field(buf, table, 45)
        if (pos != 0) { val d = buf.getDouble(pos); n.put("offsetX", d); sig(45, d) }
        pos = field(buf, table, 46)
        if (pos != 0) { val d = buf.getDouble(pos); n.put("offsetY", d); sig(46, d) }
        pos = field(buf, table, 47)
        if (pos != 0) { val d = buf.getDouble(pos); n.put("scale", d); sig(47, d) }
        pos = field(buf, table, 48)
        if (pos != 0) { val s = string(buf, pos); n.put("drag", s); sig(48, s) }
        // Identity among its siblings (slot 49): what composables key on.
        pos = field(buf, table, 49)
        if (pos != 0) n.put("key", string(buf, pos))

        var children: List<UNode> = emptyList()
        pos = field(buf, table, 44)
        if (pos != 0) {
            val vec = indirect(buf, pos)
            val count = buf.getInt(vec)
            val list = ArrayList<UNode>(count)
            for (i in 0 until count) list.add(node(buf, indirect(buf, vec + 4 + i * 4)))
            children = list
        }
        return UNode(n, children, sig.toString())
    }

    /**
     * Apply a `Patch` buffer (shared/renderers/tree.fbs, emitted by
     * FlatTreeEncoder.encodePatch) to the retained tree, returning the new root.
     * Copy-on-write: only the nodes on each op's path are rebuilt; every off-path
     * sibling keeps its [UNode] identity, so the skippable [IsoNode] recomposes
     * only the path to each change plus the changed subtree. The first patch
     * after the reactor enables diffs is a single root op = the whole tree.
     */
    fun applyPatch(retained: UNode?, bytes: ByteArray): UNode {
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val patch = indirect(buf, 0)
        var root = retained
        val opsPos = field(buf, patch, 0) // Patch.ops (slot 0)
        if (opsPos != 0) {
            val vec = indirect(buf, opsPos)
            val count = buf.getInt(vec)
            for (i in 0 until count) {
                val op = indirect(buf, vec + 4 + i * 4)
                val pathPos = field(buf, op, 0) // PatchOp.path (slot 0)
                if (pathPos == 0) continue
                val path = string(buf, pathPos)
                val orderPos = field(buf, op, 3) // PatchOp.order (slot 3)
                if (orderPos != 0) {
                    val orderVec = indirect(buf, orderPos)
                    val order = IntArray(buf.getInt(orderVec)) { buf.getInt(orderVec + 4 + it * 4) }
                    val insertsPos = field(buf, op, 4) // PatchOp.inserts (slot 4)
                    val inserts = ArrayList<UNode>()
                    if (insertsPos != 0) {
                        val vec = indirect(buf, insertsPos)
                        for (k in 0 until buf.getInt(vec)) inserts.add(node(buf, indirect(buf, vec + 4 + k * 4)))
                    }
                    root = root?.let { reorderAt(it, path, order, inserts) }
                    continue
                }
                val nodePos = field(buf, op, 1) // PatchOp.node (slot 1)
                if (nodePos == 0) continue
                val attrsPos = field(buf, op, 2) // PatchOp.attrs_only (slot 2)
                val attrsOnly = attrsPos != 0 && buf.get(attrsPos).toInt() != 0
                val decoded = node(buf, indirect(buf, nodePos))
                root = applyOp(root, path, decoded, attrsOnly)
            }
        }
        // Non-null after the first (root) op; the empty box guards a degenerate
        // empty-ops patch against a still-empty retained tree.
        return root ?: UNode(JSONObject().apply { put("k", "box") }, emptyList(), "k0;")
    }

    /** Splices [decoded] into [root] at positional [path] ("n", "n.0.1", ...).
     *  attrs-only keeps the retained node's children; otherwise the decoded
     *  subtree (with its own children) replaces it. */
    private fun applyOp(root: UNode?, path: String, decoded: UNode, attrsOnly: Boolean): UNode {
        val segments = path.split('.').drop(1).map { it.toInt() } // drop leading "n"
        if (segments.isEmpty()) {
            return if (attrsOnly) UNode(decoded.json, root?.children ?: emptyList(), decoded.sig)
            else decoded
        }
        return replaceAt(root!!, segments, 0, decoded, attrsOnly)
    }

    /** The node at [path] gets, for each [order] entry, its retained child at
     *  that index (same [UNode], so Compose skips it) or for -1 the next of
     *  [inserts]. Copy-on-write along the path. */
    private fun reorderAt(root: UNode, path: String, order: IntArray, inserts: List<UNode>): UNode {
        val segments = path.split('.').drop(1).map { it.toInt() }
        fun rebuild(cur: UNode, depth: Int): UNode {
            if (depth == segments.size) {
                var next = 0
                val kids = order.map { index ->
                    if (index >= 0 && index < cur.children.size) cur.children[index] else inserts[next++]
                }
                return UNode(cur.json, kids, cur.sig)
            }
            val index = segments[depth]
            val kids = ArrayList(cur.children)
            kids[index] = rebuild(cur.children[index], depth + 1)
            return UNode(cur.json, kids, cur.sig)
        }
        return rebuild(root, 0)
    }

    private fun replaceAt(
        cur: UNode, segments: List<Int>, depth: Int, decoded: UNode, attrsOnly: Boolean,
    ): UNode {
        val index = segments[depth]
        val child = cur.children[index]
        val newChild = if (depth == segments.lastIndex) {
            if (attrsOnly) UNode(decoded.json, child.children, decoded.sig) else decoded
        } else {
            replaceAt(child, segments, depth + 1, decoded, attrsOnly)
        }
        val newChildren = ArrayList(cur.children)
        newChildren[index] = newChild
        return UNode(cur.json, newChildren, cur.sig)
    }

}
