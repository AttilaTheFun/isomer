// The SwiftUI host's retained render tree + tree.fbs `Patch` applier — the
// Swift analogue of the Android Compose host's `FlatTree.applyPatch`
// (FlatTree.kt). Patches are the ONLY wire format the reactor ships (the
// first patch after start/reload is a single full-tree op at "n").
//
// The retained model wraps the flatbuffer instead of copying it: a
// `PatchedNode` holds the zero-copy `IsoFlat_Node` view for its OWN
// attributes (the backing buffer is kept alive by `buffer`) plus a
// materialized `children` array — the splice points. Application is
// copy-on-write: only nodes on an op's path are rebuilt, so an unchanged
// subtree keeps its `PatchedNode` reference across frames.

import FlatBuffers
public import IsomerSwiftUI

/// One retained node. Reference identity == unchanged subtree.
public final class PatchedNode {
    /// Zero-copy own-attribute view into `buffer`'s flatbuffer (IsomerSwiftUI's
    /// IsoFlat types: a host reading the tree, the Playground's headless run).
    public let flat: IsoFlat_Node
    /// The serialized buffer `flat` (and every descendant wrapped from the
    /// same patch op) points into — retained so the views stay valid.
    public let buffer: [UInt8]
    /// Materialized children, spliced by later patch ops.
    public let children: [PatchedNode]

    /// Headless-verification hook: a compact structural dump of the subtree
    /// (kind, view kind, grow/expand flags, sizes, leading text), used with
    /// the `ISO_DUMP_TREE=<path>` env hook on the example hosts.
    public func structureDump(indent: String = "") -> String {
        let n = flat
        var line = indent + "\(n.kind)"
        if let view = n.view { line += " view=\(view)" }
        line += " axis=\(n.axis)"
        if n.growW { line += " growW" }
        if n.growH { line += " growH" }
        if n.expandW { line += " expandW" }
        if n.expandH { line += " expandH" }
        if let w = n.width { line += " w=\(w)" }
        if let h = n.height { line += " h=\(h)" }
        if let min = n.min { line += " min=\(min)" }
        if let v = n.v, !v.isEmpty { line += " v=\"\(v.prefix(24))\"" }
        if let lines = n.lines { line += " lines=\(lines)" }
        if let key = n.key { line += " key=\(key.suffix(40))" }
        if n.tap != nil { line += " tap" }
        for kv in n.params where kv.key != "imageData" && kv.key != "runs" && kv.key != "runLinks" {
            line += " \(kv.key)=\(kv.value.prefix(20))"
        }
        var out = line + "\n"
        for child in children {
            out += child.structureDump(indent: indent + "  ")
        }
        return out
    }

    init(flat: IsoFlat_Node, buffer: [UInt8], children: [PatchedNode]) {
        self.flat = flat
        self.buffer = buffer
        self.children = children
    }

    /// Wrap a decoded flatbuffer subtree (no attribute copying — children are
    /// wrapped recursively, own attributes stay in the buffer).
    static func wrap(flat: IsoFlat_Node, buffer: [UInt8]) -> PatchedNode {
        // A picture's bytes ride the first node that shows them, once: kept
        // as the patch arrives, whether or not that node is ever drawn (it
        // may be built again, without them, before it is).
        if flat.kind == .image, let source = flat.src {
            for kv in flat.params where kv.key == "imageData" { HostImages.shared.remember(source, base64: kv.value) }
        }
        var children: [PatchedNode] = []
        children.reserveCapacity(Int(flat.ch.count))
        for index in 0..<flat.ch.count {
            children.append(wrap(flat: flat.ch[index], buffer: buffer))
        }
        return PatchedNode(flat: flat, buffer: buffer, children: children)
    }
}

public enum FlatPatchTree {
    /// Apply a `Patch` buffer to the retained tree, returning the new root.
    /// `retained` is nil before the first frame and after a reactor reload
    /// (the fresh reactor's first patch rebuilds from scratch). Ops whose path
    /// falls outside the retained shape indicate a desynced stream and are
    /// dropped rather than spliced at a wrong spot.
    public static func apply(patch bytes: [UInt8], to retained: PatchedNode?) -> PatchedNode? {
        var buffer = ByteBuffer(bytes: bytes)
        let patch = getRoot(byteBuffer: &buffer) as IsoFlat_Patch
        var root = retained
        for index in 0..<patch.ops.count {
            let op = patch.ops[index]
            guard let path = op.path else { continue }
            let segments = path.split(separator: ".").dropFirst().compactMap { Int($0) }
            if op.order.count > 0 {
                // Reorder: kept children by old index (their identity kept),
                // -1 = the next insert.
                guard let current = root else { continue }
                let order = op.order
                let inserts = op.inserts
                root = reorder(current, segments[...]) { old in
                    var inserted = 0
                    return order.map { index -> PatchedNode in
                        if index >= 0, Int(index) < old.count { return old[Int(index)] }
                        defer { inserted += 1 }
                        return PatchedNode.wrap(flat: inserts[inserted], buffer: bytes)
                    }
                }
                continue
            }
            guard let flat = op.node else { continue }
            let decoded = PatchedNode.wrap(flat: flat, buffer: bytes)
            if segments.isEmpty {
                // Root op: replace the whole tree (attrs-only keeps children).
                root = op.attrsOnly
                    ? PatchedNode(flat: decoded.flat, buffer: decoded.buffer,
                                  children: root?.children ?? [])
                    : decoded
                continue
            }
            guard let current = root else { continue }
            root = splice(current, segments[...], decoded, attrsOnly: op.attrsOnly)
        }
        return root
    }

    /// Copy-on-write: the node at the path gets `children(old)` as its
    /// children; only the nodes on the path are rebuilt.
    private static func reorder(
        _ node: PatchedNode, _ segments: ArraySlice<Int>, _ children: ([PatchedNode]) -> [PatchedNode]
    ) -> PatchedNode {
        guard let index = segments.first else {
            return PatchedNode(flat: node.flat, buffer: node.buffer, children: children(node.children))
        }
        guard index < node.children.count else { return node }
        var kids = node.children
        kids[index] = reorder(kids[index], segments.dropFirst(), children)
        return PatchedNode(flat: node.flat, buffer: node.buffer, children: kids)
    }

    /// Copy-on-write splice: rebuilds only the nodes on the path; every
    /// off-path sibling keeps its `PatchedNode` identity.
    private static func splice(
        _ node: PatchedNode, _ segments: ArraySlice<Int>, _ decoded: PatchedNode, attrsOnly: Bool
    ) -> PatchedNode {
        guard let index = segments.first, index < node.children.count else { return node }
        let child = node.children[index]
        let newChild: PatchedNode
        if segments.count == 1 {
            newChild = attrsOnly
                ? PatchedNode(flat: decoded.flat, buffer: decoded.buffer, children: child.children)
                : decoded
        } else {
            newChild = splice(child, segments.dropFirst(), decoded, attrsOnly: attrsOnly)
        }
        var children = node.children
        children[index] = newChild
        return PatchedNode(flat: node.flat, buffer: node.buffer, children: children)
    }
}
