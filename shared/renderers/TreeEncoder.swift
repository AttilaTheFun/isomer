// Encodes the resolved (pre-layout) `RenderNode` tree as a FlatBuffer
// (shared/renderers/tree.fbs) for component-system renderers. Interactive
// nodes register their closures in `handlers`, keyed by a stable id the
// consumer echoes back through `Runtime.hostViewEvent(id:value:)`; nodes
// with `onAppear` collect into `appearances` for the renderer to fire after
// handing the tree over. The successor of the JSON TreeSerializer — same
// ids, same semantics, binary wire format.
//
// Two encode paths share one `flatten` pass:
//   • `encodePatch(root:)`— a `Patch` (diff) against the retained previous
//                           tree — THE wire format every host consumes. Only
//                           what changed is shipped; the host keeps its own
//                           retained tree and redraws only the changed nodes.
//   • `encode(root:)`     — the full tree as a `Node` root; kept as the
//                           round-trip test's reference encoding.
// `flatten` produces `FlatNode` — the encoder's own retained, value-typed
// mirror of the tree (children, and own attributes compared field by field)
// — which is both what gets serialized and what the next frame diffs against.

import FlatBuffers
internal import IsomerSwiftUI

package final class FlatTreeEncoder {
    /// value -> handler; "tap" events send an empty value.
    public private(set) var handlers: [String: (String) -> Void] = [:]
    /// onAppear handlers found in this pass, keyed by node path.
    public private(set) var appearances: [(id: String, appear: () -> Void)] = []
    /// What to run when a node recorded in `appearances` is no longer in the
    /// tree (`onDisappear`), by the same id.
    public private(set) var disappearances: [String: () -> Void] = [:]

    /// The previous frame's flattened tree, retained so `encodePatch` can diff
    /// against it. Positional-path diff: stable while structure is unchanged
    /// (the common in-place value update — a tap flipping state), full-replaces a
    /// subtree on any kind/child-count change.
    private var previous: FlatNode?

    /// Each node's greediness for the current pass. Every node asks for its
    /// own, and a node's answer takes its whole subtree's, so without this a
    /// deep tree (a long transcript) paid subtree-size times depth per frame.
    /// Each entry holds its node until the pass ends: a GeometryReader's
    /// content is built mid-pass and let go, and a node allocated after it
    /// at the same address would otherwise be handed the freed node's answer
    /// (a bar's track shape came out not greedy, and drew 0x0 on the web).
    private var greedinessMemo: [ObjectIdentifier: (node: RenderNode, w: Bool, h: Bool)] = [:]

    /// Handler ids handed out this pass, to keep two identities that hash
    /// alike apart.
    private var usedHandles: Set<String> = []

    /// The flattened form of the reused subtrees (Reuse.swift) by node: a
    /// subtree the core handed back unbuilt flattens to what it did last
    /// frame, so its handlers and appearances are replayed instead of the
    /// subtree being walked again. Held strongly (identity stays unique) and
    /// dropped once a pass no longer reaches the node.
    private final class FlattenCacheEntry {
        let node: RenderNode
        let ident: String
        let anchor: String?
        /// The node's `contentEpoch` when flattened: a node below it replaced
        /// in place since (InPlace.swift) makes this stale.
        let epoch: Int
        let flat: FlatNode
        let record: FlattenRecord
        /// The live values the flattening read (text fields, scrolls, inline
        /// images): the cached form holds while each reads the same.
        let probes: [LiveProbe]
        /// The scroll targets inside it.
        let targets: Set<String>
        /// The node as last keyed among its siblings (its key relative to
        /// `keyAnchor`), so a pass reaching it again skips the key work.
        var keyed: FlatNode?
        var keyAnchor: String?

        init(node: RenderNode, ident: String, anchor: String?, flat: FlatNode, record: FlattenRecord, probes: [LiveProbe], targets: Set<String>) {
            self.node = node
            self.ident = ident
            self.anchor = anchor
            self.epoch = node.contentEpoch
            self.flat = flat
            self.record = record
            self.probes = probes
            self.targets = targets
        }

        /// Whether the live values it read are unchanged, and nothing below
        /// the node was replaced since.
        var stillLive: Bool { epoch == node.contentEpoch && probes.allSatisfy { $0.read() == $0.value } }
    }
    /// A value a node's flattened form reads from outside the tree (a text
    /// field's text and focus, a scroll's pending request and row count, an
    /// image's pending bytes), with what it read.
    private struct LiveProbe {
        let read: () -> String
        let value: String
    }
    /// The probes of the pass, in order: a cached subtree keeps those read
    /// while it was flattened (Reuse's reused subtrees, flattenCache).
    private var liveProbes: [LiveProbe] = []
    /// The scroll targets (`.id`s) met while flattening, one set per scroll
    /// (and per cached subtree) being flattened: a scroll is handed a scroll
    /// request only for a target inside it.
    private var targetCollectors: [Set<String>] = []
    /// With the frame log on (FrameLog.swift): what a pass flattened.
    private var passStats = (nodes: 0, hits: 0, fresh: [String](), stale: [String]())
    /// What flattening a subtree registered.
    private struct FlattenRecord {
        var handlers: [(String, (String) -> Void)] = []
        var appearances: [(String, () -> Void)] = []
        var disappearances: [(String, () -> Void)] = []
        var handles: [String] = []
        /// The cached subtrees inside this one, kept while it is.
        var inner: [ObjectIdentifier] = []
    }
    private var flattenCache: [ObjectIdentifier: FlattenCacheEntry] = [:]
    private var flattenCacheReached: Set<ObjectIdentifier> = []
    private var recorders: [FlattenRecord] = []
    /// Bumped by nodes whose flattened form is built from live runtime
    /// state (a geometry reader's content, built for its measured size):
    /// subtrees holding one are flattened afresh every pass. Nodes that only
    /// read a few live values (text fields, scrolls) leave a `LiveProbe`
    /// instead, and their subtrees stay cached while the values hold.
    private var flattenVolatility = 0
    private var nextSubtreeToken = 0

    public init() {}

    /// Drop the retained tree so the next `encodePatch` re-sends the full tree as
    /// a single root op (e.g. after the consumer resets, or a bundle reload).
    public func resetRetainedTree() {
        previous = nil
        flattenCache = [:]
    }

    // MARK: - Full-tree encode

    /// Encodes `root` (with any pending presentations layered over it) as a
    /// `Node` root. Unchanged from the pre-diff wire format.
    public func encode(root: RenderNode) -> [UInt8] {
        handlers = [:]
        appearances = []
        disappearances = [:]
        let tree = flattenRoot(root)
        var fbb = FlatBufferBuilder(initialSize: 16_384)
        let offset = serialize(tree, includeChildren: true, &fbb)
        fbb.finish(offset: offset)
        return fbb.sizedByteArray
    }

    // MARK: - Diff-aware encode

    /// Encodes only what changed since the last `encode`/`encodePatch` as a
    /// `Patch`. The first call (or one after `resetRetainedTree`) emits a single
    /// op at path "n" carrying the whole tree. Ships over the same transport as
    /// `encode` — the host distinguishes them because it opted into diffs.
    public func encodePatch(root: RenderNode) -> [UInt8] {
        handlers = [:]
        appearances = []
        disappearances = [:]
        passStats = (0, 0, [], [])
        let tree = flattenRoot(root)
        if Runtime.shared.frameLog != nil {
            let stale = passStats.stale.prefix(6).joined(separator: ", ") + (passStats.stale.count > 6 ? " (+\(passStats.stale.count - 6))" : "")
            Runtime.shared.host?.log("[encode] flattened \(passStats.nodes) nodes | cached subtrees replayed \(passStats.hits), flattened again \(passStats.stale.count): \(stale.isEmpty ? "-" : stale) | new \(passStats.fresh.count): \(passStats.fresh.prefix(4).joined(separator: ", "))")
        }
        var fbb = FlatBufferBuilder(initialSize: 4_096)
        var ops: [Offset] = []
        diff(previous, tree, path: "n", &fbb, &ops)
        let opsVector = fbb.createVector(ofOffsets: ops)
        let patch = IsoFlat_Patch.createPatch(&fbb, opsVectorOffset: opsVector)
        fbb.finish(offset: patch)
        previous = tree
        return fbb.sizedByteArray
    }

    // MARK: - Diff

    /// Walks old/new together, appending the minimal set of `PatchOp`s. A
    /// kind change replaces the whole subtree; an own-attribute change
    /// replaces just the node's attributes (children kept). Children match
    /// by key — their identity — not by position, as SwiftUI's do: when the
    /// children differ in membership or order, one `order` op says where each
    /// kept child now sits and carries only the new ones, and every kept
    /// child is then diffed against itself. A row inserted above a thousand
    /// others ships as that row alone.
    ///
    /// Ops run in the order they are emitted, and paths are positions in the
    /// tree as it stands when the op runs: a node's own ops come before its
    /// children's, so a child's path is its position after any reorder.
    private func diff(
        _ old: FlatNode?, _ new: FlatNode, path: String,
        _ fbb: inout FlatBufferBuilder, _ ops: inout [Offset]
    ) {
        guard let old, old.kind == new.kind else {
            ops.append(op(path, serialize(new, includeChildren: true, &fbb), attrsOnly: false, &fbb))
            return
        }
        // The same cached subtree as last frame (a reused view's): nothing
        // in it changed.
        if new.subtreeToken != 0, new.subtreeToken == old.subtreeToken { return }
        if !old.sameOwnAttributes(as: new) {
            ops.append(op(path, serialize(new, includeChildren: false, &fbb), attrsOnly: true, &fbb))
        }
        // Where each new child was among the old ones (-1: it is new).
        var sameOrder = old.children.count == new.children.count
        var order: [Int32] = []
        order.reserveCapacity(new.children.count)
        if sameOrder {
            for index in new.children.indices where old.children[index].matchKey != new.children[index].matchKey {
                sameOrder = false
                break
            }
        }
        if sameOrder {
            for index in new.children.indices {
                diff(old.children[index], new.children[index], path: "\(path).\(index)", &fbb, &ops)
            }
            return
        }
        // No children left: a plain replace (an `order` op is never empty,
        // so readers can tell one by its entries).
        if new.children.isEmpty {
            ops.append(op(path, serialize(new, includeChildren: true, &fbb), attrsOnly: false, &fbb))
            return
        }
        var oldIndex: [String: Int] = [:]
        oldIndex.reserveCapacity(old.children.count)
        for (index, child) in old.children.enumerated() { oldIndex[child.matchKey] = index }
        var inserts: [Offset] = []
        for child in new.children {
            if let index = oldIndex[child.matchKey], old.children[index].kind == child.kind {
                order.append(Int32(index))
            } else {
                order.append(-1)
                inserts.append(serialize(child, includeChildren: true, &fbb))
            }
        }
        ops.append(reorderOp(path, order: order, inserts: inserts, &fbb))
        for (index, child) in new.children.enumerated() where order[index] >= 0 {
            diff(old.children[Int(order[index])], child, path: "\(path).\(index)", &fbb, &ops)
        }
    }

    private func op(
        _ path: String, _ node: Offset, attrsOnly: Bool, _ fbb: inout FlatBufferBuilder
    ) -> Offset {
        let pathOffset = fbb.create(string: path)
        return IsoFlat_PatchOp.createPatchOp(
            &fbb, pathOffset: pathOffset, nodeOffset: node, attrsOnly: attrsOnly)
    }

    /// The node at `path` keeps its attributes; its children become, for
    /// each `order` entry, the old child at that index, or (for -1) the next
    /// of `inserts`.
    private func reorderOp(
        _ path: String, order: [Int32], inserts: [Offset], _ fbb: inout FlatBufferBuilder
    ) -> Offset {
        let pathOffset = fbb.create(string: path)
        let orderVector = fbb.createVector(order)
        let insertsVector = fbb.createVector(ofOffsets: inserts)
        return IsoFlat_PatchOp.createPatchOp(
            &fbb, pathOffset: pathOffset, orderVectorOffset: orderVector, insertsVectorOffset: insertsVector)
    }

    // MARK: - Flatten (RenderNode -> FlatNode)

    /// Flattens `root` and layers any pending presentations over it exactly as
    /// the wire format expects (each a `presentation` node over the root inside a
    /// depth stack), collecting handlers/appearances as it goes.
    private func flattenRoot(_ root: RenderNode) -> FlatNode {
        greedinessMemo.removeAll(keepingCapacity: true)
        usedHandles.removeAll(keepingCapacity: true)
        flattenCacheReached.removeAll(keepingCapacity: true)
        liveProbes.removeAll(keepingCapacity: true)
        defer {
            greedinessMemo.removeAll(keepingCapacity: true)
            // Entries no longer reached (a rebuilt row's old subtree) go once
            // they add up, not on every pass.
            if flattenCache.count > flattenCacheReached.count + flattenCacheReached.count / 4 + 32 {
                flattenCache = flattenCache.filter { flattenCacheReached.contains($0.key) }
            }
        }
        var rootNode = flatten(root, ident: root.buildPath ?? "n", anchor: root.buildPath)
        rootNode.setKey(nil, fallback: "#0")

        let presentations = Runtime.shared.pendingPresentations
        Runtime.shared.topPresentationDismiss = presentations.last?.dismiss
        guard !presentations.isEmpty else { return rootNode }

        var layers: [FlatNode] = [rootNode]
        for presentation in presentations {
            let dismissID = "presentation.\(presentation.id)"
            let dismiss = presentation.dismiss
            register(dismissID, { _ in dismiss() })
            var content = flatten(
                presentation.content, ident: presentation.content.buildPath ?? "p.\(presentation.id)",
                anchor: presentation.content.buildPath)
            content.setKey(nil, fallback: "#0")
            var node = FlatNode(kind: .presentation)
            node.setKey("~p\(presentation.id)", fallback: "")
            // The content's presentation modifiers, as the sheet's params.
            var sheetParams: [(String, String)] = []
            if let detents = presentation.content.presentationDetents, !detents.isEmpty { sheetParams.append(("detents", detents)) }
            if let grabber = presentation.content.presentationDragIndicator { sheetParams.append(("grabber", grabber == "hidden" ? "0" : "1")) }
            if presentation.content.presentationDismissDisabled { sheetParams.append(("nodismiss", "1")) }
            switch presentation.style {
            case .sheet:
                node.style = .sheet
                if !sheetParams.isEmpty { node.params = sheetParams }
            case .cover:
                // A sheet on the wire, flagged full-screen (no schema change).
                node.style = .sheet
                node.params = [("cover", "1")]
            case .popover:
                node.style = .popover
                // Where it hangs from (the node with param "popover" of
                // this id), its attachment and arrow, and how it shows
                // at a compact size.
                var popoverParams: [(String, String)] = [("popoverId", presentation.id)]
                if let attachment = presentation.popoverAttachment { popoverParams.append(("attach", attachment)) }
                if let edge = presentation.popoverArrowEdge { popoverParams.append(("arrowEdge", edge)) }
                if let compact = presentation.content.presentationCompactAdaptation { popoverParams.append(("compact", compact)) }
                node.params = popoverParams
            case .alert(let title, let message):
                node.style = .alert
                node.title = title
                node.message = message
            case .request(let kind, let params, let onResult):
                // A sheet on the wire flagged as a request: hosts run their
                // own picker and answer on the result handler.
                let resultID = "presentation.\(presentation.id).result"
                register(resultID, { value in
                    dismiss()
                    onResult(value)
                })
                node.style = .sheet
                node.params = [("request", kind), ("result", resultID)] + params
            }
            // The panel fill and head-text color, scheme-resolved at encode
            // time (like every other color on the wire) — component-system
            // renderers draw the panel chrome themselves and must not
            // hardcode a light palette.
            node.bg = flatColor(Color.secondaryBackground)
            node.color = flatColor(Color.primary)
            node.dismiss = dismissID
            node.children = [content]
            layers.append(node)
        }
        var wrapper = FlatNode(kind: .stack)
        wrapper.axis = .depth
        wrapper.growW = true
        wrapper.growH = true
        wrapper.children = layers
        return wrapper
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    /// `ident` is the node's identity (its build path, or its parent's with
    /// its position for the nodes the runtime synthesizes); handler ids
    /// derive from it, so they hold while rows move around the node.
    /// `anchor` is the nearest build path above, which children's keys are
    /// written relative to.
    private func flatten(_ node: RenderNode, ident: String, anchor: String?) -> FlatNode {
        guard node.isReusedSubtreeRoot else { return flattenNode(node, ident: ident, anchor: anchor) }
        let id = ObjectIdentifier(node)
        if let entry = flattenCache[id], entry.ident == ident, entry.anchor == anchor, entry.stillLive {
            flattenCacheReached.insert(id)
            for index in recorders.indices { recorders[index].inner.append(id) }
            replay(entry.record)
            liveProbes += entry.probes
            collectTargets(entry.targets)
            passStats.hits += 1
            return entry.flat
        }
        if Runtime.shared.frameLog != nil {
            if flattenCache[id] != nil { passStats.stale.append(_pathTail(ident, 2)) }
            else { passStats.fresh.append(_pathTail(ident, 3)) }
        }
        recorders.append(FlattenRecord())
        let volatilityBefore = flattenVolatility
        let probesBefore = liveProbes.count
        targetCollectors.append([])
        var flat = flattenNode(node, ident: ident, anchor: anchor)
        let targets = targetCollectors.removeLast()
        let record = recorders.removeLast()
        if !recorders.isEmpty { merge(record, into: recorders.count - 1) }
        if flattenVolatility == volatilityBefore {
            for index in recorders.indices { recorders[index].inner.append(id) }
            nextSubtreeToken &+= 1
            flat.subtreeToken = nextSubtreeToken
            flattenCache[id] = FlattenCacheEntry(node: node, ident: ident, anchor: anchor, flat: flat, record: record,
                                                 probes: Array(liveProbes[probesBefore...]), targets: targets)
            flattenCacheReached.insert(id)
        }
        return flat
    }

    /// Scroll targets met (or replayed): every scroll and cached subtree being
    /// flattened holds them.
    private func collectTargets(_ targets: Set<String>) {
        guard !targets.isEmpty else { return }
        for index in targetCollectors.indices { targetCollectors[index].formUnion(targets) }
    }

    private func register(_ id: String, _ handler: @escaping (String) -> Void) {
        handlers[id] = handler
        for index in recorders.indices { recorders[index].handlers.append((id, handler)) }
    }

    private func recordAppearance(_ id: String, _ appear: @escaping () -> Void, _ disappear: (() -> Void)?) {
        appearances.append((id, appear))
        for index in recorders.indices { recorders[index].appearances.append((id, appear)) }
        if let disappear {
            disappearances[id] = disappear
            for index in recorders.indices { recorders[index].disappearances.append((id, disappear)) }
        }
    }

    private func recordHandle(_ handle: String) {
        for index in recorders.indices { recorders[index].handles.append(handle) }
    }

    /// A cached subtree's registrations, made again (and recorded for any
    /// cached subtree around it).
    private func replay(_ record: FlattenRecord) {
        for (id, handler) in record.handlers { handlers[id] = handler }
        appearances.append(contentsOf: record.appearances)
        for (id, disappear) in record.disappearances { disappearances[id] = disappear }
        usedHandles.formUnion(record.handles)
        for inner in record.inner { flattenCacheReached.insert(inner) }
        for index in recorders.indices { merge(record, into: index) }
    }

    private func merge(_ record: FlattenRecord, into index: Int) {
        recorders[index].handlers.append(contentsOf: record.handlers)
        recorders[index].appearances.append(contentsOf: record.appearances)
        recorders[index].disappearances.append(contentsOf: record.disappearances)
        recorders[index].handles.append(contentsOf: record.handles)
        recorders[index].inner.append(contentsOf: record.inner)
    }

    private func flattenNode(_ node: RenderNode, ident: String, anchor: String?) -> FlatNode {
        passStats.nodes += 1
        if let target = node.scrollTarget { collectTargets([target]) }
        if node.hasLifecycle {
            // Key by build identity AND node identity: the first separates a
            // pushed screen from the one it replaced at the same slot (its
            // onAppear must fire), the second screens that share a build path.
            // A node with only an onDisappear is recorded too: it has to be
            // known to be there before it can be seen to have gone.
            recordAppearance("\(node.identityPath ?? "")|\(ident)", node.onAppear ?? {}, node.disappearHandler)
        }
        // The id every handler on this node is named from: a short hash of
        // its identity (the wire carries it for every interactive node).
        var handleCache: String?
        func handle() -> String {
            if let handleCache { return handleCache }
            var made = handlerID(ident)
            var n = 1
            while !usedHandles.insert(made).inserted { made = handlerID(ident) + "d\(n)"; n += 1 }
            recordHandle(made)
            handleCache = made
            return made
        }
        let childAnchor = node.buildPath ?? anchor

        // Geometry readers under component-system renderers: the host owns
        // layout, so the real size arrives from the renderer as a measurement
        // event ("<w>x<h>" on the node's ".geo" id — ResizeObserver on web,
        // onSizeChanged on Compose, a layout listener on classic Views). The
        // content builds against the last reported size and the wrapper is
        // greedy on both axes, matching core layout's geometryReader. Until a
        // measurement lands (or on renderers that never send one) the build
        // falls back to the canvas size — the historical behavior. A same-size
        // re-report converges: the rebuilt tree is identical, the patch is
        // empty, and the host observes no further size change.
        if case .geometryReader = node.kind, let build = node.geometryBuild {
            let id = "\(handle()).geo"
            let size = Runtime.shared.geometrySizes[id]
                ?? CGSize(width: Runtime.shared.width, height: Runtime.shared.height)
            let origin = Runtime.shared.geometryOrigins[id] ?? .zero
            let measured = Runtime.shared.geometrySizes[id] != nil
            // Its content is built here for the size (and place) measured:
            // the same reader (a reused node: nothing it shows changed, or
            // the view around it would have been built again) at the same
            // size and place builds the same, so the subtree stays cached
            // while they hold.
            let readSize: () -> String = {
                let size = Runtime.shared.geometrySizes[id]
                    ?? CGSize(width: Runtime.shared.width, height: Runtime.shared.height)
                let origin = Runtime.shared.geometryOrigins[id] ?? .zero
                return "\(size.width)x\(size.height)@\(origin.x),\(origin.y)"
            }
            liveProbes.append(LiveProbe(read: readSize, value: readSize()))
            // "<w>x<h>", and where the host knows it the reader's place in the
            // window: "<w>x<h>@<x>,<y>" (for `frame(in: .global)`).
            register(id, { value in Runtime.shared.recordGeometry(id: id, value: value) })
            var out = FlatNode(kind: .box)
            out.growW = true
            out.growH = true
            out.params = [("geo", id)]
            out.children = flattenChildren([build(size, measured ? origin : nil)], ident: ident, anchor: childAnchor)
            return out
        }

        var out = FlatNode(kind: .box)
        // A scroll: the targets inside it, for its scroll requests.
        var isScroll = false
        if case .scroll = node.kind { isScroll = true; targetCollectors.append([]) }
        out.children = flattenChildren(node.children, ident: ident, anchor: childAnchor)
        let scrollTargets = isScroll ? targetCollectors.removeLast() : []
        // `.background(view)` / `.overlay(view)`: decoration layers, marked
        // ("layer" param) so component hosts place them behind / over the
        // content sized to this box (a filled shape or gradient as the FIRST
        // background collapses onto the node as a fill instead, below).
        func collapsesToFill(_ decoration: RenderNode) -> Bool {
            // A material (glass) stays a layer: hosts draw it over a blur of
            // what lies behind, which a plain fill on the node cannot carry.
            if case .shape(_, let fill, _) = decoration.kind, fill != nil { return true }
            if case .gradient(_, let paint) = decoration.kind { return paint.material == nil }
            return false
        }
        func alignName(_ alignment: Alignment) -> String {
            func h(_ a: HorizontalAlignment) -> String { a.kind == .leading ? "start" : a.kind == .trailing ? "end" : "center" }
            func v(_ a: VerticalAlignment) -> String { a.kind == .top ? "start" : a.kind == .bottom ? "end" : "center" }
            return h(alignment.horizontal) + "," + v(alignment.vertical)
        }
        var backgroundLayers: [FlatNode] = []
        for (index, decoration) in node.background.enumerated() where !(index == 0 && collapsesToFill(decoration)) {
            var layer = flatten(decoration, ident: decoration.buildPath ?? "\(ident)~bg\(index)", anchor: childAnchor)
            layer.setKey("~bg\(index)", fallback: "")
            layer.params = (layer.params ?? []) + [("layer", "background"), ("layerAlign", alignName(node.backgroundAlignment))]
            backgroundLayers.append(layer)
        }
        var overlayLayers: [FlatNode] = []
        for (index, decoration) in node.overlay.enumerated() {
            var layer = flatten(decoration, ident: decoration.buildPath ?? "\(ident)~ov\(index)", anchor: childAnchor)
            layer.setKey("~ov\(index)", fallback: "")
            layer.params = (layer.params ?? []) + [("layer", "overlay"), ("layerAlign", alignName(node.overlayAlignment))]
            overlayLayers.append(layer)
        }
        if !backgroundLayers.isEmpty || !overlayLayers.isEmpty {
            out.children = backgroundLayers + out.children + overlayLayers
        }

        var shapeRadius: Double? = nil
        switch node.kind {
        case .box:
            out.kind = .box
            // List-cell role in semantic mode ("row"/"header"): hosts apply
            // their platform's row metrics and separators keyed on it.
            if let cell = node.listCell {
                out.params = [("cell", cell)] + (node.listSelected ? [("selected", "1")] : [])
                if node.hidesRowSeparator { out.params = (out.params ?? []) + [("noSeparator", "1")] }
                // `.listRowInsets` ("top,leading,bottom,trailing") and
                // `.listRowBackground` (a colour) on the row.
                // A side left to the host (the edge form of `.listRowInsets`)
                // is "-": the host's own metric there.
                if let insets = node.listRowInsets {
                    let value = [insets.top, insets.leading, insets.bottom, insets.trailing]
                        .map { $0.isInfinite ? "-" : formatNumber(Double($0)) }.joined(separator: ",")
                    out.params = (out.params ?? []) + [("rowInsets", value)]
                }
                if let background = node.listRowBackground { out.params = (out.params ?? []) + [("rowBg", hexColor(background))] }
                // A view behind the row (its background layer): the host
                // draws neither its cell fill nor its selection.
                if node.listRowBackgroundNode != nil { out.params = (out.params ?? []) + [("rowOwnBg", "1")] }
            }
            // A List row off screen, not built: the host keeps its place.
            if node.isRowPlaceholder { out.params = (out.params ?? []) + [("placeholder", "1")] }
            // `ViewThatFits`: its children are the candidates; the host shows
            // the first whose ideal size fits along these axes ("h", "v",
            // "hv"), else the last.
            if let axes = node.fitsAxes {
                let named = (axes.contains(.horizontal) ? "h" : "") + (axes.contains(.vertical) ? "v" : "")
                out.params = (out.params ?? []) + [("fits", named)]
            }
        case .text(let string):
            out.kind = .text
            out.v = string
            if let symbol = node.symbolName {
                out.params = [("symbol", symbol)]
                if let secondary = node.symbolSecondary { out.params?.append(("symbol2", hexColor(secondary))) }
                if node.symbolIsImage { out.params?.append(("symbolImage", "1")) }
            }
            if !node.textRuns.isEmpty {
                let encoded = node.textRuns.map { run -> String in
                    var flags = ""
                    if run.bold { flags += "b" }
                    if run.italic { flags += "i" }
                    if run.monospaced { flags += "m" }
                    if run.underline { flags += "u" }
                    if run.strikethrough { flags += "s" }
                    // Its exact weight ("w600"), for hosts with every weight.
                    if let weight = run.weight { flags += "w\(weight)" }
                    if run.link != nil { flags += "l" }
                    if run.strong { flags += "S" }
                    if run.emphasized { flags += "E" }
                    var part = "\(run.length):\(flags)"
                    if let color = run.color {
                        let c = flatColor(color)
                        part += ":" + [c.r, c.g, c.b, c.a].map { formatNumber(Double($0)) }.joined(separator: ",")
                    }
                    return part
                }.joined(separator: ";")
                out.params = (out.params ?? []) + [("runs", encoded)]
                // Link runs' URLs, in run order (unit-separated).
                let links = node.textRuns.compactMap(\.link)
                if !links.isEmpty { out.params = (out.params ?? []) + [("runLinks", links.joined(separator: "\u{1F}"))] }
            }
            if let truncation = node.truncation { out.params = (out.params ?? []) + [("truncation", truncation)] }
            if let textCase = node.textCase { out.params = (out.params ?? []) + [("textCase", textCase)] }
            if let spacing = node.lineSpacing, spacing > 0 { out.params = (out.params ?? []) + [("lineSpacing", formatNumber(spacing))] }
        case .shape(let shapeKind, _, _):
            out.kind = .shape
            (out.shape, shapeRadius) = flatShape(shapeKind)
            // An app's own shape: its path in the unit square, for the host
            // to scale to the frame.
            if case .path(let path) = shapeKind {
                out.params = (out.params ?? []) + [("path", path.serialized)]
            }
            // `.trim(from:to:)`: the arc a ring draws.
            if let trim = node.trim {
                out.params = (out.params ?? []) + [("trim", "\(formatNumber(Double(trim.0))),\(formatNumber(Double(trim.1)))")]
            }
        case .stack:
            out.kind = .stack
        case .spacer:
            out.kind = .spacer
        case .divider:
            out.kind = .divider
        case .scroll:
            out.kind = .scroll
        case .image(let source, _, _, _):
            out.kind = .image
            out.src = source
            // A picture's bytes for a host without an image channel, once.
            if !Runtime.shared.inlineImages.isEmpty, let bytes = Runtime.shared.inlineImages.removeValue(forKey: source) {
                out.params = (out.params ?? []) + [("imageData", base64Encoded(bytes))]
            }
            // Bytes that come later flatten it again (taking them).
            liveProbes.append(LiveProbe(read: { Runtime.shared.inlineImages[source] == nil ? "" : "bytes" }, value: ""))
        case .textField(let placeholder):
            // Its text and focus are read live: the subtree is cached while
            // they hold.
            let textGet = node.textGet, focusGet = node.focusGet, selectionGet = node.selectionGet
            let readField: () -> String = {
                (textGet?() ?? "") + "\u{1}" + (focusGet.map { $0() ? "1" : "0" } ?? "")
                    + "\u{1}" + (selectionGet?().map { "\($0.request)" } ?? "")
            }
            liveProbes.append(LiveProbe(read: readField, value: readField()))
            out.kind = .textfield
            out.placeholder = placeholder
            // A stable identity so consumers can hold focus-local edit state.
            out.id = node.identityPath ?? handle()
            if let get = node.textGet { out.v = get() }
            if let style = node.textFieldStyle, style != "automatic" {
                out.params = (out.params ?? []) + [("fieldStyle", style)]
            }
            if let submit = node.textSubmit {
                let id = "\(handle()).submit"
                register(id, { _ in submit() })
                out.params = (out.params ?? []) + [("submit", id)]
            }
            if !node.keyPress.isEmpty {
                // `.onKeyPress`: the host reports the field's keys
                // synchronously (Runtime.keyPressEvent) so a key taken
                // here is not also typed.
                let handlers = node.keyPress
                let id = "\(handle()).keys"
                register(id, { value in
                    guard let press = KeyPress(hostValue: value) else { return }
                    for handler in handlers where handler.phases.contains(press.phase) {
                        if handler.action(press) == .handled {
                            Runtime.shared.keyPressHandled = true
                            return
                        }
                    }
                })
                let phases = handlers.reduce(KeyPress.Phases()) { $0.union($1.phases) }
                out.params = (out.params ?? []) + [("keys", id), ("keyUp", phases.contains(.up) ? "1" : "0")]
            }
            if let keyboard = node.keyboardType, keyboard != "default" {
                out.params = (out.params ?? []) + [("keyboard", keyboard)]
            }
            if node.secureEntry { out.params = (out.params ?? []) + [("secure", "1")] }
            if let autocap = node.autocapitalization {
                out.params = (out.params ?? []) + [("autocap", autocap)]
            }
            if node.autocorrectionDisabled {
                out.params = (out.params ?? []) + [("autocorrect", "0")]
            }
            if let focusGet = node.focusGet, let focusSet = node.focusSet {
                // `focus` = what the guest wants now; `focusId` = where the
                // host reports the field gaining/losing focus ("1"/"0").
                let id = "\(handle()).focus"
                register(id, { value in focusSet(value == "1") })
                out.params = (out.params ?? []) + [("focus", focusGet() ? "1" : "0"), ("focusId", id)]
            }
            if let set = node.textSet {
                let id = "\(handle()).text"
                register(id, set)
                out.edit = id
            }
            if let selectionSet = node.selectionSet {
                // `TextField(_:text:selection:)`: `selId` = where the host
                // reports the field's selection ("start,end", UTF-16
                // offsets); `sel` = one the app set for the host to show,
                // "start,end,request" (a host shows each request once, so its
                // own reports coming back don't move the caret).
                let id = "\(handle()).selection"
                register(id, { value in
                    let bounds = value.split(separator: ",").compactMap { Int($0) }
                    if bounds.count == 2 { selectionSet(bounds[0], bounds[1]) }
                })
                out.params = (out.params ?? []) + [("selId", id)]
                if let requested = node.selectionGet?() {
                    out.params = (out.params ?? []) + [("sel", "\(requested.start),\(requested.end),\(requested.request)")]
                }
            }
            // Growing multi-line form (`TextField(_:text:axis: .vertical)`):
            // rides the generic params channel; hosts render a wrapping
            // input sized between minLines and maxLines.
            if node.textAxis == .vertical {
                let range = node.lineRange ?? 1 ... 5
                out.params = (out.params ?? []) + [
                    ("axis", "v"),
                    ("minLines", "\(max(1, range.lowerBound))"),
                    ("maxLines", "\(max(1, range.upperBound))"),
                ]
            }
            // `TextEditor`: a multi-line editor that FILLS its container
            // (no line cap) — hosts render a full-height text view.
            if node.textEditor {
                out.params = (out.params ?? []) + [("editor", "1")]
            }
            if node.font.design == .monospaced {
                out.params = (out.params ?? []) + [("mono", "1")]
            }
        case .slider:
            out.kind = .slider
            out.num = node.sliderFraction
            if let set = node.sliderSet {
                let id = "\(handle()).slider"
                register(id, { value in set(Double(value) ?? 0) })
                out.edit = id
            }
        case .gradient(let shapeKind, let paint):
            out.kind = .gradient
            (out.shape, shapeRadius) = flatShape(shapeKind)
            out.gradient = paint.json()
        case .hostView(let spec):
            out.kind = .hostview
            out.view = spec.kind
            out.v = spec.value
            if let onChange = spec.onChange {
                let id = "\(handle()).host"
                register(id, onChange)
                out.edit = id
            }
            if !spec.options.isEmpty { out.options = spec.options }
            if !spec.params.isEmpty {
                out.params = spec.params.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            }
            // A menu whose label is a view of the app's own: the host draws
            // the child instead of the label's words.
            if spec.kind == "menu", !node.children.isEmpty {
                out.params = (out.params ?? []) + [("labelContent", "1")]
            }
        case .progress(let value):
            out.kind = .progress
            out.num = value
            if let size = node.controlSize { out.params = [("size", size)] }
        case .geometryReader:
            out.kind = .box // unreachable (handled above); box keeps layout sane
        }

        // Text / control typography.
        switch node.kind {
        case .text:
            out.fontSize = Double(node.font.size)
            out.weight = Int32(node.font.weight.value)
            out.color = flatColor(node.color)
            if let name = systemColorName(node.color) { out.params = (out.params ?? []) + [("colorName", name)] }
            // The text style (hosts with a type ramp use it) and whether the
            // colour is the container's to choose.
            if let style = node.font.textStyle { out.params = (out.params ?? []) + [("textStyle", style)] }
            if node.colorAuto { out.params = (out.params ?? []) + [("autoColor", "1")] }
            if node.fontAuto { out.params = (out.params ?? []) + [("autoFont", "1")] }
            if let limit = node.lineLimit { out.lines = Int32(limit) }
            // `.font(.system(_, design: .monospaced))` / `.monospaced()`.
            if node.font.design == .monospaced {
                out.params = (out.params ?? []) + [("mono", "1")]
            }
            // The other designs, and a typeface by name (`Font.custom`).
            if node.font.design == .serif { out.params = (out.params ?? []) + [("design", "serif")] }
            if node.font.design == .rounded { out.params = (out.params ?? []) + [("design", "rounded")] }
            if let family = node.font.family { out.params = (out.params ?? []) + [("family", family)] }
        case .textField:
            out.fontSize = Double(node.font.size)
            // Its text style, as a Text's: a field's line height is its
            // font's, and a growing field (a composer) is lines of it.
            if let style = node.font.textStyle { out.params = (out.params ?? []) + [("textStyle", style)] }
        default:
            break
        }

        // Shape fill/stroke.
        if case .shape(_, let fill, let stroke) = node.kind {
            if let fill {
                out.fill = flatColor(fill)
                if let name = systemColorName(fill) { out.params = (out.params ?? []) + [("fillName", name)] }
            }
            if let stroke {
                out.stroke = flatColor(stroke.0)
                out.strokeWidth = Double(stroke.1)
                // By name too, as the fill: a host's own accent dims behind
                // a popover, as SwiftUI's does (a card's border).
                if let name = systemColorName(stroke.0) { out.params = (out.params ?? []) + [("strokeName", name)] }
            }
        }

        // A `Grid`'s line (row or spanning view): its index among the lines.
        if let line = node.gridLine { out.params = (out.params ?? []) + [("gridLine", String(line))] }

        // Axis / spacing / spacer / image flags.
        switch node.kind {
        case .stack(let axis):
            out.axis = flatAxis(axis)
            if let spacing = node.stackSpacing { out.spacing = Double(spacing) }
            // `.safeAreaInset(edge:)`: the inset child is bar chrome at that edge.
            if let edge = node.safeAreaEdge {
                out.params = (out.params ?? []) + [("inset", edge)]
                if node.safeAreaBar { out.params = (out.params ?? []) + [("insetBar", "1")] }
                if let spacing = node.safeAreaSpacing { out.params = (out.params ?? []) + [("insetSpacing", String(Double(spacing)))] }
            }
            if let bar = node.bottomBarItems { out.params = (out.params ?? []) + [("bottomBar", bar)] }
            if let columns = node.gridColumns { out.params = (out.params ?? []) + [("grid", String(columns))] }
            if node.isGridRow { out.params = (out.params ?? []) + [("gridRow", "1")] }
        case .scroll(let axis):
            // A pending scroll request, and a lazy list's epoch and row
            // count, are read live: the subtree is cached while they hold.
            let lazyList = node.lazyRows ? node.identityPath : nil
            let readScroll: () -> String = {
                let runtime = Runtime.shared
                var value = ""
                if let pending = runtime.pendingScroll, lazyList.map(runtime.listHoldsScrollTarget) ?? scrollTargets.contains(pending.target) {
                    value = "\(pending.target)|\(pending.tick)|\(pending.anchor)|\(pending.animated)"
                }
                if let list = lazyList {
                    value += "|\(runtime.listEpochs[list] ?? -1)|\(runtime.listRowCounts[list] ?? -1)"
                }
                return value
            }
            liveProbes.append(LiveProbe(read: readScroll, value: readScroll()))
            out.axis = flatAxis(axis)
            var scrollParams: [(String, String)] = []
            // A scroll is handed a request only for a target inside it (the
            // host acts on the scroll holding it): a lazy list, for a row it
            // has (built or not); another scroll, for an `.id` within.
            if let pending = Runtime.shared.pendingScroll,
               lazyList.map(Runtime.shared.listHoldsScrollTarget) ?? scrollTargets.contains(pending.target) {
                scrollParams.append(("scrollTo", "\(pending.target)|\(pending.tick)|\(pending.anchor)" + (pending.animated ? "|a" : "")))
            }
            // `.defaultScrollAnchor(.bottom)`: hosts start the scroll at the
            // bottom and keep it pinned there while at that edge as content
            // grows (chat logs). Only the bottom anchor crosses the wire —
            // the top is the default and other anchors have no consumer yet.
            if let anchor = node.scrollAnchor, anchor.y == 1 {
                scrollParams.append(("anchor", "bottom"))
                if let role = node.scrollAnchorRole { scrollParams.append(("anchorFor", role)) }
            }
            // Content shorter than the scroll sits at its bottom (the
            // alignment role; plain `.defaultScrollAnchor(.bottom)` has it).
            if let alignment = node.scrollAlignment, alignment.y == 1 {
                scrollParams.append(("anchorAlign", "bottom"))
            }
            // `onScrollGeometryChange`: the host reports the scroll's
            // geometry as it changes (not a render by itself).
            if !node.scrollGeometryHandlers.isEmpty {
                let handlers = node.scrollGeometryHandlers
                let id = "\(handle()).geometry"
                register(id, { value in
                    guard let geometry = ScrollGeometry(hostValue: value) else { return }
                    MainActor.assumeIsolated { for entry in handlers { entry.handler(geometry) } }
                })
                scrollParams.append(("geometry", id))
            }
            // `.scrollEdgeEffectStyle(_:for:)`: "hard", an opaque band under
            // the bar at that edge, or "soft", fading and visible (a plain
            // List's own edge on iOS 26 is hard; a host with the effect
            // applies either, others draw the band for hard alone).
            if let name = scrollEdgeStyleName(node.scrollEdgeTop) { scrollParams.append(("edgeTop", name)) }
            if let name = scrollEdgeStyleName(node.scrollEdgeBottom) { scrollParams.append(("edgeBottom", name)) }
            // A `List`: hosts with a native list component render it as one.
            if node.isList { scrollParams.append(("list", "1")) }
            // Lazy rows: the host reports the rows it shows ("first,last"),
            // and the list builds around them.
            if node.lazyRows, let list = node.identityPath {
                let id = "\(handle()).window"
                register(id, { value in Runtime.shared.listWindowReported(list: list, value: value) })
                scrollParams.append(("window", id))
                // Its rows replaced wholesale (another conversation): a
                // bottom-anchored host lands at the new bottom at once.
                if let epoch = Runtime.shared.listEpochs[list] { scrollParams.append(("epoch", String(epoch))) }
                // The rows this build has, echoed in the host's reports.
                if let rows = Runtime.shared.listRowCounts[list] { scrollParams.append(("rows", String(rows))) }
            }
            if let style = node.listStyle, style != "automatic" { scrollParams.append(("listStyle", style)) }
            if node.isList, !node.listRowSeparators { scrollParams.append(("separators", "0")) }
            if !node.showsIndicators { scrollParams.append(("indicators", "hidden")) }
            if node.contentBackgroundHidden { scrollParams.append(("contentBg", "hidden")) }
            if node.isList, let least = node.minListRowHeight { scrollParams.append(("minRowHeight", formatNumber(Double(least)))) }
            // `.scrollDisabled(true)`: the host doesn't let it scroll.
            if node.scrollDisabled { scrollParams.append(("scrollDisabled", "1")) }
            if let bounce = node.scrollBounce, !bounce.hasPrefix("automatic") {
                scrollParams.append(("bounce", bounce))
            }
            if let mode = node.dismissesKeyboard, mode != "automatic" {
                scrollParams.append(("dismissKeyboard", mode))
            }
            if !scrollParams.isEmpty { out.params = scrollParams }
        case .spacer(let minLength):
            if let minLength { out.min = Double(minLength) }
        case .image(_, let isRemote, let resizable, let fit):
            out.remote = isRemote
            out.resizable = resizable
            out.fit = fit
        default:
            break
        }

        // A shape/gradient background collapses onto the node as a fill.
        var bgRadius: Double? = nil
        if let background = node.background.first {
            func backgroundRadius(_ shapeKind: ShapeKind) -> Double? {
                guard node.cornerRadius == 0 else { return nil }
                switch shapeKind {
                case .roundedRectangle(let radius): return Double(radius)
                case .circle, .capsule: return 9999
                case .rectangle, .path: return nil
                }
            }
            if case .shape(let shapeKind, let fill, _) = background.kind, let fill {
                out.bg = flatColor(fill)
                if let name = systemColorName(fill) { out.params = (out.params ?? []) + [("bgName", name)] }
                bgRadius = backgroundRadius(shapeKind)
            } else if case .gradient(let shapeKind, let paint) = background.kind {
                out.gradient = paint.json()
                bgRadius = backgroundRadius(shapeKind)
            }
        }

        if let action = node.tapAction {
            let id = "\(handle()).tap"
            register(id, { _ in action() })
            out.tap = id
            out.feedback = Int32(node.pressFeedback.rawValue)
            if node.tapCount > 1 { out.params = (out.params ?? []) + [("tapCount", String(node.tapCount))] }
        }
        // `.dropDestination`: the host takes the drop, stores the files and
        // sends their paths ("over:1" / "over:0" while a drag hovers).
        if let drop = node.dropAction {
            let id = "\(handle()).drop"
            let targeted = node.dropTargeted
            register(id, { value in
                if value.hasPrefix("over:") { targeted?(value == "over:1"); return }
                drop(value.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
            })
            out.params = (out.params ?? []) + [("drop", id)]
        }

        // Row actions: the items as params (title, symbol, destructive per
        // item; unit-separated), the handler keyed by the item's index.
        if !node.contextMenuItems.isEmpty {
            let id = "\(handle()).ctx"
            let items = node.contextMenuItems
            register(id, { raw in if let i = Int(raw), items.indices.contains(i) { items[i].action() } })
            out.params = (out.params ?? []) + [("ctxmenu", id), ("ctxitems", encodeRowActions(items))]
        }
        if !node.swipeItems.isEmpty {
            let id = "\(handle()).swipe"
            let items = node.swipeItems
            register(id, { raw in if let i = Int(raw), items.indices.contains(i) { items[i].item.action() } })
            let leading = items.filter { $0.edge == .leading }
            let trailing = items.filter { $0.edge == .trailing }
            var params: [(String, String)] = [("swipe", id)]
            if !leading.isEmpty { params.append(("swipeLeading", encodeRowActions(leading.map(\.item), indices: items.indices.filter { items[$0].edge == .leading }))) }
            if !trailing.isEmpty { params.append(("swipeTrailing", encodeRowActions(trailing.map(\.item), indices: items.indices.filter { items[$0].edge == .trailing }))) }
            if items.contains(where: { $0.fullSwipe }) { params.append(("swipeFull", "1")) }
            out.params = (out.params ?? []) + params
        }

        let inset = node.padding
        if inset.top != 0 || inset.leading != 0 || inset.bottom != 0 || inset.trailing != 0 {
            out.padding = [
                Double(inset.top), Double(inset.leading),
                Double(inset.bottom), Double(inset.trailing),
            ]
        }

        // SwiftUI greediness propagates up: a container holding a greedy
        // descendant (scroll, spacer, .infinity frame) is itself greedy. The
        // consumer maps these to flex-grow/stretch along its layout axes.
        let grow = greediness(node)
        out.growW = grow.w
        out.growH = grow.h

        // Alignment (leading/top = start, trailing/bottom = end).
        if case .stack = node.kind {
            if node.stackAlignment.horizontal != .center {
                out.alignH = flatAlign(node.stackAlignment.horizontal)
            }
            if node.stackAlignment.vertical != .center {
                out.alignV = flatAlign(node.stackAlignment.vertical)
            }
        } else if node.alignment != .center {
            out.alignH = flatAlign(node.alignment.horizontal)
            out.alignV = flatAlign(node.alignment.vertical)
        } else if node.textAlignmentExplicit {
            out.alignH = flatAlign(HorizontalAlignment.center)
        }

        if let shadow = node.shadow {
            out.shadow = IsoFlat_ShadowSpec(
                color: flatColor(shadow.color),
                radius: Float32(shadow.radius),
                x: Float32(shadow.x),
                y: Float32(shadow.y))
        }

        out.width = node.fixedWidth.map { Double($0) }
        out.height = node.fixedHeight.map { Double($0) }
        out.expandW = node.expandsWidth || node.maxWidth == .infinity
        out.expandH = node.expandsHeight || node.maxHeight == .infinity
        // Finite frame bounds (`.frame(minWidth:maxWidth:…)`) ride the params
        // channel; hosts clamp the flexible frame to them.
        if let maxWidth = node.maxWidth, maxWidth != .infinity { out.params = (out.params ?? []) + [("maxW", "\(Int(maxWidth))")] }
        if let maxHeight = node.maxHeight, maxHeight != .infinity { out.params = (out.params ?? []) + [("maxH", "\(Int(maxHeight))")] }
        if let minWidth = node.minWidth, node.fixedWidth == nil { out.params = (out.params ?? []) + [("minW", "\(Int(minWidth))")] }
        if let minHeight = node.minHeight, node.fixedHeight == nil { out.params = (out.params ?? []) + [("minH", "\(Int(minHeight))")] }
        if node.cornerRadius != 0 {
            out.radius = Double(node.cornerRadius)
        } else if let shapeRadius {
            out.radius = shapeRadius
        } else if let bgRadius {
            out.radius = bgRadius
            // The background's corners only: hosts round the fill with it,
            // but SwiftUI's `.background(RoundedRectangle(…))` and
            // `.glassEffect(in:)` don't clip what is in front (a glass's
            // rim and shadow lie on its edge).
            out.params = (out.params ?? []) + [("radiusOf", "bg")]
        }
        if node.opacity != 1 { out.opacity = node.opacity }
        // Visual transforms: the animator has already interpolated these
        // toward their targets (Animation.swift), so a `withAnimation`
        // change ships as a short run of patches and the host applies each
        // frame's value — the same motion every renderer sees.
        if node.offsetX != 0 { out.offsetX = Double(node.offsetX) }
        if node.offsetY != 0 { out.offsetY = Double(node.offsetY) }
        if node.scaleEffect != 1 { out.scale = Double(node.scaleEffect) }
        // `.position`: the greedy box's child centered at (x, y); hosts
        // apply their own positioning (SwiftUI `.position`, CSS absolute).
        if let x = node.positionX, let y = node.positionY {
            out.params = (out.params ?? []) + [("posX", formatNumber(Double(x))), ("posY", formatNumber(Double(y)))]
        }
        if node.clipsContent {
            out.params = (out.params ?? []) + [("clip", "1")]
        }
        if let fixed = node.fixedSize {
            out.params = (out.params ?? []) + [("fixed", fixed)]
        }
        if let ratio = node.aspectRatio {
            out.params = (out.params ?? []) + [("aspect", formatNumber(Double(ratio))), ("aspectMode", node.aspectFill ? "fill" : "fit")]
        }
        if let interpolation = node.imageInterpolation {
            out.params = (out.params ?? []) + [("interp", interpolation)]
        }
        if node.zIndex != 0 { out.params = (out.params ?? []) + [("z", formatNumber(node.zIndex))] }
        if node.buttonDisabled { out.params = (out.params ?? []) + [("disabled", "1")] }
        if node.hitTestingDisabled { out.params = (out.params ?? []) + [("nohit", "1")] }
        if node.floatsAboveChrome { out.params = (out.params ?? []) + [("float", "1")] }
        if let hover = node.hoverAction {
            let id = "\(handle()).hover"
            register(id, { value in hover(value == "1") })
            out.params = (out.params ?? []) + [("hover", id)]
        }
        if !node.hostHints.isEmpty { out.params = (out.params ?? []) + node.hostHints }
        // `.textSelection`: "1" the text inside is selectable, "0" it isn't.
        if let selectable = node.textSelection {
            out.params = (out.params ?? []) + [("select", selectable ? "1" : "0")]
        }
        // `.tint`: the subtree's accent color, as #rrggbbaa.
        // A Button (its style, size, shape, role) and a Label's stack, for
        // hosts that make the system's own.
        if let style = node.buttonStyleName {
            var params: [(String, String)] = [("button", style)]
            if let size = node.buttonControlSize { params.append(("controlSize", size)) }
            if let shape = node.buttonBorderShape { params.append(("borderShape", shape)) }
            if let role = node.buttonRole { params.append(("role", role.wireName)) }
            out.params = (out.params ?? []) + params
        }
        if node.isLabel { out.params = (out.params ?? []) + [("label", "1")] }
        if let role = node.formRole { out.params = (out.params ?? []) + [("form", role)] }
        if let width = node.columnWidth {
            var params: [(String, String)] = [("colWidth", String(Int(width.ideal)))]
            if let min = width.min { params.append(("colWidthMin", String(Int(min)))) }
            if let max = width.max { params.append(("colWidthMax", String(Int(max)))) }
            out.params = (out.params ?? []) + params
        }
        if let item = node.shareItem {
            var params: [(String, String)] = [("share", item)]
            if let subject = node.shareSubject { params.append(("shareSubject", subject)) }
            if let message = node.shareMessage { params.append(("shareMessage", message)) }
            if let style = node.shareStyle { params.append(("shareStyle", style)) }
            if let preview = node.sharePreview { params.append(("sharePreview", preview)) }
            out.params = (out.params ?? []) + params
        }
        if let tint = node.tint {
            out.params = (out.params ?? []) + [("tint", hexColor(tint))]
            if let name = systemColorName(tint) { out.params = (out.params ?? []) + [("tintName", name)] }
        }
        // A drag gesture: the host tracks the pointer and reports the running
        // translation ("changed:x,y") and the release ("ended:x,y") on the
        // node's ".drag" id; the guest's DragGesture callbacks run from there.
        if let gesture = node.dragGesture {
            let id = "\(handle()).drag"
            register(id, { value in
                let parts = value.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return }
                let numbers = parts[1].split(separator: ",")
                guard numbers.count == 2, let x = Double(numbers[0]), let y = Double(numbers[1]) else { return }
                let translation = CGSize(width: x, height: y)
                let payload = DragGesture.Value(
                    startLocation: .zero, location: CGPoint(x: x, y: y),
                    translation: translation, predictedEndLocation: CGPoint(x: x, y: y))
                switch parts[0] {
                case "changed": gesture.onChangedAction?(payload)
                case "ended": gesture.onEndedAction?(payload)
                default: break
                }
            })
            out.drag = id
            // How far the pointer moves before the drag begins: a press that
            // moves less stays a tap for the views inside.
            out.params = (out.params ?? []) + [("dragMin", formatNumber(Double(gesture.minimumDistance)))]
        }
        // A pinch: the host reports the magnification since it began
        // ("changed:<m>" as it moves, "ended:<m>" when the fingers lift).
        if node.magnifyChanged != nil || node.magnifyEnded != nil {
            let id = "\(handle()).magnify"
            let changed = node.magnifyChanged
            let ended = node.magnifyEnded
            register(id, { value in
                let parts = value.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let m = Double(parts[1]) else { return }
                if parts[0] == "changed" { changed?(CGFloat(m)) } else if parts[0] == "ended" { ended?(CGFloat(m)) }
            })
            out.params = (out.params ?? []) + [("magnify", id)]
        }
        if node.ignoresSafeArea {
            out.params = (out.params ?? []) + [("safeArea", "ignore")]
        }
        var a11y: [(String, String)] = []
        if let target = node.scrollTarget { a11y.append(("vid", target)) }
        if let label = node.accessibilityLabel { a11y.append(("a11yLabel", label)) }
        if let hint = node.accessibilityHint { a11y.append(("a11yHint", hint)) }
        if let value = node.accessibilityValue { a11y.append(("a11yValue", value)) }
        if let id = node.accessibilityIdentifier { a11y.append(("a11yId", id)) }
        if node.accessibilityHidden { a11y.append(("a11yHidden", "1")) }
        if let children = node.accessibilityChildren { a11y.append(("a11yChildren", children)) }
        if !a11y.isEmpty { out.params = (out.params ?? []) + a11y }
        // The view a popover hangs from (hosts that present popovers
        // natively anchor it here; the others ignore it).
        if let popover = node.popoverAnchor { out.params = (out.params ?? []) + [("popover", popover)] }

        return out
    }

    // MARK: - Serialize (FlatNode -> FlatBuffer Node)

    /// Serializes a `FlatNode` to a `Node` table. When `includeChildren` is
    /// false the `ch` vector is omitted — the attrs-only patch encoding whose
    /// consumer keeps the retained node's existing children.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func serialize(
        _ node: FlatNode, includeChildren: Bool, _ fbb: inout FlatBufferBuilder
    ) -> Offset {
        // Children and every string/vector are created BEFORE the table.
        let childOffsets: [Offset] = includeChildren
            ? node.children.map { serialize($0, includeChildren: true, &fbb) }
            : []
        let childrenVector: Offset? =
            childOffsets.isEmpty ? nil : fbb.createVector(ofOffsets: childOffsets)

        let vOffset = node.v.map { fbb.create(string: $0) }
        let idOffset = node.id.map { fbb.create(string: $0) }
        let srcOffset = node.src.map { fbb.create(string: $0) }
        let placeholderOffset = node.placeholder.map { fbb.create(string: $0) }
        let editOffset = node.edit.map { fbb.create(string: $0) }
        let viewOffset = node.view.map { fbb.create(string: $0) }
        let gradientOffset = node.gradient.map { fbb.create(string: $0) }
        let tapOffset = node.tap.map { fbb.create(string: $0) }
        let titleOffset = node.title.map { fbb.create(string: $0) }
        let messageOffset = node.message.map { fbb.create(string: $0) }
        let dismissOffset = node.dismiss.map { fbb.create(string: $0) }
        let dragOffset = node.drag.map { fbb.create(string: $0) }
        let keyOffset = node.key.map { fbb.create(string: $0) }
        let optionsVector = node.options.map { options in
            fbb.createVector(ofOffsets: options.map { fbb.create(string: $0) })
        }
        let paramsVector = node.params.map { params -> Offset in
            let entries = params.map { key, value -> Offset in
                let keyOffset = fbb.create(string: key)
                let valueOffset = fbb.create(string: value)
                return IsoFlat_KV.createKV(&fbb, keyOffset: keyOffset, valueOffset: valueOffset)
            }
            return fbb.createVector(ofOffsets: entries)
        }
        let paddingVector = node.padding.map { fbb.createVector($0) }

        let start = IsoFlat_Node.startNode(&fbb)
        IsoFlat_Node.add(kind: node.kind, &fbb)
        if let vOffset { IsoFlat_Node.add(v: vOffset, &fbb) }
        if let num = node.num { IsoFlat_Node.add(num: num, &fbb) }
        if let idOffset { IsoFlat_Node.add(id: idOffset, &fbb) }
        if let fontSize = node.fontSize { IsoFlat_Node.add(size: fontSize, &fbb) }
        if let weight = node.weight { IsoFlat_Node.add(weight: weight, &fbb) }
        if let color = node.color { IsoFlat_Node.add(color: color, &fbb) }
        if let lines = node.lines { IsoFlat_Node.add(lines: lines, &fbb) }
        if let shape = node.shape { IsoFlat_Node.add(shape: shape, &fbb) }
        if let fill = node.fill { IsoFlat_Node.add(fill: fill, &fbb) }
        if let stroke = node.stroke { IsoFlat_Node.add(stroke: stroke, &fbb) }
        if let strokeWidth = node.strokeWidth { IsoFlat_Node.add(strokeWidth: strokeWidth, &fbb) }
        if let axis = node.axis { IsoFlat_Node.add(axis: axis, &fbb) }
        if let spacing = node.spacing { IsoFlat_Node.add(spacing: spacing, &fbb) }
        if let min = node.min { IsoFlat_Node.add(min: min, &fbb) }
        if let srcOffset { IsoFlat_Node.add(src: srcOffset, &fbb) }
        if let remote = node.remote { IsoFlat_Node.add(remote: remote, &fbb) }
        if let resizable = node.resizable { IsoFlat_Node.add(resizable: resizable, &fbb) }
        if let fit = node.fit { IsoFlat_Node.add(fit: fit, &fbb) }
        if let placeholderOffset { IsoFlat_Node.add(placeholder: placeholderOffset, &fbb) }
        if let editOffset { IsoFlat_Node.add(edit: editOffset, &fbb) }
        if let viewOffset { IsoFlat_Node.add(view: viewOffset, &fbb) }
        if let optionsVector { IsoFlat_Node.addVectorOf(options: optionsVector, &fbb) }
        if let paramsVector { IsoFlat_Node.addVectorOf(params: paramsVector, &fbb) }
        if node.growW { IsoFlat_Node.add(growW: true, &fbb) }
        if node.growH { IsoFlat_Node.add(growH: true, &fbb) }
        if let alignH = node.alignH { IsoFlat_Node.add(alignH: alignH, &fbb) }
        if let alignV = node.alignV { IsoFlat_Node.add(alignV: alignV, &fbb) }
        if let shadow = node.shadow { IsoFlat_Node.add(shadow: shadow, &fbb) }
        if let paddingVector { IsoFlat_Node.addVectorOf(padding: paddingVector, &fbb) }
        if let width = node.width { IsoFlat_Node.add(width: width, &fbb) }
        if let height = node.height { IsoFlat_Node.add(height: height, &fbb) }
        if node.expandW { IsoFlat_Node.add(expandW: true, &fbb) }
        if node.expandH { IsoFlat_Node.add(expandH: true, &fbb) }
        if let radius = node.radius { IsoFlat_Node.add(radius: radius, &fbb) }
        if let opacity = node.opacity { IsoFlat_Node.add(opacity: opacity, &fbb) }
        if let bg = node.bg { IsoFlat_Node.add(bg: bg, &fbb) }
        if let gradientOffset { IsoFlat_Node.add(gradient: gradientOffset, &fbb) }
        if let tapOffset {
            IsoFlat_Node.add(tap: tapOffset, &fbb)
            if let feedback = node.feedback { IsoFlat_Node.add(feedback: feedback, &fbb) }
        }
        if let style = node.style { IsoFlat_Node.add(style: style, &fbb) }
        if let titleOffset { IsoFlat_Node.add(title: titleOffset, &fbb) }
        if let messageOffset { IsoFlat_Node.add(message: messageOffset, &fbb) }
        if let dismissOffset { IsoFlat_Node.add(dismiss: dismissOffset, &fbb) }
        if let childrenVector { IsoFlat_Node.addVectorOf(ch: childrenVector, &fbb) }
        if let offsetX = node.offsetX { IsoFlat_Node.add(offsetX: offsetX, &fbb) }
        if let offsetY = node.offsetY { IsoFlat_Node.add(offsetY: offsetY, &fbb) }
        if let scale = node.scale { IsoFlat_Node.add(scale: scale, &fbb) }
        if let dragOffset { IsoFlat_Node.add(drag: dragOffset, &fbb) }
        if let keyOffset { IsoFlat_Node.add(key: keyOffset, &fbb) }
        return IsoFlat_Node.endNode(&fbb, start: start)
    }

    // MARK: - Mapping helpers

    /// "#rrggbbaa" for a color (no Foundation formatting here).
    private func hexColor(_ value: Color) -> String { wireHexColor(value) }

    /// A number as a short decimal string ("12.5", "-3", "0").
    private func formatNumber(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(rounded)
    }

    private func flatColor(_ value: Color) -> IsoFlat_ColorRGBA {
        IsoFlat_ColorRGBA(
            r: Float32(value.red), g: Float32(value.green),
            b: Float32(value.blue), a: Float32(value.alpha))
    }

    private func flatAxis(_ axis: StackAxis) -> IsoFlat_Axis {
        switch axis {
        case .horizontal: return .horizontal
        case .vertical: return .vertical
        case .depth: return .depth
        }
    }

    private func flatAlign(_ alignment: HorizontalAlignment) -> IsoFlat_Align {
        switch alignment.kind {
        case .leading: return .start
        case .center: return .center
        case .trailing: return .end
        }
    }

    private func flatAlign(_ alignment: VerticalAlignment) -> IsoFlat_Align {
        switch alignment.kind {
        case .top: return .start
        case .center: return .center
        case .bottom: return .end
        }
    }

    private func flatShape(_ shape: ShapeKind) -> (IsoFlat_Shape, Double?) {
        switch shape {
        case .rectangle: return (.rect, nil)
        case .roundedRectangle(let radius): return (.rect, Double(radius))
        case .circle: return (.circle, nil)
        case .capsule: return (.capsule, nil)
        case .path: return (.rect, nil)
        }
    }

    /// Flattens a node's children, keying each on its identity relative to
    /// `anchor` (unique among the siblings; position for the runtime's own
    /// nodes). The keys are what the diff matches children on and what hosts
    /// key their components on.
    private func flattenChildren(_ children: [RenderNode], ident: String, anchor: String?) -> [FlatNode] {
        var seen: Set<String> = []
        var out: [FlatNode] = []
        out.reserveCapacity(children.count)
        for (index, child) in children.enumerated() {
            // A reused subtree reached the same way as last pass: its keyed
            // form as it was.
            if child.isReusedSubtreeRoot, let path = child.buildPath {
                let id = ObjectIdentifier(child)
                if let entry = flattenCache[id], let keyed = entry.keyed, entry.keyAnchor == anchor, entry.ident == path,
                   entry.stillLive {
                    flattenCacheReached.insert(id)
                    for index in recorders.indices { recorders[index].inner.append(id) }
                    replay(entry.record)
                    liveProbes += entry.probes
                    collectTargets(entry.targets)
                    if let key = keyed.key { seen.insert(key) }
                    out.append(keyed)
                    continue
                }
            }
            var key: String?
            if let path = child.buildPath {
                // Relative to the anchor when the path runs through it
                // ("<anchor>/…"). On UTF-8 bytes: build paths are long, and
                // Character counting and offsetting walk the whole string.
                if let anchor, _byteAfterPrefix(path, anchor) == UInt8(ascii: "/") {
                    let bytes = path.utf8
                    key = String(path[bytes.index(bytes.startIndex, offsetBy: anchor.utf8.count + 1)...])
                } else {
                    key = path
                }
                if !seen.insert(key!).inserted { key = key! + "#\(index)"; seen.insert(key!) }
            }
            var flat = flatten(child, ident: child.buildPath ?? "\(ident)/#\(index)", anchor: anchor)
            flat.setKey(key, fallback: "#\(index)")
            if child.isReusedSubtreeRoot, child.buildPath != nil {
                let id = ObjectIdentifier(child)
                if let entry = flattenCache[id] {
                    entry.keyed = flat
                    entry.keyAnchor = anchor
                }
            }
            out.append(flat)
        }
        return out
    }

    /// "n" and a base-36 FNV-1a hash of the identity: short, stable across
    /// frames and processes, and in the [a-z0-9.] alphabet tools scan for.
    private func handlerID(_ ident: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in ident.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return "n" + String(hash, radix: 36)
    }

    private func greediness(_ node: RenderNode) -> (w: Bool, h: Bool) {
        if let known = greedinessMemo[ObjectIdentifier(node)] { return (known.w, known.h) }
        // A reused subtree's root, flattened before: as it was (its subtree is
        // the same), without walking it again.
        if node.isReusedSubtreeRoot, let entry = flattenCache[ObjectIdentifier(node)], entry.node === node,
           entry.epoch == node.contentEpoch {
            return (entry.flat.growW, entry.flat.growH)
        }
        var w = node.expandsWidth || node.maxWidth == .infinity
        var h = node.expandsHeight || node.maxHeight == .infinity
        switch node.kind {
        case .scroll(let axis):
            if axis == .vertical { h = true } else { w = true }
        case .spacer:
            if node.spacerAxis == .vertical { h = true }
            if node.spacerAxis == .horizontal { w = true }
        case .shape, .gradient:
            // Shapes fill their proposed space (a fixed frame cancels below).
            w = true
            h = true
        case .geometryReader:
            // Greedy on both axes (core layout's rule) — and greediness must
            // reach the wire so the measured wrapper's ANCESTORS stretch too;
            // a content-sized ancestor would otherwise feed the reader its
            // own content width back, shrinking it geometrically.
            w = true
            h = true
        default:
            break
        }
        // A ViewThatFits is greedy as the candidate the host chooses is: the
        // host applies that one's (its own flags say only its frame's).
        for child in node.children where node.fitsAxes == nil {
            let g = greediness(child)
            w = w || g.w
            h = h || g.h
        }
        if node.fixedWidth != nil { w = false }
        if node.fixedHeight != nil { h = false }
        // A finite maximum height bounds what a greedy descendant takes
        // (`.frame(maxHeight: 92)` around a ScrollView: at most 92, as in
        // SwiftUI), so the views above it are not greedy for it. (They were:
        // a composer's suggestions list, a scroll view so capped, made the
        // composer fill the screen, and the flags its views changed made the
        // host build its field again, which took the keyboard away.)
        if let maxHeight = node.maxHeight, maxHeight.isFinite { h = false }
        greedinessMemo[ObjectIdentifier(node)] = (node, w, h)
        return (w, h)
    }
}

