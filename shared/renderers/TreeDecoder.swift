// Decodes a `tree.fbs` FlatBuffer (produced by `FlatTreeEncoder`) back into a
// `RenderNode` tree so a self-drawing renderer (`SwiftGPURenderer`) can draw a
// wasm-delivered UI. The exact inverse of `FlatTreeEncoder`: it reads the same
// `IsoFlat_Node` accessors Apple's `IsomerTreeView` reads, but rebuilds
// `RenderNode`s instead of SwiftUI views. Interactive nodes get synthesized
// closures (`tapAction`/`textSet`/`sliderSet`/host `onChange`) that call the
// `send(id, value)` closure — the same id the encoder registered in its
// `handlers` table and that the host echoes back (to the reactor's
// `iso_hot_event` in the desktop wasm host, or to `encoder.handlers[id]` in a round-trip test).
//
// The visual transforms (`.offset`, `.scaleEffect`), `.position`, clipping
// and a drag's handler round-trip; rotation, overlays and minimum sizes do
// not yet (docs/desktop_wasm_implementation_notes.md, blocker 2).

import FlatBuffers
internal import IsomerSwiftUI

package final class FlatTreeDecoder {
    /// Routes an interactive node's event to the source of truth, keyed by the
    /// stable id the encoder assigned (`"<path>.tap"`, `".text"`, `".slider"`,
    /// `".host"`, `"presentation.<id>"`). "tap" events send an empty value.
    private let send: (String, String) -> Void

    public init(send: @escaping (String, String) -> Void) {
        self.send = send
    }

    /// Decodes a finished `tree.fbs` buffer into a fresh `RenderNode` tree.
    public func decode(bytes: [UInt8]) -> RenderNode {
        var buffer = ByteBuffer(bytes: bytes)
        let root = getRoot(byteBuffer: &buffer) as IsoFlat_Node
        return node(root)
    }

    /// Applies a `Patch` buffer — the only wire format the reactor ships — to
    /// the retained tree and returns the new root.
    /// The desktop peer of the Android host's `FlatTree.applyPatch`: each op
    /// targets a node by positional path ("n", "n.0.1", …); `attrs_only`
    /// replaces just that node's attributes (children kept), otherwise the
    /// decoded subtree replaces it wholesale. The first patch after enabling
    /// diffs (and after every hot-reload swap, when `retained` is nil again) is
    /// a single full-tree op at "n". RenderNode is a reference type, so ops
    /// splice in place; unchanged subtrees keep their nodes (and closures).
    public func applyPatch(bytes: [UInt8], to retained: RenderNode?) -> RenderNode {
        var buffer = ByteBuffer(bytes: bytes)
        let patch = getRoot(byteBuffer: &buffer) as IsoFlat_Patch
        var root = retained
        for index in 0..<patch.ops.count {
            let op = patch.ops[index]
            guard let path = op.path else { continue }
            let segments = path.split(separator: ".").dropFirst().compactMap { Int($0) }
            if op.order.count > 0 {
                // Reorder: the retained children by old index, -1 = the next insert.
                var target = root
                for segment in segments {
                    guard let cursor = target, segment < cursor.children.count else { target = nil; break }
                    target = cursor.children[segment]
                }
                guard let target else { continue }
                let old = target.children
                var inserted = 0
                target.children = op.order.map { index -> RenderNode in
                    if index >= 0, Int(index) < old.count { return old[Int(index)] }
                    defer { inserted += 1 }
                    return node(op.inserts[inserted])
                }
                continue
            }
            guard let flat = op.node else { continue }
            let decoded = node(flat)
            if segments.isEmpty {
                // Root op: replace the whole tree (attrs-only keeps old children).
                if op.attrsOnly { decoded.children = root?.children ?? [] }
                root = decoded
                continue
            }
            // Walk to the op's parent; a path outside the retained shape means a
            // desynced stream — drop the op rather than splice at a wrong spot.
            var parent = root
            for segment in segments.dropLast() {
                guard let cursor = parent, segment < cursor.children.count else { parent = nil; break }
                parent = cursor.children[segment]
            }
            guard let parent, let leaf = segments.last, leaf < parent.children.count else { continue }
            if op.attrsOnly { decoded.children = parent.children[leaf].children }
            parent.children[leaf] = decoded
        }
        // Non-nil after the first (root) op; the empty box guards a degenerate
        // empty-ops patch against a still-empty retained tree.
        return root ?? RenderNode(kind: .box)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func node(_ n: IsoFlat_Node) -> RenderNode {
        let out = RenderNode(kind: kind(n))

        // Children (encoded for any kind that has them).
        if !n.ch.isEmpty {
            out.children = (0..<n.ch.count).map { node(n.ch[$0]) }
        }

        // Text / control attributes.
        switch n.kind {
        case .text:
            out.font = Font(
                size: n.size.map { CGFloat($0) } ?? Font.body.size,
                weight: Font.Weight(value: Int(n.weight ?? 400)))
            if let color = n.color { out.color = self.color(color) }
            out.lineLimit = n.lines.map { Int($0) }
        case .textfield:
            out.font = Font(size: n.size.map { CGFloat($0) } ?? Font.body.size)
            out.identityPath = n.id
            for kv in n.params where kv.key == "secure" { out.secureEntry = kv.value == "1" }
            let initial = n.v ?? ""
            out.textGet = { initial }
            if let edit = n.edit {
                let route = self.send
                out.textSet = { value in route(edit, value) }
            }
        case .box:
            // `ViewThatFits`, for the core's layout to choose (Layout.swift).
            for kv in n.params where kv.key == "fits" {
                var axes: Axis.Set = []
                if kv.value.contains("h") { axes.insert(.horizontal) }
                if kv.value.contains("v") { axes.insert(.vertical) }
                out.fitsAxes = axes
            }
        case .slider:
            out.sliderFraction = n.num ?? 0
            if let edit = n.edit {
                let route = self.send
                out.sliderSet = { value in route(edit, String(value)) }
            }
        default:
            break
        }

        // Stack vs. leaf alignment + spacing.
        if case .stack = n.kind {
            out.stackAlignment = alignment(n)
            out.stackSpacing = n.spacing.map { CGFloat($0) }
        } else {
            out.alignment = alignment(n)
        }

        // Frame / greediness (encoder folds maxWidth==.infinity into expandW,
        // and propagated child greediness into growW; IsomerTreeView unions
        // both into a stretched frame, so we do too).
        out.fixedWidth = n.width.map { CGFloat($0) }
        out.fixedHeight = n.height.map { CGFloat($0) }
        out.expandsWidth = n.expandW || n.growW
        out.expandsHeight = n.expandH || n.growH

        if let inset = padding(n) { out.padding = inset }
        out.opacity = n.opacity ?? 1

        // `radius` is shared: the shape/gradient kinds consumed it as the shape
        // corner (in `kind(_:)`); for every other kind it's the node's own
        // cornerRadius (or, for a plain box, the corner of its bg fill).
        if case .shape = n.kind {} else if case .gradient = n.kind {} else {
            out.cornerRadius = CGFloat(n.radius ?? 0)
        }

        // Collapsed background fill (solid color or gradient) → a background node.
        if let bg = n.bg {
            out.background = [fillNode(shape: bgShape(n), fill: color(bg))]
        } else if case .gradient = n.kind {
            // handled by kind()
        } else if let gradient = n.gradient, let paint = parseGradient(gradient) {
            out.background = [RenderNode(kind: .gradient(bgShape(n), paint))]
        }

        if let shadow = n.shadow {
            out.shadow = ShadowSpec(
                color: color(shadow.color),
                radius: CGFloat(shadow.radius),
                x: CGFloat(shadow.x),
                y: CGFloat(shadow.y))
        }

        if let tap = n.tap {
            let route = self.send
            out.tapAction = { route(tap, "") }
            out.pressFeedback = PressFeedback(rawValue: Int(n.feedback ?? 0)) ?? .none
        }

        // Visual transforms, as the guest's animator left them this frame
        // (a 2048 board's cells are each `.offset` into place).
        out.offsetX = CGFloat(n.offsetX ?? 0)
        out.offsetY = CGFloat(n.offsetY ?? 0)
        out.scaleEffect = CGFloat(n.scale ?? 1)
        for kv in n.params {
            switch kv.key {
            case "posX": out.positionX = Double(kv.value).map { CGFloat($0) }
            case "posY": out.positionY = Double(kv.value).map { CGFloat($0) }
            case "clip": out.clipsContent = kv.value == "1"
            default: break
            }
        }
        // A drag on the node: its movement goes back to the guest's
        // onChanged/onEnded by the node's drag id, as Apple's tree view sends it.
        if let drag = n.drag {
            let route = self.send
            var gesture = DragGesture(minimumDistance: 6)
            gesture.onChangedAction = { value in route(drag, "changed:\(value.translation.width),\(value.translation.height)") }
            gesture.onEndedAction = { value in route(drag, "ended:\(value.translation.width),\(value.translation.height)") }
            out.dragGesture = gesture
        }

        return out
    }

    // MARK: - Kind

    // swiftlint:disable:next cyclomatic_complexity
    private func kind(_ n: IsoFlat_Node) -> RenderNode.Kind {
        switch n.kind {
        case .box:
            return .box
        case .text:
            return .text(n.v ?? "")
        case .shape:
            return .shape(shapeKind(n), fill: n.fill.map(color), stroke: stroke(n))
        case .stack:
            return .stack(axis(n.axis))
        case .spacer:
            return .spacer(n.min.map { CGFloat($0) })
        case .divider:
            return .divider
        case .scroll:
            return .scroll(axis(n.axis))
        case .image:
            return .image(
                source: n.src ?? "",
                isRemote: n.remote ?? false,
                resizable: n.resizable ?? false,
                fit: n.fit ?? false)
        case .textfield:
            return .textField(placeholder: n.placeholder ?? "")
        case .slider:
            return .slider
        case .gradient:
            let paint = n.gradient.flatMap(parseGradient)
                ?? GradientPaint(kind: .solid, stops: [Gradient.Stop(color: .clear, location: 0)])
            return .gradient(shapeKind(n), paint)
        case .hostview:
            return .hostView(hostSpec(n))
        case .progress:
            return .progress(n.num)
        case .presentation:
            // v1: desktop-wasm has no native modal chrome; render the content
            // inline as a depth stack (dismiss/style are dropped).
            return .stack(.depth)
        }
    }

    private func hostSpec(_ n: IsoFlat_Node) -> HostViewSpec {
        var params: [String: String] = [:]
        for kv in n.params { params[kv.key] = kv.value }
        var onChange: ((String) -> Void)?
        if let edit = n.edit {
            let route = self.send
            onChange = { value in route(edit, value) }
        }
        return HostViewSpec(
            id: n.edit ?? n.id ?? "",
            kind: n.view ?? "",
            params: params,
            value: n.v ?? "",
            options: n.options.compactMap { $0 },
            onChange: onChange)
    }

    // MARK: - Scalar mappings

    private func color(_ c: IsoFlat_ColorRGBA) -> Color {
        Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b), opacity: Double(c.a))
    }

    private func stroke(_ n: IsoFlat_Node) -> (Color, CGFloat)? {
        guard let s = n.stroke else { return nil }
        return (color(s), CGFloat(n.strokeWidth ?? 1))
    }

    private func axis(_ axis: IsoFlat_Axis?) -> StackAxis {
        switch axis {
        case .horizontal: return .horizontal
        case .depth: return .depth
        default: return .vertical
        }
    }

    /// The shape kind for a `.shape`/`.gradient` node: `radius` carried the
    /// shape's own corner radius (encoder `flatShape`).
    private func shapeKind(_ n: IsoFlat_Node) -> ShapeKind {
        // An app's own shape travels as its path (encoder: the `path` param).
        for kv in n.params where kv.key == "path" {
            if let text = kv.value, let path = Path(serialized: text) { return .path(path) }
        }
        switch n.shape {
        case .circle: return .circle
        case .capsule: return .capsule
        default:
            let radius = n.radius ?? 0
            return radius > 0 ? .roundedRectangle(CGFloat(radius)) : .rectangle
        }
    }

    /// The shape a collapsed background fill takes: encoder stored 9999 for
    /// circle/capsule backgrounds and the literal radius otherwise.
    private func bgShape(_ n: IsoFlat_Node) -> ShapeKind {
        let radius = n.radius ?? 0
        if radius >= 9999 { return .capsule }
        return radius > 0 ? .roundedRectangle(CGFloat(radius)) : .rectangle
    }

    private func fillNode(shape: ShapeKind, fill: Color) -> RenderNode {
        RenderNode(kind: .shape(shape, fill: fill, stroke: nil))
    }

    private func alignment(_ n: IsoFlat_Node) -> Alignment {
        let horizontal: HorizontalAlignment
        switch n.alignH {
        case .start: horizontal = .leading
        case .end: horizontal = .trailing
        default: horizontal = .center
        }
        let vertical: VerticalAlignment
        switch n.alignV {
        case .start: vertical = .top
        case .end: vertical = .bottom
        default: vertical = .center
        }
        return Alignment(horizontal: horizontal, vertical: vertical)
    }

    private func padding(_ n: IsoFlat_Node) -> EdgeInsets? {
        guard n.padding.count == 4 else { return nil }
        return EdgeInsets(
            top: CGFloat(n.padding[0]),
            leading: CGFloat(n.padding[1]),
            bottom: CGFloat(n.padding[2]),
            trailing: CGFloat(n.padding[3]))
    }

    // MARK: - Gradient JSON → GradientPaint (inverse of GradientPaint.json())

    private func parseGradient(_ json: String) -> GradientPaint? {
        guard let root = parseJSON(json), case .object = root else { return nil }
        let stops: [Gradient.Stop] = (root["stops"].array ?? []).compactMap { entry in
            guard let c = entry["c"].array?.compactMap({ $0.double }), c.count == 4 else { return nil }
            return Gradient.Stop(
                color: Color(red: c[0], green: c[1], blue: c[2], opacity: c[3]),
                location: CGFloat(entry["l"].double ?? 0))
        }
        guard !stops.isEmpty else { return nil }

        func point(_ key: String, _ fallback: UnitPoint) -> UnitPoint {
            guard let p = root[key].array?.compactMap({ $0.double }), p.count == 2 else { return fallback }
            return UnitPoint(x: p[0], y: p[1])
        }

        let kind: GradientPaint.Kind
        switch root["kind"].string {
        case "linear":
            kind = .linear(start: point("p0", .top), end: point("p1", .bottom))
        case "radial":
            kind = .radial(
                center: point("c", .center),
                startRadius: CGFloat(root["sr"].double ?? 0),
                endRadius: CGFloat(root["er"].double ?? 0))
        case "angular":
            kind = .angular(
                center: point("c", .center),
                startAngle: Angle(radians: root["a0"].double ?? 0),
                endAngle: Angle(radians: root["a1"].double ?? 0))
        default:
            kind = .solid
        }
        return GradientPaint(kind: kind, stops: stops)
    }
}
