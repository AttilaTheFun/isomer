package dev.isomer.runtime

import org.json.JSONArray
import org.json.JSONObject

// UNode (the retained node this decoder emits) lives in its own file:
// UNode.kt (@Immutable-annotated, skippable in Compose).

/**
 * Decodes the render tree (shared/wire/tree.proto: protobuf) into a retained
 * [UNode] tree. Hand-written against protobuf's wire format; the field
 * numbers MUST match tree.proto's.
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

    /** Protobuf's fields in `bytes[from, to)`, one at a time. */
    internal class Reader(val bytes: ByteArray, from: Int, private val to: Int) {
        var pos = from
        fun done() = pos >= to

        /** A varint's low 64 bits. */
        fun varint(): Long {
            var result = 0L
            var shift = 0
            while (true) {
                val byte = bytes[pos++].toInt()
                if (shift < 64) result = result or ((byte and 0x7f).toLong() shl shift)
                if (byte and 0x80 == 0) return result
                shift += 7
            }
        }

        /** The next field's number and wire type. */
        fun tag(): Pair<Int, Int> {
            val tag = varint().toInt()
            return Pair(tag ushr 3, tag and 7)
        }

        fun int32() = varint().toInt()
        fun bool() = varint() != 0L
        fun double(): Double {
            var bits = 0L
            for (i in 0 until 8) bits = bits or ((bytes[pos + i].toLong() and 0xff) shl (8 * i))
            pos += 8
            return java.lang.Double.longBitsToDouble(bits)
        }
        fun float(): Float {
            var bits = 0
            for (i in 0 until 4) bits = bits or ((bytes[pos + i].toInt() and 0xff) shl (8 * i))
            pos += 4
            return java.lang.Float.intBitsToFloat(bits)
        }

        /** A length-delimited field's bounds; the reader moves past it. */
        fun span(): IntRange {
            val length = varint().toInt()
            val from = pos
            pos += length
            return from until pos
        }

        fun string(): String {
            val span = span()
            return String(bytes, span.first, span.last - span.first + 1, Charsets.UTF_8)
        }

        fun skip(type: Int) {
            when (type) {
                0 -> varint()
                1 -> pos += 8
                2 -> pos += varint().toInt()
                5 -> pos += 4
            }
        }

        fun sub(span: IntRange) = Reader(bytes, span.first, span.last + 1)
    }

    private fun color(r: Reader): JSONArray {
        val out = doubleArrayOf(0.0, 0.0, 0.0, 0.0)
        while (!r.done()) {
            val (field, type) = r.tag()
            if (type == 5 && field in 1..4) out[field - 1] = r.float().toDouble() else r.skip(type)
        }
        return JSONArray().apply { out.forEach { put(it) } }
    }

    private fun shadow(r: Reader): JSONObject {
        val out = JSONObject().apply {
            put("color", JSONArray().apply { repeat(4) { put(0.0) } })
            put("radius", 0.0)
            put("x", 0.0)
            put("y", 0.0)
        }
        while (!r.done()) {
            val (field, type) = r.tag()
            when {
                field == 1 && type == 2 -> out.put("color", color(r.sub(r.span())))
                field == 2 && type == 5 -> out.put("radius", r.float().toDouble())
                field == 3 && type == 5 -> out.put("x", r.float().toDouble())
                field == 4 && type == 5 -> out.put("y", r.float().toDouble())
                else -> r.skip(type)
            }
        }
        return out
    }

    /**
     * Decodes one `Node` message into a [UNode]. Attributes go into the
     * JSONObject; children (field 45) become retained [UNode]s. The
     * [StringBuilder] `sig` accumulates a deterministic own-signature: each
     * present field appends `slot:value;` in field order (slot = field - 1,
     * as in the FlatBuffers format before), so two nodes with equal own
     * attributes produce byte-identical sigs regardless of hash-map order.
     */
    private fun node(r: Reader): UNode {
        val n = JSONObject()
        val sig = StringBuilder()
        fun sig(slot: Int, value: Any) { sig.append(slot).append(':').append(value).append(';') }

        var kind = "box"
        var numeric: Double? = null
        var hasAxis = false
        var options: JSONArray? = null
        var params: JSONObject? = null
        var padding: JSONArray? = null
        val children = ArrayList<UNode>()
        while (!r.done()) {
            val (field, type) = r.tag()
            when (field) {
                1 -> kind = KINDS.getOrElse(r.int32()) { "box" }
                2 -> { val s = r.string(); n.put("v", s); sig(1, s) }
                3 -> numeric = r.double()
                4 -> { val s = r.string(); n.put("id", s); sig(3, s) }
                5 -> { val d = r.double(); n.put("size", d); sig(4, d) }
                6 -> { val i = r.int32(); n.put("weight", i); sig(5, i) }
                7 -> { val c = color(r.sub(r.span())); n.put("color", c); sig(6, c) }
                8 -> { val i = r.int32(); n.put("lines", i); sig(7, i) }
                9 -> { val s = SHAPES[r.int32()]; n.put("shape", s); sig(8, s) }
                10 -> { val c = color(r.sub(r.span())); n.put("fill", c); sig(9, c) }
                11 -> { val c = color(r.sub(r.span())); n.put("stroke", c); sig(10, c) }
                12 -> { val d = r.double(); n.put("strokeWidth", d); sig(11, d) }
                13 -> { val s = AXES[r.int32()]; n.put("axis", s); sig(12, s); hasAxis = true }
                14 -> { val d = r.double(); n.put("spacing", d); sig(13, d) }
                15 -> { val d = r.double(); n.put("min", d); sig(14, d) }
                16 -> { val s = r.string(); n.put("src", s); sig(15, s) }
                17 -> { val b = r.bool(); n.put("remote", b); sig(16, b) }
                18 -> { val b = r.bool(); n.put("resizable", b); sig(17, b) }
                19 -> { val b = r.bool(); n.put("fit", b); sig(18, b) }
                20 -> { val s = r.string(); n.put("placeholder", s); sig(19, s) }
                21 -> { val s = r.string(); n.put("edit", s); sig(20, s) }
                22 -> { val s = r.string(); n.put("view", s); sig(21, s) }
                23 -> (options ?: JSONArray().also { options = it }).put(r.string())
                24 -> {
                    val kv = r.sub(r.span())
                    var key = ""
                    var value = ""
                    while (!kv.done()) {
                        val (f, t) = kv.tag()
                        when {
                            f == 1 && t == 2 -> key = kv.string()
                            f == 2 && t == 2 -> value = kv.string()
                            else -> kv.skip(t)
                        }
                    }
                    (params ?: JSONObject().also { params = it }).put(key, value)
                }
                25 -> { val b = r.bool(); n.put("growW", b); sig(24, b) }
                26 -> { val b = r.bool(); n.put("growH", b); sig(25, b) }
                27 -> { val s = ALIGN_H[r.int32()]; n.put("alignH", s); sig(26, s) }
                28 -> { val s = ALIGN_V[r.int32()]; n.put("alignV", s); sig(27, s) }
                29 -> { val s = shadow(r.sub(r.span())); n.put("shadow", s); sig(28, s) }
                30 -> {
                    val list = padding ?: JSONArray().also { padding = it }
                    if (type == 2) {
                        val packed = r.sub(r.span())
                        while (!packed.done()) list.put(packed.double())
                    } else {
                        list.put(r.double())
                    }
                }
                31 -> { val d = r.double(); n.put("width", d); sig(30, d) }
                32 -> { val d = r.double(); n.put("height", d); sig(31, d) }
                33 -> { val b = r.bool(); n.put("expandW", b); sig(32, b) }
                34 -> { val b = r.bool(); n.put("expandH", b); sig(33, b) }
                35 -> { val d = r.double(); n.put("radius", d); sig(34, d) }
                36 -> { val d = r.double(); n.put("opacity", d); sig(35, d) }
                37 -> { val c = color(r.sub(r.span())); n.put("bg", c); sig(36, c) }
                38 -> { val s = r.string(); n.put("gradient", s); sig(37, s) }
                39 -> { val s = r.string(); n.put("tap", s); sig(38, s) }
                40 -> { val i = r.int32(); n.put("feedback", i); sig(39, i) }
                41 -> { val s = STYLES[r.int32()]; n.put("style", s); sig(40, s) }
                42 -> { val s = r.string(); n.put("title", s); sig(41, s) }
                43 -> { val s = r.string(); n.put("message", s); sig(42, s) }
                44 -> { val s = r.string(); n.put("dismiss", s); sig(43, s) }
                45 -> children.add(node(r.sub(r.span())))
                46 -> { val d = r.double(); n.put("offsetX", d); sig(45, d) }
                47 -> { val d = r.double(); n.put("offsetY", d); sig(46, d) }
                48 -> { val d = r.double(); n.put("scale", d); sig(47, d) }
                49 -> { val s = r.string(); n.put("drag", s); sig(48, s) }
                // Identity among its siblings: what composables key on.
                50 -> n.put("key", r.string())
                else -> r.skip(type)
            }
        }
        n.put("k", kind)
        sig.insert(0, "0:$kind;")
        numeric?.let { n.put("v", it); sig(2, it) } // numeric value
        if (!hasAxis && (kind == "stack" || kind == "scroll")) { n.put("axis", "h"); sig(12, "h") }
        options?.let { n.put("options", it); sig(22, it) }
        params?.let { p ->
            n.put("params", p)
            // JSONObject iteration is unordered; sign each entry in a stable
            // key order.
            for (k in p.keys().asSequence().sorted()) sig.append("23.").append(k).append(':').append(p.opt(k)).append(';')
        }
        padding?.let { n.put("padding", it); sig(29, it) }
        return UNode(n, children, sig.toString())
    }

    /**
     * Apply a `Patch` (shared/wire/tree.proto, emitted by
     * FlatTreeEncoder.encodePatch) to the retained tree, returning the new root.
     * Copy-on-write: only the nodes on each op's path are rebuilt; every off-path
     * sibling keeps its [UNode] identity, so the skippable [IsoNode] recomposes
     * only the path to each change plus the changed subtree. The first patch
     * after the reactor enables diffs is a single root op = the whole tree.
     */
    fun applyPatch(retained: UNode?, bytes: ByteArray): UNode {
        val r = Reader(bytes, 0, bytes.size)
        var root = retained
        while (!r.done()) {
            val (field, type) = r.tag()
            if (field != 1 || type != 2) { r.skip(type); continue } // Patch.ops
            val op = r.sub(r.span())
            var path: String? = null
            var decoded: UNode? = null
            var attrsOnly = false
            var reorder = false
            val order = ArrayList<Int>()
            val inserts = ArrayList<UNode>()
            while (!op.done()) {
                val (f, t) = op.tag()
                when {
                    f == 1 && t == 2 -> path = op.string()
                    f == 2 && t == 2 -> decoded = node(op.sub(op.span()))
                    f == 3 && t == 0 -> attrsOnly = op.bool()
                    f == 4 && t == 2 -> {
                        val packed = op.sub(op.span())
                        while (!packed.done()) order.add(packed.int32())
                    }
                    f == 4 && t == 0 -> order.add(op.int32())
                    f == 5 && t == 2 -> inserts.add(node(op.sub(op.span())))
                    f == 6 && t == 0 -> reorder = op.bool()
                    else -> op.skip(t)
                }
            }
            val opPath = path ?: continue
            if (reorder || order.isNotEmpty()) {
                root = root?.let { reorderAt(it, opPath, order.toIntArray(), inserts) }
                continue
            }
            val node = decoded ?: continue
            root = applyOp(root, opPath, node, attrsOnly)
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