// MARK: - FlatNode

/// The encoder's retained, value-typed mirror of one render node: its own
/// serializable attributes and its child `FlatNode`s; `sameOwnAttributes`
/// compares the own attributes (children excluded) against the previous
/// frame's.
private struct FlatNode {
    var kind: IsoFlat_Kind

    var v: String?
    var num: Double?
    var id: String?
    var fontSize: Double?
    var weight: Int32?
    var color: IsoFlat_ColorRGBA?
    var lines: Int32?
    var shape: IsoFlat_Shape?
    var fill: IsoFlat_ColorRGBA?
    var stroke: IsoFlat_ColorRGBA?
    var strokeWidth: Double?
    var axis: IsoFlat_Axis?
    var spacing: Double?
    var min: Double?
    var src: String?
    var remote: Bool?
    var resizable: Bool?
    var fit: Bool?
    var placeholder: String?
    var edit: String?
    var view: String?
    var options: [String]?
    var params: [(String, String)]?
    var growW: Bool = false
    var growH: Bool = false
    var alignH: IsoFlat_Align?
    var alignV: IsoFlat_Align?
    var shadow: IsoFlat_ShadowSpec?
    var padding: [Double]?
    var width: Double?
    var height: Double?
    var expandW: Bool = false
    var expandH: Bool = false
    var radius: Double?
    var opacity: Double?
    var bg: IsoFlat_ColorRGBA?
    var gradient: String?
    var tap: String?
    var feedback: Int32?
    var style: IsoFlat_PresentationStyle?
    var title: String?
    var message: String?
    var dismiss: String?
    var offsetX: Double?
    var offsetY: Double?
    var scale: Double?
    var drag: String?
    /// The node's identity among its siblings, on the wire (nil for the
    /// runtime's own unkeyed nodes, which hosts key by position).
    var key: String?
    /// What the diff matches this node on among its siblings: the key, or
    /// its position.
    private(set) var matchKey: String = ""
    /// Nonzero on a cached subtree's root: the same token next frame means
    /// the very same subtree (its key aside), which the diff skips.
    var subtreeToken = 0

    var children: [FlatNode] = []

    mutating func setKey(_ key: String?, fallback: String) {
        self.key = key
        matchKey = key ?? fallback
    }

    init(kind: IsoFlat_Kind) { self.kind = kind }

    /// Whether this node's own attributes (children, key and token aside)
    /// are another's: what the diff sends an attributes op for when not.
    /// Compared field by field: it was a string of every attribute, built
    /// for every node on every frame, numbers formatted as text.
    func sameOwnAttributes(as o: FlatNode) -> Bool {
        kind == o.kind && v == o.v && num == o.num && id == o.id && fontSize == o.fontSize
            && weight == o.weight && Self.same(color, o.color) && lines == o.lines && shape == o.shape
            && Self.same(fill, o.fill) && Self.same(stroke, o.stroke) && strokeWidth == o.strokeWidth
            && axis == o.axis && spacing == o.spacing && min == o.min && src == o.src && remote == o.remote
            && resizable == o.resizable && fit == o.fit && placeholder == o.placeholder && edit == o.edit
            && view == o.view && options == o.options && Self.same(params, o.params)
            && growW == o.growW && growH == o.growH && alignH == o.alignH && alignV == o.alignV
            && Self.same(shadow, o.shadow) && padding == o.padding && width == o.width && height == o.height
            && expandW == o.expandW && expandH == o.expandH && radius == o.radius && opacity == o.opacity
            && Self.same(bg, o.bg) && gradient == o.gradient && tap == o.tap && feedback == o.feedback
            && style == o.style && title == o.title && message == o.message && dismiss == o.dismiss
            && offsetX == o.offsetX && offsetY == o.offsetY && scale == o.scale && drag == o.drag
    }

    private static func same(_ a: IsoFlat_ColorRGBA?, _ b: IsoFlat_ColorRGBA?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a
        default: return false
        }
    }

    private static func same(_ a: IsoFlat_ShadowSpec?, _ b: IsoFlat_ShadowSpec?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            return same(a.color, b.color) && a.radius == b.radius && a.x == b.x && a.y == b.y
        default: return false
        }
    }

    private static func same(_ a: [(String, String)]?, _ b: [(String, String)]?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }
}

/// "#rrggbbaa" for a color (no Foundation formatting here).
/// A scroll edge style's wire name; nil for automatic (the host's own).
func scrollEdgeStyleName(_ style: ScrollEdgeEffectStyle?) -> String? {
    switch style?.kind {
    case .hard?: return "hard"
    case .soft?: return "soft"
    case .automatic?, nil: return nil
    }
}

func wireHexColor(_ value: Color) -> String {
    let digits = Array("0123456789abcdef")
    func pair(_ component: Double) -> String {
        let byte = Int((min(1, max(0, component)) * 255).rounded())
        return String(digits[byte >> 4]) + String(digits[byte & 0xF])
    }
    return "#" + pair(value.red) + pair(value.green) + pair(value.blue) + pair(value.alpha)
}

/// Row actions as a param: per item its index (the event's value), title,
/// symbol, "d" when destructive and its tint ("#rrggbbaa", or empty), the
/// fields record-separated and the items unit-separated.
func encodeRowActions(_ items: [RowActionItem], indices: [Int]? = nil) -> String {
    zip(indices ?? Array(items.indices), items).map { index, item in
        [String(index), item.title, item.symbol ?? "", item.destructive ? "d" : "", item.tint.map(wireHexColor) ?? ""].joined(separator: "\u{1E}")
    }.joined(separator: "\u{1F}")
}

/// Base64 (standard alphabet, padded), without Foundation.
func base64Encoded(_ bytes: [UInt8]) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    var out: [UInt8] = []
    out.reserveCapacity((bytes.count + 2) / 3 * 4)
    var index = 0
    while index + 2 < bytes.count {
        let n = UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2])
        out += [alphabet[Int(n >> 18 & 63)], alphabet[Int(n >> 12 & 63)], alphabet[Int(n >> 6 & 63)], alphabet[Int(n & 63)]]
        index += 3
    }
    let rest = bytes.count - index
    if rest == 1 {
        let n = UInt32(bytes[index]) << 16
        out += [alphabet[Int(n >> 18 & 63)], alphabet[Int(n >> 12 & 63)], UInt8(ascii: "="), UInt8(ascii: "=")]
    } else if rest == 2 {
        let n = UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8
        out += [alphabet[Int(n >> 18 & 63)], alphabet[Int(n >> 12 & 63)], alphabet[Int(n >> 6 & 63)], UInt8(ascii: "=")]
    }
    return String(decoding: out, as: UTF8.self)
}

/// A system colour's name for hosts with the system's colours ("green",
/// "green@0.5" with an opacity on it), or nil for any other colour.
func systemColorName(_ color: Color) -> String? {
    guard let name = color.systemName else { return nil }
    guard color.systemOpacity != 1 else { return name }
    // Two decimals ("0.50"), without Foundation's formatting.
    let hundredths: Int = Int((color.systemOpacity * 100).rounded())
    let whole: String = String(hundredths / 100)
    let fraction: String = String(String(100 + hundredths % 100).dropFirst())
    return name + "@" + whole + "." + fraction
}
