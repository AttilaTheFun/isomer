// The native SwiftUIRenderer's Apple half: interprets the render-tree
// FlatBuffer (shared/renderers/tree.fbs) as REAL SwiftUI views. The tree
// producer runs elsewhere — a wasm module under WasmKit in the hot-reload
// example host, where the runtime binds `SwiftUIRenderer { bytes in … }` —
// and events go back by node id through `send` (the counterpart of
// `Runtime.hostViewEvent(id:value:)`).
//
// v1 kind coverage (grow with the demo): box/stack/scroll/spacer/divider/
// text/shape/gradient/image/progress/textField/slider/toggle/picker/menu/
// datepicker/navbar/tabbar host views, presentations as overlay layers.
// Native `.sheet`/NavigationStack mapping is future work — presentations
// and bars render as styled layers driven purely by the tree.

import FlatBuffers
import os
import SwiftUI
public import IsomerSwiftUI

/// Renders the retained patch tree (`FlatPatchTree.apply` output). Cheap:
/// node views read own attributes zero-copy from the flatbuffer, and an
/// unchanged subtree keeps its `PatchedNode` reference across frames.
public struct IsomerTreeView: View {
    private let root: PatchedNode
    private let send: (String, String) -> Void

    public init(root: PatchedNode, send: @escaping (String, String) -> Void) {
        self.root = root
        self.send = send
    }

    public var body: some View {
        IsomerTreeBenchHook.bodyTick?()
        // Presentations arrive as extra depth-stack layers over the root;
        // peel them off and present them NATIVELY (real .sheet / .alert)
        // instead of drawing overlay panels.
        let (base, presentations) = Self.splitPresentations(root)
        // Popovers hang from their views (param "popover"), as SwiftUI's
        // do: the views find their layers here.
        var popovers: [String: PatchedNode] = [:]
        for layer in presentations where layer.flat.style == .popover {
            if let id = layer.flat.params.first(where: { $0.key == "popoverId" })?.value { popovers[id] = layer }
        }
        return NodeView(pnode: base, send: send)
            .environment(\.isoPopovers, popovers)
            .modifier(NativePresentations(presentations: presentations, send: send))
    }

    /// When the root is the presentation wrapper (a depth stack whose extra
    /// layers are `presentation` nodes), returns (base content, layers).
    static func splitPresentations(_ root: PatchedNode) -> (PatchedNode, [PatchedNode]) {
        guard root.flat.kind == .stack, root.flat.axis == .depth,
              root.children.count > 1,
              root.children.dropFirst().allSatisfy({ $0.flat.kind == .presentation }),
              let base = root.children.first
        else { return (root, []) }
        return (base, Array(root.children.dropFirst()))
    }
}

// MARK: - Node dispatch

/// A child node with its identity among its siblings: the key the guest
/// gives it (its place in the app's structure, `IsoFlat_Node.key`), else its
/// position. SwiftUI keeps a view across frames by that identity, so a view
/// stays the same view (a field its focus, a scroll view its offset) when a
/// sibling comes in before it, as in the app's own SwiftUI; by position, a
/// row of suggestions put in above a composer's field made the field a new
/// one, and the keyboard went away.
struct KeyedNode: Identifiable {
    let id: SiblingID
    let node: PatchedNode
}

func keyedNodes(_ nodes: [PatchedNode]) -> [KeyedNode] {
    zip(siblingIDs(nodes.map(\.flat.key)), nodes).map { KeyedNode(id: $0, node: $1) }
}

/// A child's identity among its siblings. The two cases never equal each
/// other, so no key can pass for a position (a key spelled "#1" is still a
/// key), and the occurrence keeps a key the guest repeats distinct.
package enum SiblingID: Hashable {
    /// The guest's key, and which of the siblings with that key this is (0
    /// for the first): keys are unique among siblings, but a repeated one
    /// must not make two views one.
    case key(String, occurrence: Int)
    /// No key: the child's position among its siblings.
    case position(Int)
}

/// The identities of siblings with these keys (nil: no key), all distinct.
package func siblingIDs(_ keys: [String?]) -> [SiblingID] {
    var occurrences: [String: Int] = [:]
    return keys.enumerated().map { index, key in
        guard let key else { return .position(index) }
        let occurrence = occurrences[key, default: 0]
        occurrences[key] = occurrence + 1
        return .key(key, occurrence: occurrence)
    }
}

/// A node of the tree. Equal while its `PatchedNode` is the same object:
/// patches are copy-on-write (FlatPatchTree), so an unchanged subtree keeps
/// its node objects from frame to frame and SwiftUI, comparing a view with
/// its last by `==` where it is Equatable, skips its body; only the nodes
/// on a patch's path are drawn again. (`send` is the model's, the same for
/// a tree's life.)
struct NodeView: View, Equatable {
    let pnode: PatchedNode
    let send: (String, String) -> Void
    /// A text field's focus (`.focused` in the guest ↔ the real keyboard).
    @FocusState private var fieldFocused: Bool
    /// Inside a scroll: a geometry reader here reports its size alone.
    @Environment(\.isomerInScroll) private var inScroll

    static func == (lhs: NodeView, rhs: NodeView) -> Bool { lhs.pnode === rhs.pnode }

    /// Own attributes, zero-copy from the patch buffer.
    var node: IsoFlat_Node { pnode.flat }

    var body: some View {
        content
            .modifier(Decorations(node: node, send: send))
    }

    @ViewBuilder private var content: some View {
        switch node.kind {
        case .box:
            boxBody
        case .text:
            textBody
        case .shape:
            AnyShapeView(node: node)
        case .gradient:
            AnyShapeView(node: node)
        case .stack:
            stackBody
        case .spacer:
            Spacer(minLength: node.min.map { CGFloat($0) } ?? 0)
        case .divider:
            Divider()
        case .scroll:
            if nodeParam("list") == "1", node.axis != .horizontal {
                // A `List` renders as the REAL thing: native separators,
                // insets, and (in a split sidebar) sidebar styling.
                ListBody(pnode: pnode, send: send)
                    .environment(\.isomerInScroll, true)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(node.axis == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
                        children(inheritAxis: node.axis == .horizontal ? .horizontal : .vertical)
                            .environment(\.isomerInScroll, true)
                    }
                    .modifier(KeyboardDismissModifier(mode: nodeParam("dismissKeyboard")))
                    .modifier(ScrollBounceModifier(spec: nodeParam("bounce")))
                    .modifier(ScrollEdgeModifier(top: nodeParam("edgeTop"), bottom: nodeParam("edgeBottom")))
                    .modifier(ScrollAnchorModifier(anchor: nodeParam("anchor"), role: nodeParam("anchorFor"), align: nodeParam("anchorAlign")))
                    .modifier(ScrollGeometryReporter(id: nodeParam("geometry"), send: send))
                    // `ScrollViewProxy.scrollTo` from the guest: "<id>|<tick>|<anchor>".
                    // Every ScrollView sees it; only the one containing the id moves.
                    .onChange(of: nodeParam("scrollTo")) { request in hostScrollTo(request, proxy: proxy) }
                    .onAppear { hostScrollTo(nodeParam("scrollTo"), proxy: proxy) }
                }
            }
        case .image:
            imageBody
        case .textfield:
            textFieldBody
        case .slider:
            sliderBody
        case .progress:
            if let value = node.num {
                ProgressView(value: value)
            } else {
                ProgressView()
            }
        case .hostview:
            switch node.view {
            case "navstack":
                NavStackBody(pnode: pnode, send: send)
            case "navsplit":
                NavSplitBody(pnode: pnode, send: send)
            case "tabs":
                TabsBody(pnode: pnode, send: send)
            case "menu" where !pnode.children.isEmpty:
                // A label of the app's own (a symbol in a circle, an
                // avatar): drawn as the app made it, not as the word "Menu"
                // (which a composer's 44 pt attach button cut to "M…").
                Menu {
                    MenuItems(node: node, send: send)
                } label: {
                    NodeView(pnode: pnode.children[0], send: send)
                }
            default:
                HostViewBody(node: node, send: send)
            }
        case .presentation:
            PresentationBody(pnode: pnode, send: send)
        }
    }

    /// A child's decoration layer ("background" / "overlay"), if it is one.
    private func layer(of child: PatchedNode) -> String? {
        for kv in child.flat.params where kv.key == "layer" { return kv.value }
        return nil
    }

    /// `.overlay(alignment:)` / `.background(alignment:)` from the layer's
    /// "layerAlign" param ("<start|center|end>,<start|center|end>").
    private func layerAlignment(_ child: PatchedNode?) -> Alignment {
        guard let child else { return .center }
        var value = "center,center"
        for kv in child.flat.params where kv.key == "layerAlign" { value = kv.value }
        let parts = value.split(separator: ",").map(String.init)
        let horizontal: HorizontalAlignment = parts.first == "start" ? .leading : parts.first == "end" ? .trailing : .center
        let vertical: VerticalAlignment = parts.last == "start" ? .top : parts.last == "end" ? .bottom : .center
        return Alignment(horizontal: horizontal, vertical: vertical)
    }

    @ViewBuilder private var boxBody: some View {
        if let item = nodeParam("share") {
            // A ShareLink: the system's share sheet, from its label (before
            // iOS 16, the guest's tap, which asks the host to share).
            if #available(iOS 16.0, macOS 13.0, *) {
                if let preview = nodeParam("sharePreview") {
                    ShareLink(item: item, subject: nodeParam("shareSubject").map { Text($0) },
                              message: nodeParam("shareMessage").map { Text($0) }, preview: SharePreview(preview)) {
                        ForEach(0..<pnode.children.count, id: \.self) { index in
                            NodeView(pnode: pnode.children[index], send: send)
                        }
                    }
                    .modifier(HostButtonStyle(name: nodeParam("shareStyle")))
                } else {
                    ShareLink(item: item, subject: nodeParam("shareSubject").map { Text($0) },
                              message: nodeParam("shareMessage").map { Text($0) }) {
                        ForEach(0..<pnode.children.count, id: \.self) { index in
                            NodeView(pnode: pnode.children[index], send: send)
                        }
                    }
                    .modifier(HostButtonStyle(name: nodeParam("shareStyle")))
                }
            } else {
                Button {
                    if let tap = node.tap { send(tap, "") }
                } label: {
                    ForEach(0..<pnode.children.count, id: \.self) { index in
                        NodeView(pnode: pnode.children[index], send: send)
                    }
                }
                .modifier(HostButtonStyle(name: nodeParam("shareStyle")))
            }
        } else if nodeParam("button") != nil {
            NativeButtonBody(pnode: pnode, send: send)
        } else if pnode.children.isEmpty {
            Color.clear.frame(width: 0, height: 0)
        } else if pnode.children.contains(where: { layer(of: $0) != nil }) {
            // `.background(view)` / `.overlay(view)` layers around the content,
            // sized to this box the way SwiftUI's own modifiers size them.
            let content = pnode.children.filter { layer(of: $0) == nil }
            // `.glassEffect` on this view: the glass is the view's own (its
            // content takes the glass's look, as SwiftUI's does), not a
            // layer drawn behind it.
            let glassLayer = pnode.children.first { layer(of: $0) == "background" && Self.glass(of: $0) != nil }
            let backgrounds = pnode.children.filter { layer(of: $0) == "background" && $0 !== glassLayer }
            let overlays = pnode.children.filter { layer(of: $0) == "overlay" }
            ZStack(alignment: alignment) {
                ForEach(keyedNodes(content)) { child in NodeView(pnode: child.node, send: send) }
            }
            .background(alignment: layerAlignment(backgrounds.first)) {
                ZStack { ForEach(keyedNodes(backgrounds)) { child in NodeView(pnode: child.node, send: send) } }
            }
            .modifier(GlassEffectModifier(fill: glassLayer.flatMap(Self.glass), shape: glassLayer.map {
                NodeShape(kind: $0.flat.shape, radius: CGFloat($0.flat.radius ?? 0))
            }))
            .overlay(alignment: layerAlignment(overlays.first)) {
                ZStack { ForEach(keyedNodes(overlays)) { child in NodeView(pnode: child.node, send: send) } }
            }
        } else if let axes = nodeParam("fits") {
            // `ViewThatFits`: SwiftUI's own over the candidates. Before iOS
            // 16 the last of them, the one meant for when nothing fits.
            if #available(iOS 16, macOS 13, *) {
                ViewThatFits(in: (axes.contains("h") ? Axis.Set.horizontal : []).union(axes.contains("v") ? .vertical : [])) {
                    ForEach(keyedNodes(pnode.children)) { child in NodeView(pnode: child.node, send: send) }
                }
            } else if let last = pnode.children.last {
                NodeView(pnode: last, send: send)
            }
        } else if let geo = nodeParam("geo") {
            // A GeometryReader wrapper: report the size SwiftUI offers it
            // ("<w>x<h>" on the `.geo` id) so the guest rebuilds the reader's
            // content against its CONTAINER, not the canvas. The wrapper IS a
            // SwiftUI GeometryReader — greedy, sized by its parent — and the
            // content is pinned to that size. Measuring a content-fitting
            // ZStack instead echoed the content's own size back: the first
            // frame is built for the reactor's default canvas (900x680 until
            // the host's resize lands), so the report said 900 wide, the
            // guest rebuilt at 900, and the layout stayed off-screen on a
            // phone. A same-size re-report rebuilds an identical tree (empty
            // patch) and settles.
            GeometryReader { proxy in
                ZStack(alignment: alignment) { childViews }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: alignment)
                    .onAppear { reportGeometry(geo, proxy) }
                    .onChange(of: proxy.size) { _ in reportGeometry(geo, proxy) }
                    // Its place in the window too (`frame(in: .global)`),
                    // outside a scroll only: inside one it moves with every
                    // frame of a scroll, and the reader would be built again
                    // for each.
                    .onChange(of: inScroll ? .zero : proxy.frame(in: .global).origin) { _ in reportGeometry(geo, proxy) }
            }
        } else {
            ZStack(alignment: alignment) { childViews }
        }
    }

    /// A background layer that is Liquid Glass (`.glassEffect`), as its fill.
    static func glass(of layer: PatchedNode) -> MaterialFill? {
        guard let json = layer.flat.gradient, let fill = MaterialFill(json: json), fill.glass != nil else { return nil }
        return fill
    }

    private func reportGeometry(_ id: String, _ proxy: GeometryProxy) {
        let w = Int(proxy.size.width.rounded())
        let h = Int(proxy.size.height.rounded())
        guard w > 0, h > 0 else { return }
        if inScroll {
            send(id, "\(w)x\(h)")
        } else {
            let origin = proxy.frame(in: .global).origin
            send(id, "\(w)x\(h)@\(Int(origin.x.rounded())),\(Int(origin.y.rounded()))")
        }
    }

    private var textBody: some View {
        // `Image(systemName:)`: the glyph node names its symbol; draw the
        // real SF Symbol at the glyph's font, falling back to the glyph
        // only when the symbol doesn't exist on this OS.
        // A colour the app did not set ("autoColor") is the container's:
        // a list header's, a button style's, the label's in a list row.
        let ownColor = nodeParam("autoColor") == "1" ? nil : node.color
        if let symbol = nodeParam("symbol"), symbolExists(symbol) {
            let color = ownColor.map { nodeParam("colorName").flatMap(hostSystemColor) ?? swiftColor($0) }
            // An `Image(systemName:)` is an image, as in SwiftUI (a list
            // row's separator starts at its text, not at the symbol); a
            // `Text(Image(…))` on its own is text.
            if nodeParam("symbolImage") == "1" {
                let image = Image(systemName: symbol).font(textFont)
                if let color { return AnyView(image.foregroundColor(color)) }
                return AnyView(image)
            }
            var image = Text(Image(systemName: symbol)).font(textFont)
            if let color { image = image.foregroundColor(color) }
            return AnyView(image)
        }
        // A font the app did not choose ("autoFont") is the container's: a
        // Form's or a list's section header, a button's control size.
        var text = Self.styledText(node.v ?? "", runs: nodeParam("runs"), links: nodeParam("runLinks"))
        if nodeParam("autoFont") != "1" { text = text.font(textFont) }
        if let color = ownColor {
            text = text.foregroundColor(nodeParam("colorName").flatMap(hostSystemColor) ?? swiftColor(color))
        }
        // Only apply an EXPLICIT limit: `.lineLimit(nil)` would override the
        // environment default a native container sets (a List's sidebar rows
        // truncate at one line; unlimited text there wraps mid-word).
        var truncated = AnyView(text)
        if let spacing = nodeParam("lineSpacing").flatMap(Double.init) { truncated = AnyView(truncated.lineSpacing(CGFloat(spacing))) }
        switch nodeParam("truncation") {
        case "head": truncated = AnyView(text.truncationMode(.head))
        case "middle": truncated = AnyView(text.truncationMode(.middle))
        case "tail": truncated = AnyView(text.truncationMode(.tail))
        default: break
        }
        if let lines = node.lines {
            truncated = AnyView(truncated.lineLimit(Int(lines)))
        }
        // `.textCase` in scope in the app: "none" keeps a container from
        // casing it (a list's section header); the guest cased the string
        // itself for the others.
        switch nodeParam("textCase") {
        case "none": return AnyView(truncated.textCase(nil))
        case "upper": return AnyView(truncated.textCase(.uppercase))
        case "lower": return AnyView(truncated.textCase(.lowercase))
        default: return truncated
        }
    }

    /// A concatenated or markdown Text's styled runs ("length:flags[:r,g,b,a]"
    /// joined by ";", lengths in characters; flags b/i/m/u/s and "w<weight>")
    /// as SwiftUI's Text concatenation.
    static func styledText(_ string: String, runs: String?, links: String? = nil) -> Text {
        guard let runs, !runs.isEmpty else { return Text(verbatim: string) }
        var linkURLs = (links ?? "").split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)[...]
        var result = Text(verbatim: "")
        var index = string.startIndex
        for run in runs.split(separator: ";") {
            let parts = run.split(separator: ":", omittingEmptySubsequences: false)
            guard let length = parts.first.flatMap({ Int($0) }) else { continue }
            let end = string.index(index, offsetBy: length, limitedBy: string.endIndex) ?? string.endIndex
            let flags = parts.count > 1 ? String(parts[1]) : ""
            var piece: Text
            // A link: the system's (the tint's colour, unless the run has a
            // colour of its own, as an attributed string's link with a
            // foreground colour has in SwiftUI; a tap opens it).
            // Markdown's emphasis (S, E) is the system's markdown's, through
            // its presentation intents, as SwiftUI draws a literal's.
            let isLink = flags.contains("l")
            let strong = flags.contains("S"), emphasized = flags.contains("E")
            let linkURL = isLink ? linkURLs.popFirst().flatMap({ URL(string: $0) }) : nil
            let rgba = parts.count > 2 ? parts[2].split(separator: ",").compactMap { Double($0) } : []
            // The system colour by name where the run names one (the
            // platform's `.primary`), else its RGBA.
            let named = parts.count > 3 ? hostSystemColor(String(parts[3])) : nil
            let ownColor = named ?? (rgba.count == 4 ? Color(red: rgba[0], green: rgba[1], blue: rgba[2], opacity: rgba[3]) : nil)
            if linkURL != nil || strong || emphasized {
                var attributed = AttributedString(String(string[index..<end]))
                if let linkURL {
                    attributed.link = linkURL
                    if let ownColor { attributed.foregroundColor = ownColor }
                }
                var intent: InlinePresentationIntent = []
                if strong { intent.insert(.stronglyEmphasized) }
                if emphasized { intent.insert(.emphasized) }
                if !intent.isEmpty { attributed.inlinePresentationIntent = intent }
                piece = Text(attributed)
            } else {
                piece = Text(verbatim: String(string[index..<end]))
            }
            if let range = flags.range(of: "w"), let weight = Int32(flags[range.upperBound...].prefix { $0.isNumber }) {
                piece = piece.fontWeight(flatFontWeight(weight))
            } else if flags.contains("b"), !strong {
                piece = piece.bold()
            }
            if flags.contains("i"), !emphasized { piece = piece.italic() }
            if flags.contains("m") {
                if #available(iOS 16.4, macOS 13.3, tvOS 16.4, watchOS 9.4, *) {
                    piece = piece.monospaced()
                } else {
                    piece = piece.font(.system(.body, design: .monospaced))
                }
            }
            if flags.contains("u") { piece = piece.underline() }
            if flags.contains("s") { piece = piece.strikethrough() }
            if let ownColor, !isLink { piece = piece.foregroundColor(ownColor) }
            result = result + piece
            index = end
        }
        if index < string.endIndex { result = result + Text(verbatim: String(string[index...])) }
        return result
    }

    /// The text's font: its text style where it has one (the platform's
    /// leading and Dynamic Type), else its size; with its weight and design.
    private var textFont: Font {
        let weight = flatFontWeight(node.weight ?? 400)
        let design: Font.Design = nodeParam("mono") == "1" ? .monospaced : .default
        if let style = nodeParam("textStyle").flatMap(hostTextStyle) {
            if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
                return .system(style, design: design, weight: weight)
            }
            return .system(style, design: design).weight(weight)
        }
        return .system(size: node.size.map { CGFloat($0) } ?? 15, weight: weight, design: design)
    }

    @ViewBuilder private var stackBody: some View {
        let spacing = node.spacing.map { CGFloat($0) }
        if nodeParam("bottomBar") != nil {
            BottomBarBody(pnode: pnode, send: send)
        } else if let edge = nodeParam("inset"), pnode.children.count == 2 {
            // `.safeAreaInset` / `.safeAreaBar`: the system's, so the
            // content runs beneath the bar to the screen's edge with the
            // bar's height (and the keyboard's, under a composer) as its
            // inset, as the app's own does — not stacked above it.
            let top = edge == "top"
            NodeView(pnode: pnode.children[top ? 1 : 0], send: send)
                .modifier(SafeAreaSlot(
                    edge: top ? .top : .bottom,
                    spacing: nodeParam("insetSpacing").flatMap(Double.init).map { CGFloat($0) },
                    bar: nodeParam("insetBar") == "1",
                    inset: NodeView(pnode: pnode.children[top ? 0 : 1], send: send)))
        } else if nodeParam("grid") != nil, pnode.children.contains(where: { Self.isGridRow($0) }) {
            // A `Grid`: the system's, so its columns line up across rows
            // (each sized by its widest cell); a row that is no GridRow (a
            // Divider) spans the grid. The rows' spacing is the columns'.
            let columnSpacing = pnode.children.first(where: { Self.isGridRow($0) })?.flat.spacing.map { CGFloat($0) }
            Grid(alignment: alignment, horizontalSpacing: columnSpacing ?? 8, verticalSpacing: spacing ?? 8) {
                ForEach(keyedNodes(pnode.children)) { row in
                    if Self.isGridRow(row.node) {
                        GridRow {
                            ForEach(keyedNodes(row.node.children)) { cell in
                                NodeView(pnode: cell.node, send: send)
                            }
                        }
                    } else {
                        NodeView(pnode: row.node, send: send)
                    }
                }
            }
        } else if nodeParam("label") == "1", pnode.children.count == 2 {
            // A Label: the system's, from its icon and title.
            Label {
                NodeView(pnode: pnode.children[1], send: send)
            } icon: {
                NodeView(pnode: pnode.children[0], send: send)
            }
        } else {
            plainStackBody(spacing: spacing)
        }
    }

    private static func isGridRow(_ node: PatchedNode) -> Bool {
        node.flat.params.contains { $0.key == "gridRow" && $0.value == "1" }
    }

    @ViewBuilder private func plainStackBody(spacing: CGFloat?) -> some View {
        switch node.axis {
        case .horizontal:
            HStack(alignment: verticalAlignment, spacing: spacing ?? 8) { childViews }
        case .depth:
            if nodeParam("form") == "form" {
                FormBody(pnode: pnode, send: send)
            } else {
                ZStack(alignment: alignment) { childViews }
            }
        default:
            VStack(alignment: horizontalAlignment, spacing: spacing ?? 8) { childViews }
        }
    }

    @ViewBuilder private var imageBody: some View {
        let source = node.src ?? ""
        let pixelated = nodeParam("interp") == "none"
        if source.hasPrefix("isomer-image://") {
            // A picture the app decoded (ImageIO, Image(data:)): its bytes
            // came with the node that first showed it; kept by source.
            if let image = HostImages.shared.image(for: source, base64: nodeParam("imageData")) {
                #if canImport(UIKit)
                fitted(Image(uiImage: image).resizable().interpolation(pixelated ? .none : .medium))
                #else
                fitted(Image(nsImage: image).resizable().interpolation(pixelated ? .none : .medium))
                #endif
            } else {
                Color(white: 0.5, opacity: 0.08)
            }
        } else if node.remote == true, let url = URL(string: source) {
            RemoteImageView(url: url, fit: node.fit == true, pixelated: pixelated)
        } else {
            fitted(Image(source).resizable().interpolation(pixelated ? .none : .medium))
        }
    }

    @ViewBuilder private func fitted(_ image: some View) -> some View {
        if node.fit == true {
            image.aspectRatio(contentMode: .fit)
        } else {
            image.aspectRatio(contentMode: .fill)
        }
    }

    private var textFieldBody: some View {
        let size = node.size.map { CGFloat($0) } ?? 15
        let design: Font.Design = nodeParam("mono") == "1" ? .monospaced : .default
        // The field's text style where it has one (the platform's metrics,
        // as the app's own field has), else its size.
        let fieldFont: Font = nodeParam("textStyle").flatMap(hostTextStyle).map { .system($0, design: design) }
            ?? .system(size: size, design: design)
        if nodeParam("editor") == "1" {
            // `TextEditor`: a container-filling text view.
            var editor = AnyView(EchoedText(value: node.v ?? "", send: sendEdit) { text in
                TextEditor(text: text).font(fieldFont)
            })
            #if os(iOS)
            if let keyboard = nodeParam("keyboard") { editor = AnyView(editor.keyboardType(hostKeyboardType(keyboard))) }
            if let autocap = nodeParam("autocap") { editor = AnyView(editor.textInputAutocapitalization(hostAutocapitalization(autocap))) }
            #endif
            if nodeParam("autocorrect") == "0" { editor = AnyView(editor.autocorrectionDisabled(true)) }
            return editor
        }
        let placeholder = node.placeholder ?? ""
        // `TextField(_:text:axis: .vertical)` grows with its text between its
        // line bounds (`.lineLimit(1...10)`), as a composer does.
        let vertical = nodeParam("axis") == "v"
        let minLines = nodeParam("minLines").flatMap(Int.init) ?? 1
        let maxLines = nodeParam("maxLines").flatMap(Int.init)
        // `TextField(_:text:selection:)` in the guest: the selection goes back
        // and forth too (SelectionTextField), where SwiftUI has it.
        let selectionID = nodeParam("selId"), selectionRequest = nodeParam("sel"), guestText = node.v ?? ""
        let field = EchoedText(value: guestText, send: sendEdit) { text in
            if #available(iOS 18.0, macOS 15.0, *), let selectionID {
                SelectionTextField(
                    placeholder: placeholder, text: text, vertical: vertical, minLines: minLines, maxLines: maxLines,
                    request: selectionRequest, guestText: guestText, report: { send(selectionID, $0) })
            } else if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *), vertical {
                if let maxLines {
                    TextField(placeholder, text: text, axis: .vertical).lineLimit(minLines...max(minLines, maxLines))
                } else {
                    TextField(placeholder, text: text, axis: .vertical).lineLimit(minLines...)
                }
            } else {
                TextField(placeholder, text: text)
            }
        }
            .font(fieldFont)
            .onSubmit {
                if let submit = nodeParam("submit") { send(submit, "") }
            }
        var styled: AnyView
        // SwiftUI's default (`.automatic`) text field on iOS draws no border —
        // apps compose their own capsule/background around it, as the
        // Snapchat mock does — so only an explicit `.roundedBorder` gets one.
        if nodeParam("fieldStyle") == "roundedBorder" {
            styled = AnyView(field.textFieldStyle(.roundedBorder))
        } else {
            styled = AnyView(field.textFieldStyle(.plain))
        }
        #if os(iOS)
        if let keyboard = nodeParam("keyboard") { styled = AnyView(styled.keyboardType(hostKeyboardType(keyboard))) }
        if let autocap = nodeParam("autocap") { styled = AnyView(styled.textInputAutocapitalization(hostAutocapitalization(autocap))) }
        #endif
        if nodeParam("autocorrect") == "0" { styled = AnyView(styled.autocorrectionDisabled(true)) }
        if let focusID = nodeParam("focusId") {
            // The guest's `.focused` state drives the real focus, and the
            // real focus (keyboard shown/dismissed) is reported back.
            let wanted = nodeParam("focus") == "1"
            styled = AnyView(styled
                .focused($fieldFocused)
                .onAppear { if wanted { DispatchQueue.main.async { fieldFocused = true } } }
                .onChange(of: nodeParam("focus")) { value in
                    let want = value == "1"
                    if want != fieldFocused { fieldFocused = want }
                }
                .onChange(of: fieldFocused) { focused in
                    if focused != (nodeParam("focus") == "1") { send(focusID, focused ? "1" : "0") }
                })
        }
        return styled
    }

    private var sliderBody: some View {
        Slider(value: Binding(
            get: { node.num ?? 0 },
            set: { value in
                if let edit = node.edit { send(edit, String(value)) }
            }))
    }

    /// A field's edit, to the guest.
    private func sendEdit(_ value: String) {
        if let edit = node.edit { send(edit, value) }
    }

    private func nodeParam(_ key: String) -> String? {
        for kv in node.params where kv.key == key { return kv.value }
        return nil
    }

    @ViewBuilder private var childViews: some View {
        children(inheritAxis: nil)
    }

    @ViewBuilder private func children(inheritAxis: Axis?) -> some View {
        ForEach(keyedNodes(pnode.children)) { child in
            NodeView(pnode: child.node, send: send)
        }
    }

    private var alignment: Alignment {
        Alignment(horizontal: horizontalAlignment, vertical: verticalAlignment)
    }

    private var horizontalAlignment: HorizontalAlignment {
        switch node.alignH {
        case .start: return .leading
        case .end: return .trailing
        default: return .center
        }
    }

    private var verticalAlignment: VerticalAlignment {
        switch node.alignV {
        case .start: return .top
        case .end: return .bottom
        default: return .center
        }
    }
}

// MARK: - Shapes & gradients

/// The node's shape as one type (SwiftUI's own `AnyShape` is iOS 16).
struct NodeShape: Shape {
    let kind: IsoFlat_Shape?
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        switch kind {
        case .circle: return Circle().path(in: rect)
        case .capsule: return Capsule().path(in: rect)
        default:
            return radius > 0
                ? RoundedRectangle(cornerRadius: radius).path(in: rect)
                : Rectangle().path(in: rect)
        }
    }
}

struct AnyShapeView: View {
    let node: IsoFlat_Node

    private var fillName: String? {
        for kv in node.params where kv.key == "fillName" { return kv.value }
        return nil
    }

    /// The stroke's colour, the system's by name when the guest gave one
    /// (`strokeName`).
    private func strokeColor(_ stroke: IsoFlat_ColorRGBA) -> Color {
        for kv in node.params where kv.key == "strokeName" { return hostSystemColor(kv.value) ?? swiftColor(stroke) }
        return swiftColor(stroke)
    }

    var body: some View {
        let radius = CGFloat(node.radius ?? 0)
        Group {
            if let gradient = node.gradient, let material = MaterialFill(json: gradient) {
                // A material or Liquid Glass: the system's, over what lies
                // behind.
                material.view(in: shape(radius: radius))
            } else if let gradient = node.gradient, let paint = gradientPaint(gradient) {
                shape(radius: radius).fill(paint)
            } else if let fill = node.fill {
                let filled = shape(radius: radius).fill(fillName.flatMap(hostSystemColor) ?? swiftColor(fill))
                if let stroke = node.stroke {
                    filled.overlay(
                        shape(radius: radius).stroke(
                            strokeColor(stroke), lineWidth: CGFloat(node.strokeWidth ?? 1)))
                } else {
                    filled
                }
            } else if let stroke = node.stroke {
                shape(radius: radius).stroke(
                    strokeColor(stroke), lineWidth: CGFloat(node.strokeWidth ?? 1))
            } else {
                shape(radius: radius).fill(Color.clear)
            }
        }
    }

    private func shape(radius: CGFloat) -> NodeShape {
        NodeShape(kind: node.shape, radius: radius)
    }
}

/// Parses the runtime's gradient paint JSON (shared with
/// HostBridge.fillGradient): {kind, stops: [{c: [r,g,b,a], l}]} with a
/// linear one's p0/p1, a radial one's c/sr/er, an angular one's c/a0/a1.
func gradientPaint(_ json: String) -> AnyShapeStyle? {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let stops = object["stops"] as? [[String: Any]] else { return nil }
    let colors: [Gradient.Stop] = stops.compactMap { stop in
        guard let c = stop["c"] as? [Double], c.count == 4 else { return nil }
        return Gradient.Stop(
            color: Color(red: c[0], green: c[1], blue: c[2], opacity: c[3]),
            location: CGFloat(stop["l"] as? Double ?? 0))
    }
    guard !colors.isEmpty else { return nil }
    func point(_ key: String, _ fallback: UnitPoint) -> UnitPoint {
        guard let p = object[key] as? [Double], p.count == 2 else { return fallback }
        return UnitPoint(x: p[0], y: p[1])
    }
    func number(_ key: String) -> CGFloat { CGFloat(object[key] as? Double ?? 0) }
    let gradient = Gradient(stops: colors)
    switch object["kind"] as? String {
    case "radial":
        return AnyShapeStyle(RadialGradient(
            gradient: gradient, center: point("c", .center),
            startRadius: number("sr"), endRadius: number("er")))
    case "angular":
        return AnyShapeStyle(AngularGradient(
            gradient: gradient, center: point("c", .center),
            startAngle: .radians(Double(number("a0"))), endAngle: .radians(Double(number("a1")))))
    default:
        return AnyShapeStyle(LinearGradient(
            gradient: gradient, startPoint: point("p0", .top), endPoint: point("p1", .bottom)))
    }
}

// MARK: - Host views (semantic chrome)

/// A menu's actions: index 0 of the options is the label, 1... the
/// actions, each with its icon when it has one.
struct MenuItems: View {
    let node: IsoFlat_Node
    let send: (String, String) -> Void

    var body: some View {
        let rows = node.options.compactMap { $0 }
        let symbols = list("symbols")
        let roles = list("roles")
        ForEach(1..<max(rows.count, 1), id: \.self) { index in
            let symbol = index - 1 < symbols.count ? symbols[index - 1] : ""
            let role: ButtonRole? = switch index - 1 < roles.count ? roles[index - 1] : "" {
            case "destructive": .destructive
            case "cancel": .cancel
            default: nil
            }
            if symbol.isEmpty {
                Button(rows[index], role: role) { if let edit = node.edit { send(edit, String(index)) } }
            } else {
                Button(role: role) { if let edit = node.edit { send(edit, String(index)) } } label: {
                    Label(rows[index], systemImage: symbol)
                }
            }
        }
    }

    private func list(_ key: String) -> [String] {
        (node.params.first { $0.key == key }?.value ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

struct HostViewBody: View {
    let node: IsoFlat_Node
    let send: (String, String) -> Void

    private func param(_ key: String) -> String? {
        for kv in node.params where kv.key == key { return kv.value }
        return nil
    }

    private var options: [String] {
        node.options.compactMap { $0 }
    }

    var body: some View {
        switch node.view {
        case "toggle":
            Toggle("", isOn: Binding(
                get: { node.v == "1" },
                set: { on in
                    if let edit = node.edit { send(edit, on ? "1" : "0") }
                }))
                .labelsHidden()
        case "picker":
            // The system's Picker as the app made it: its title shown where
            // SwiftUI shows one (a Form row) unless `.labelsHidden()`, its
            // style.
            Picker(param("title") ?? "", selection: Binding(
                get: { Int(node.v ?? "0") ?? 0 },
                set: { index in
                    if let edit = node.edit { send(edit, String(index)) }
                })) {
                let rows = options
                ForEach(0..<rows.count, id: \.self) { index in
                    Text(rows[index]).tag(index)
                }
            }
            .modifier(HostPickerStyle(name: param("style")))
            .modifier(LabelsHiddenModifier(hidden: param("labelsHidden") == "1"))
        case "menu":
            Menu(param("label") ?? "Menu") {
                MenuItems(node: node, send: send)
            }
        case "datepicker":
            NativeDatePicker(
                title: param("title") ?? "",
                iso: node.v ?? "",
                onChange: { iso in
                    if let edit = node.edit { send(edit, iso) }
                })
                .modifier(LabelsHiddenModifier(hidden: param("labelsHidden") == "1"))
        case "search":
            EchoedText(value: node.v ?? "", send: { value in if let edit = node.edit { send(edit, value) } }) { text in
                TextField(param("prompt") ?? "Search", text: text)
            }
                .textFieldStyle(.roundedBorder)
        case "navbar":
            NavBarBody(node: node, send: send)
        case "tabbar":
            TabBarBody(node: node, send: send)
        default:
            if let kind = node.view, kind.hasPrefix("bridge:"),
               let bridged = BridgedViewRegistry.shared.view(
                    for: String(kind.dropFirst("bridge:".count)),
                    parameters: paramDict,
                    value: node.v ?? "",
                    send: { value in if let edit = node.edit { send(edit, value) } }) {
                // A native view the app registered by id — render it for real.
                bridged
            } else {
                // Representables and unbridged chrome: an inert placeholder in
                // the layout slot, matching the drawn path's fallback.
                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0, opacity: 0.04))
            }
        }
    }

    private var paramDict: [String: String] {
        var out: [String: String] = [:]
        for kv in node.params { out[kv.key] = kv.value }
        return out
    }
}

/// A serialized `List` (a scroll node with the `list` param) mounted as the
/// REAL SwiftUI `List`, as the app's own `List` would be: its sections (a
/// `header` cell opens one; an empty one is the gap between sections
/// without headers), its selection (a selectable row's cell carries the
/// row's tap, the selected one `selected`; the native selection sends the
/// tap, so a phone's split view opens the row as SwiftUI's does), its style,
/// separators, swipe actions and context menus. Rows the guest has not
/// built (`placeholder`) hold their place until they come on screen, when
/// the rows shown are reported on the list's `window` id and the guest
/// builds them.
struct ListBody: View {
    let pnode: PatchedNode
    let send: (String, String) -> Void
    /// The rows on screen, for the build window: a reference, not view
    /// state, so a row coming on screen does not rebuild the list (as it
    /// would, every row of a scroll, through @State).
    @State private var window = RowWindow()

    var node: IsoFlat_Node { pnode.flat }

    var body: some View {
        let cells = listCells
        let sections = Self.sections(of: cells)
        let _ = window.keys = cells.map(Self.identity)
        let selection = Binding<String?>(
            get: { cells.first { Self.param($0, "selected") == "1" }.map(Self.identity) },
            set: { key in
                // A row chosen: the guest's own selection is set by the
                // row's tap. (Deselection comes from the guest: a phone's
                // split going back clears it.)
                guard let key, let cell = cells.first(where: { Self.identity($0) == key }),
                      let tap = cell.flat.tap else { return }
                send(tap, "")
            })
        ScrollViewReader { proxy in
            List(selection: selection) {
                ForEach(sections) { section in
                    let footer = section.footer?.children.first
                    if let header = section.header, let content = header.children.first,
                       !(content.flat.kind == .box && content.children.isEmpty) {
                        Section {
                            rows(section.rows, cells: cells)
                        } header: {
                            NodeView(pnode: content, send: send)
                        } footer: {
                            if let footer { NodeView(pnode: footer, send: send) }
                        }
                    } else {
                        Section {
                            rows(section.rows, cells: cells)
                        } footer: {
                            if let footer { NodeView(pnode: footer, send: send) }
                        }
                    }
                }
            }
            .modifier(ListStyleModifier(style: param("listStyle")))
            .modifier(ScrollEdgeModifier(top: param("edgeTop"), bottom: param("edgeBottom")))
            .modifier(ScrollAnchorModifier(anchor: param("anchor"), role: param("anchorFor"), align: param("anchorAlign")))
            .modifier(ScrollGeometryReporter(id: param("geometry"), send: send))
            .modifier(BottomPin(on: param("anchor") == "bottom" && param("anchorFor") != "initialOffset",
                                window: window, proxy: proxy))
            .modifier(MinRowHeightModifier(height: param("minRowHeight").flatMap(Double.init)))
            .modifier(KeyboardDismissModifier(mode: param("dismissKeyboard")))
            .modifier(ScrollBounceModifier(spec: param("bounce")))
            .onChange(of: param("scrollTo")) { request in listScrollTo(request, proxy: proxy) }
            .onAppear { listScrollTo(param("scrollTo"), proxy: proxy) }
        }
    }

    /// The guest's `scrollTo` ("<id>|<tick>|<anchor>[|a]") in the native
    /// list, to the row it names by its key — among the rows as they are
    /// now (a closure kept from an earlier body holds earlier rows). A
    /// request for a row of another scroll is not this list's.
    private func listScrollTo(_ request: String?, proxy: ScrollViewProxy) {
        guard let request else { return }
        let parts = request.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let target = parts.first, !target.isEmpty, let key = scrollKey(target) else { return }
        hostScrollTo(([key] + parts.dropFirst()).joined(separator: "|"), proxy: proxy)
    }

    @ViewBuilder private func rows(_ indices: [Int], cells: [PatchedNode]) -> some View {
        let hideAll = param("separators") == "0"
        // Each row by its own identity — its ForEach id where it has one
        // (which `scrollTo` names), else its place in the content — not by
        // its index: rows put in above are an insert, and the rows on
        // screen stay on screen.
        ForEach(indices.map { RowRef(index: $0, id: rowKey(cells[$0])) }) { ref in
            let index = ref.index
            let cell = cells[index]
            row(cell)
                .tag(Self.identity(cell))
                .modifier(RowSeparatorModifier(hidden: hideAll || Self.param(cell, "noSeparator") == "1"))
                .modifier(RowChromeModifier(insets: Self.param(cell, "rowInsets"), background: Self.param(cell, "rowBg"),
                                            backgroundView: rowBackground(cell)))
                .onAppear { rowShown(index, true, count: cells.count) }
                .onDisappear { rowShown(index, false, count: cells.count) }
        }
    }

    /// A cell's content, without the cell box: the native row is the cell
    /// (its insets, its height, its highlight), and the box's tap is the
    /// selection's.
    @ViewBuilder private func row(_ cell: PatchedNode) -> some View {
        let key = Self.identity(cell)
        if Self.param(cell, "placeholder") == "1" || cell.children.isEmpty {
            // The row's height when it was last built, else the rows' usual
            // one: rows built above the reader as the build window moves
            // then come in at about the height they held, and what is on
            // screen stays where it is.
            Color.clear.frame(height: window.placeholderHeight(key))
        } else if cell.flat.tap == nil && Self.param(cell, "cell") == nil {
            // Not a semantic cell (a guest drawing its own rows): as is.
            NodeView(pnode: cell, send: send)
                .modifier(RowHeightRecorder(window: window, key: key))
        } else {
            // The content: the cell's child that is not a layer (a row's own
            // background, `.listRowBackground(view)`, rides beside it).
            NodeView(pnode: cell.children.first { Self.param($0, "layer") == nil } ?? cell.children[0], send: send)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(RowHeightRecorder(window: window, key: key))
        }
    }

    /// The view a row draws behind itself (`.listRowBackground(view)`).
    private func rowBackground(_ cell: PatchedNode) -> AnyView? {
        guard Self.param(cell, "rowOwnBg") == "1",
              let layer = cell.children.first(where: { Self.param($0, "layer") == "background" }) else { return nil }
        return AnyView(NodeView(pnode: layer, send: send))
    }

    /// Rows coming on screen and leaving it: report the span shown
    /// ("first,last,rows") once it moves, for the guest to build around it —
    /// once a scroll settles a moment, not for every row it passes.
    private func rowShown(_ index: Int, _ visible: Bool, count: Int) {
        if visible { window.shown.insert(index) } else { window.shown.remove(index) }
        guard let id = param("window") else { return }
        let rows = param("rows") ?? String(count)
        window.schedule { [window, send] in
            guard let first = window.shown.min(), let last = window.shown.max() else { return }
            let report = "\(first),\(last),\(rows)"
            guard report != window.reported else { return }
            window.reported = report
            send(id, report)
        }
    }

    /// The scroll's column's children, minus the guest-drawn separators
    /// (the native List draws its own).
    private var listCells: [PatchedNode] {
        guard let column = pnode.children.first else { return [] }
        return column.children.filter { !Self.isDividerBox($0) }
    }

    struct ListSection: Identifiable {
        let id: String
        let header: PatchedNode?
        var rows: [Int]
        var footer: PatchedNode? = nil
    }

    /// The cells grouped into sections: a header cell starts one (keyed by
    /// the header, so a section keeps its identity as rows come and go); a
    /// footer cell is the section's footer.
    static func sections(of cells: [PatchedNode]) -> [ListSection] {
        var out: [ListSection] = []
        for (index, cell) in cells.enumerated() {
            if param(cell, "cell") == "header" {
                out.append(ListSection(id: cell.flat.key ?? "header\(out.count)", header: cell, rows: []))
            } else if param(cell, "cell") == "footer" {
                if out.isEmpty { out.append(ListSection(id: "first", header: nil, rows: [])) }
                out[out.count - 1].footer = cell
            } else {
                if out.isEmpty { out.append(ListSection(id: "first", header: nil, rows: [])) }
                out[out.count - 1].rows.append(index)
            }
        }
        return out
    }

    /// A cell's identity: its key (the row's place in the app's content).
    static func identity(_ cell: PatchedNode) -> String {
        cell.flat.key ?? ""
    }

    struct RowRef: Identifiable {
        let index: Int
        let id: String
    }

    /// A row's identity in the native list: its key, the same whether the
    /// guest built it or sent its placeholder (an identity that changed as
    /// the build window moved would make it another row). The names
    /// `scrollTo` uses are mapped to keys (`scrollKey`): the ForEach id in a
    /// key, an `.id` the row had when last built.
    private func rowKey(_ cell: PatchedNode) -> String {
        let key = cell.flat.key ?? ""
        if let target = Self.explicitID(cell) { window.targets[target] = key }
        return key
    }

    /// The `.id` on a built row or the wrappers just inside it, as the guest
    /// finds it.
    static func explicitID(_ cell: PatchedNode) -> String? {
        var current: PatchedNode? = cell
        for _ in 0..<5 {
            guard let node = current else { break }
            if let vid = param(node, "vid") { return vid }
            current = node.children.count == 1 ? node.children[0] : nil
        }
        return nil
    }

    /// The row a `scrollTo` names: one whose `.id` it is, else one whose
    /// ForEach id it is; nil when no row of this list is.
    private func scrollKey(_ target: String) -> String? {
        if let key = window.targets[target], window.keys.contains(key) { return key }
        return window.keys.first { Self.forEachID($0) == target }
    }

    /// The ForEach id in a cell's key ("…/fe-<id>/…~cell").
    static func forEachID(_ key: String) -> String? {
        guard let range = key.range(of: "/fe-", options: .backwards) ?? (key.hasPrefix("fe-") ? key.range(of: "fe-") : nil) else { return nil }
        let rest = key[range.upperBound...]
        let end = rest.firstIndex { $0 == "/" || $0 == "~" } ?? rest.endIndex
        let id = String(rest[..<end])
        return id.isEmpty ? nil : id
    }

    static func param(_ node: PatchedNode, _ key: String) -> String? {
        for kv in node.flat.params where kv.key == key { return kv.value }
        return nil
    }

    private func param(_ key: String) -> String? { Self.param(pnode, key) }

    private static func isDividerBox(_ node: PatchedNode) -> Bool {
        if node.flat.kind == .divider { return true }
        if node.flat.kind == .box, node.children.count == 1, param(node, "cell") == nil {
            return isDividerBox(node.children[0])
        }
        return false
    }
}

/// `.listStyle` from the guest (absent: the platform's automatic style).
struct ListStyleModifier: ViewModifier {
    let style: String?

    func body(content: Content) -> some View {
        switch style {
        case "plain": content.listStyle(.plain)
        #if os(iOS)
        case "insetGrouped": content.listStyle(.insetGrouped)
        case "grouped": content.listStyle(.grouped)
        #endif
        case "inset": content.listStyle(.inset)
        case "sidebar": content.listStyle(.sidebar)
        default: content
        }
    }
}

/// `\.defaultMinListRowHeight` on a list.
struct MinRowHeightModifier: ViewModifier {
    let height: Double?

    func body(content: Content) -> some View {
        if let height {
            content.environment(\.defaultMinListRowHeight, CGFloat(height))
        } else {
            content
        }
    }
}

/// `.listRowInsets` ("top,leading,bottom,trailing", "-" for a side left to
/// the list) and `.listRowBackground` (a colour, or the row's own view) on a
/// row.
struct RowChromeModifier: ViewModifier {
    let insets: String?
    let background: String?
    var backgroundView: AnyView? = nil

    func body(content: Content) -> some View {
        let inset = inset(content)
        if let backgroundView {
            inset.listRowBackground(backgroundView)
        } else if let fill = background.flatMap(colorFromHex) {
            inset.listRowBackground(fill)
        } else {
            inset
        }
    }

    private func inset(_ content: Content) -> AnyView {
        let parts = (insets ?? "").split(separator: ",", omittingEmptySubsequences: false).map { Double($0).map { CGFloat($0) } }
        guard parts.count == 4 else { return AnyView(content) }
        if parts.allSatisfy({ $0 != nil }) {
            return AnyView(content.listRowInsets(EdgeInsets(top: parts[0]!, leading: parts[1]!, bottom: parts[2]!, trailing: parts[3]!)))
        }
        // Some sides only: the others stay the list's (iOS 26's form; before
        // it, UIKit's row margins stand in for them).
        if #available(iOS 26, macOS 26, *) {
            var view = AnyView(content)
            for (edge, value) in [(Edge.Set.top, parts[0]), (.leading, parts[1]), (.bottom, parts[2]), (.trailing, parts[3])] {
                if let value { view = AnyView(view.listRowInsets(edge, value)) }
            }
            return view
        }
        return AnyView(content.listRowInsets(EdgeInsets(top: parts[0] ?? 11, leading: parts[1] ?? 20, bottom: parts[2] ?? 11, trailing: parts[3] ?? 20)))
    }
}

/// `.listRowSeparator(.hidden)` on a row.
struct RowSeparatorModifier: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if hidden {
            content.listRowSeparator(.hidden)
        } else {
            content
        }
    }
}

/// A semantic `tabs` node mounted as the REAL SwiftUI `TabView`: the guest
/// carries the items (labels) as params and the SELECTED tab's content as
/// the single child; native tab selection reports back through the
/// host-event channel and the guest swaps the content.
struct TabsBody: View {
    let pnode: PatchedNode
    let send: (String, String) -> Void
    @State private var selected = 0

    var node: IsoFlat_Node { pnode.flat }

    var body: some View {
        let count = Int(param("count") ?? "0") ?? 0
        let guestSelected = Int(param("selected") ?? "0") ?? 0
        TabView(selection: $selected) {
            ForEach(0 ..< max(count, 1), id: \.self) { index in
                Group {
                    if index == guestSelected, let content = pnode.children.first {
                        NodeView(pnode: content, send: send)
                    } else {
                        Color.clear
                    }
                }
                .tabItem { Text(param("label\(index)") ?? "") }
                .tag(index)
            }
        }
        .onAppear { selected = guestSelected }
        .onChange(of: guestSelected) { value in
            if selected != value { selected = value }
        }
        .onChange(of: selected) { value in
            let current = Int(param("selected") ?? "0") ?? 0
            if value != current, let edit = node.edit { send(edit, String(value)) }
        }
    }

    private func param(_ key: String) -> String? {
        for kv in node.params where kv.key == key { return kv.value }
        return nil
    }
}

/// Presents the tree's presentation layers NATIVELY: the topmost sheet-style
/// layer as a real `.sheet`, an alert layer as a real `.alert` (title +
/// message from the node; its serialized action buttons become alert
/// buttons). Native dismissal (swipe, Esc, an action) reports the node's
/// dismiss event and the guest removes the layer.
struct NativePresentations: ViewModifier {
    let presentations: [PatchedNode]
    let send: (String, String) -> Void

    private var sheet: PatchedNode? {
        presentations.last { $0.flat.style != .alert && !Self.isCover($0) && !Self.isRequest($0) && !Self.isAnchoredPopover($0) }
    }
    /// A popover presented from its view (AnchoredPopover), not as a sheet.
    private static func isAnchoredPopover(_ node: PatchedNode) -> Bool {
        node.flat.style == .popover && node.flat.params.contains { $0.key == "popoverId" }
    }
    /// A picker the app asked for: the system's own, not a sheet
    /// (PickerRequests.swift). Shown as a sheet it was an empty one.
    private var request: PatchedNode? {
        presentations.last { Self.isRequest($0) }
    }
    private static func isRequest(_ node: PatchedNode) -> Bool {
        node.flat.params.contains { $0.key == "request" }
    }
    /// A `.fullScreenCover` layer (a sheet flagged `cover` on the wire).
    private var cover: PatchedNode? {
        presentations.last { Self.isCover($0) }
    }
    private static func isCover(_ node: PatchedNode) -> Bool {
        node.flat.params.contains { $0.key == "cover" && $0.value == "1" }
    }
    private var alert: PatchedNode? {
        presentations.last { $0.flat.style == .alert }
    }

    func body(content: Content) -> some View {
        requested(covered(content))
            .sheet(isPresented: presentedBinding(sheet)) {
                // The sheet as the app asked for it: its detents, grabber
                // and whether a swipe dismisses it.
                if let sheet, let inner = sheet.children.first {
                    NodeView(pnode: inner, send: send)
                        .modifier(SheetTraits(sheet: sheet))
                }
            }
            .alert(
                alert.flatMap { $0.flat.title } ?? "",
                isPresented: presentedBinding(alert)
            ) {
                if let alert {
                    let actions = Self.alertActions(alert)
                    ForEach(actions.indices, id: \.self) { index in
                        Button(actions[index].title) {
                            send(actions[index].tap, "")
                        }
                    }
                }
            } message: {
                if let message = alert.flatMap({ $0.flat.message }), !message.isEmpty {
                    Text(message)
                }
            }
    }

    @ViewBuilder private func requested(_ content: some View) -> some View {
        #if os(iOS) || os(macOS)
        content.modifier(PickerRequests(request: request, send: send))
        #else
        content
        #endif
    }

    @ViewBuilder private func covered(_ content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: presentedBinding(cover)) {
            if let cover, let inner = cover.children.first {
                NodeView(pnode: inner, send: send)
            }
        }
        #else
        content.sheet(isPresented: presentedBinding(cover)) {
            if let cover, let inner = cover.children.first {
                NodeView(pnode: inner, send: send).frame(minWidth: 600, minHeight: 500)
            }
        }
        #endif
    }

    private func presentedBinding(_ node: PatchedNode?) -> Binding<Bool> {
        Binding(
            get: { node != nil },
            set: { presented in
                if !presented, let dismiss = node?.flat.dismiss { send(dismiss, "") }
            })
    }

    /// The serialized action buttons inside an alert layer: (label, tap id).
    static func alertActions(_ node: PatchedNode) -> [(title: String, tap: String)] {
        var out: [(String, String)] = []
        func walk(_ n: PatchedNode) {
            if let tap = n.flat.tap {
                out.append((firstTextIn(n) ?? "OK", tap))
                return
            }
            for child in n.children { walk(child) }
        }
        for child in node.children { walk(child) }
        return out
    }

    private static func firstTextIn(_ node: PatchedNode) -> String? {
        if node.flat.kind == .text { return node.flat.v }
        for child in node.children {
            if let text = firstTextIn(child) { return text }
        }
        return nil
    }
}

/// A semantic `navstack` node mounted as a REAL SwiftUI `NavigationStack`:
/// the guest owns the navigation STATE (its `depth` param mirrors into the
/// path, native pops report back as "back" events) while SwiftUI owns the
/// chrome — bar, large/inline title, toolbar items, search field, push/pop
/// animation. Indistinguishable from compiled native navigation.
struct NavStackBody: View {
    let pnode: PatchedNode
    let send: (String, String) -> Void

    var node: IsoFlat_Node { pnode.flat }

    /// The guest is the source of truth: the path IS its `depth` param,
    /// derived on every render (no local @State to fall out of sync when
    /// the node is re-created by a patch — that left pushes rendered at the
    /// root with no back button). A native pop (back button, swipe) hands
    /// the shrunken path back as "back" events, and the guest's next frame
    /// carries the new depth.
    private var path: Binding<[Int]> {
        Binding(
            get: { Array(0 ..< depth) },
            set: { newValue in
                if newValue.count < depth, let edit = node.edit {
                    for _ in newValue.count ..< depth { send(edit, "back") }
                }
            })
    }

    var body: some View {
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            NavigationStack(path: path) {
                level
                    .navigationDestination(for: Int.self) { _ in
                        // Every level renders the CURRENT serialized content —
                        // the guest only ever serializes the top of its stack.
                        level
                    }
            }
        } else {
            // Before NavigationStack (iOS 15): a NavigationView showing the
            // guest's current top screen — bar, title and toolbar are still
            // the system's — with a back button of our own on a pushed
            // screen, since there is no path to pop. No push animation.
            legacyStack
        }
    }

    @ViewBuilder private var legacyStack: some View {
        let pushed = level.toolbar {
            ToolbarItem(placement: .navigation) {
                if depth > 0 {
                    Button {
                        if let edit = node.edit { send(edit, "back") }
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel("Back")
                }
            }
        }
        #if os(iOS)
        NavigationView { pushed }.navigationViewStyle(.stack)
        #else
        NavigationView { pushed }
        #endif
    }

    @ViewBuilder private var level: some View {
        let leading = items("leading")
        let trailing = items("trailingItems")
        let leadingLabels = labels("leadingLabels", count: leading.count)
        let trailingLabels = labels("trailingLabels", count: trailing.count)
        let leadingSymbols = labels("leadingSymbols", count: leading.count)
        let trailingSymbols = labels("trailingSymbols", count: trailing.count)
        let leadingDisabled = labels("leadingDisabled", count: leading.count)
        let trailingDisabled = labels("trailingDisabled", count: trailing.count)
        content
            .navigationTitle(param("title") ?? "")
            .modifier(TitleDisplayModeModifier(mode: param("displayMode")))
            .modifier(PreferredSchemeModifier(scheme: param("scheme")))
            .modifier(NavSearchModifier(
                prompt: param("searchPrompt"),
                value: param("searchValue") ?? "",
                send: { value in
                    if let edit = node.edit { send(edit, "search:\(value)") }
                }))
            .toolbar {
                // Only declare a group when the screen HAS items for it: an
                // empty `.navigation` group still claims the bar's leading
                // slot on iOS and displaces the system back button, leaving
                // a pushed screen with no way back but a swipe. Each item
                // goes where the app put it: a confirmation is bold, a
                // cancellation where the system puts one.
                let leadingPlaced = placements("leadingPlacements", count: leading.count)
                let trailingPlaced = placements("trailingPlacements", count: trailing.count)
                let cancels = leading.indices.filter { leadingPlaced[$0] == "cancellationAction" }
                let navigation = leading.indices.filter { leadingPlaced[$0] != "cancellationAction" }
                let confirms = trailing.indices.filter { trailingPlaced[$0] == "confirmationAction" }
                let primary = trailing.indices.filter { trailingPlaced[$0] != "confirmationAction" }
                if !cancels.isEmpty {
                    ToolbarItemGroup(placement: .cancellationAction) {
                        ForEach(cancels, id: \.self) { index in
                            barButton(leading[index], symbol: leadingSymbols[index], label: leadingLabels[index], disabled: leadingDisabled[index] == "1", event: "leading:\(index)")
                        }
                    }
                }
                if !navigation.isEmpty {
                    ToolbarItemGroup(placement: .navigation) {
                        ForEach(navigation, id: \.self) { index in
                            barButton(leading[index], symbol: leadingSymbols[index], label: leadingLabels[index], disabled: leadingDisabled[index] == "1", event: "leading:\(index)")
                        }
                    }
                }
                if !confirms.isEmpty {
                    ToolbarItemGroup(placement: .confirmationAction) {
                        ForEach(confirms, id: \.self) { index in
                            barButton(trailing[index], symbol: trailingSymbols[index], label: trailingLabels[index], disabled: trailingDisabled[index] == "1", event: "trailingItem:\(index)")
                        }
                    }
                }
                if !primary.isEmpty {
                    ToolbarItemGroup(placement: .primaryAction) {
                        ForEach(primary, id: \.self) { index in
                            barButton(trailing[index], symbol: trailingSymbols[index], label: trailingLabels[index], disabled: trailingDisabled[index] == "1", event: "trailingItem:\(index)")
                        }
                    }
                }
            }
    }

    /// One bar item: the system's bar button, its tap the guest's event;
    /// disabled as the guest's button is (the system greys it).
    private func barButton(_ title: String, symbol: String, label: String, disabled: Bool, event: String) -> some View {
        Button {
            if let edit = node.edit { send(edit, event) }
        } label: {
            BarItemContent(title: title, symbol: symbol)
        }
        .modifier(BarItemLabel(label: label))
        .disabled(disabled)
    }

    /// Each item's placement name ("" when the guest sent none).
    private func placements(_ key: String, count: Int) -> [String] {
        labels(key, count: count)
    }

    @ViewBuilder private var content: some View {
        if pnode.children.isEmpty {
            Color.clear
        } else {
            NodeView(pnode: pnode.children[0], send: send)
        }
    }

    private var depth: Int { Int(param("depth") ?? "0") ?? 0 }

    /// Per-item accessibility labels ("" = none), padded to `count`.
    private func labels(_ key: String, count: Int) -> [String] {
        var out = (param(key) ?? "").components(separatedBy: "\n")
        if out.count < count { out += Array(repeating: "", count: count - out.count) }
        return out
    }


    private func param(_ key: String) -> String? {
        for kv in node.params where kv.key == key { return kv.value }
        return nil
    }

    private func items(_ key: String) -> [String] {
        (param(key) ?? "").split(separator: "\n").map(String.init)
    }
}

/// `.preferredColorScheme` from the guest: the native chrome (navigation
/// title, status bar) follows the app's declared scheme, not the system's.
struct PreferredSchemeModifier: ViewModifier {
    let scheme: String?

    func body(content: Content) -> some View {
        switch scheme {
        case "light": content.preferredColorScheme(.light)
        case "dark": content.preferredColorScheme(.dark)
        default: content
        }
    }
}

/// A bar item's label: the real SF Symbol when the item is an
/// `Image(systemName:)`, else its text.
struct BarItemContent: View {
    let title: String
    let symbol: String

    var body: some View {
        if !symbol.isEmpty, symbolExists(symbol) {
            Image(systemName: symbol)
        } else {
            Text(title)
        }
    }
}

/// A bar item's `.accessibilityLabel` (icon-only buttons), when it has one.
struct BarItemLabel: ViewModifier {
    let label: String

    func body(content: Content) -> some View {
        if label.isEmpty { content } else { content.accessibilityLabel(label) }
    }
}

/// `.scrollBounceBehavior` from the guest ("<behavior>:<axes>").
struct ScrollBounceModifier: ViewModifier {
    let spec: String?

    func body(content: Content) -> some View {
        if #available(iOS 16.4, macOS 13.3, *), let spec {
            let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
            let behavior: ScrollBounceBehavior = parts.first == "always" ? .always : parts.first == "basedOnSize" ? .basedOnSize : .automatic
            let names = parts.count > 1 ? parts[1] : "v"
            let axes: Axis.Set = [names.contains("v") ? .vertical : [], names.contains("h") ? .horizontal : []]
            content.scrollBounceBehavior(behavior, axes: axes)
        } else {
            content
        }
    }
}

/// `.scrollDismissesKeyboard` from the guest, where the OS has it (iOS).
struct KeyboardDismissModifier: ViewModifier {
    let mode: String?

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            switch mode {
            case "immediately": content.scrollDismissesKeyboard(.immediately)
            case "interactively": content.scrollDismissesKeyboard(.interactively)
            case "never": content.scrollDismissesKeyboard(.never)
            default: content
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// `.toolbarTitleDisplayMode`, applied when the OS has it (the wire value is
/// advisory chrome — older OSes keep the automatic style).
struct TitleDisplayModeModifier: ViewModifier {
    let mode: String?

    func body(content: Content) -> some View {
        // Only `.inline` crosses the wire meaningfully — large is what
        // `.automatic` already does, and `.large` isn't available on macOS.
        if mode == "inline", #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *) {
            content.toolbarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}

/// `.searchable` for a navstack that declared a search field.
struct NavSearchModifier: ViewModifier {
    let prompt: String?
    let value: String
    let send: (String) -> Void

    func body(content: Content) -> some View {
        if let prompt {
            EchoedText(value: value, send: send) { text in
                content.searchable(text: text, prompt: prompt)
            }
        } else {
            content
        }
    }
}

/// A semantic `navsplit` node mounted as a REAL SwiftUI
/// `NavigationSplitView` — native column sizing, materials, and the sidebar
/// toggle. Children: [sidebar, content, detail], each usually a `navstack`.
struct NavSplitBody: View {
    let pnode: PatchedNode
    let send: (String, String) -> Void

    var body: some View {
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            NavSplitNativeBody(pnode: pnode, send: send)
        } else {
            // Before NavigationSplitView (iOS 15): NavigationView's columns.
            NavigationView {
                column(0)
                column(1)
                if pnode.flat.params.contains(where: { $0.key == "columns" && $0.value == "2" }) == false {
                    column(2)
                }
            }
        }
    }

    @ViewBuilder private func column(_ index: Int) -> some View {
        if pnode.children.count > index {
            NodeView(pnode: pnode.children[index], send: send)
        } else {
            Color.clear
        }
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
struct NavSplitNativeBody: View {
    let pnode: PatchedNode
    let send: (String, String) -> Void
    /// `columnVisibility` from the guest ("visibility" param), driving the
    /// native split; the user's own toggling stays local.
    @State private var visibility: NavigationSplitViewVisibility = .automatic
    /// The column a phone shows: the guest's `preferredCompactColumn`
    /// ("compact"), moved again each time the guest asks (a new
    /// "compactTick": a row chosen, a selection cleared); a native back
    /// reports the column it went back to.
    /// ("sidebar" / "content" / "detail": the column type is iOS 17's.)
    @State private var compactColumn = "sidebar"
    @State private var appliedTick: String?

    /// The guest's visibility and phone column from the first frame: set in
    /// `onAppear` instead, an iPad drew `.automatic` (the detail alone, in
    /// portrait) for a few frames before the sidebar the guest asked for.
    init(pnode: PatchedNode, send: @escaping (String, String) -> Void) {
        self.pnode = pnode
        self.send = send
        _visibility = State(initialValue: Self.visibility(Self.param("visibility", of: pnode)))
        _compactColumn = State(initialValue: Self.compact(Self.param("compact", of: pnode)))
        _appliedTick = State(initialValue: Self.param("compactTick", of: pnode))
    }

    private static func param(_ key: String, of pnode: PatchedNode) -> String? {
        for kv in pnode.flat.params where kv.key == key { return kv.value }
        return nil
    }

    private func param(_ key: String) -> String? { Self.param(key, of: pnode) }

    private var requestedVisibility: NavigationSplitViewVisibility { Self.visibility(param("visibility")) }

    private static func visibility(_ name: String?) -> NavigationSplitViewVisibility {
        switch name {
        case "all": return .all
        case "doubleColumn": return .doubleColumn
        case "detailOnly": return .detailOnly
        default: return .automatic
        }
    }

    private var requestedCompact: String { Self.compact(param("compact")) }

    private static func compact(_ name: String?) -> String {
        switch name {
        case "content": return "content"
        case "detail": return "detail"
        default: return "sidebar"
        }
    }

    private static func rank(_ column: String) -> Int {
        column == "detail" ? 2 : column == "content" ? 1 : 0
    }

    /// The native split moving the phone's column (the back button, the
    /// edge swipe): the guest hears where it went, and ":back" when it went
    /// back, which clears the selections past it.
    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
    private var compactBinding: Binding<NavigationSplitViewColumn> {
        Binding(
            get: { compactColumn == "detail" ? .detail : compactColumn == "content" ? .content : .sidebar },
            set: { column in
                let name = column == .detail ? "detail" : column == .content ? "content" : "sidebar"
                let previous = compactColumn
                compactColumn = name
                guard name != previous, let edit = pnode.flat.edit else { return }
                let back = Self.rank(name) < Self.rank(previous)
                send(edit, "compact:" + name + (back ? ":back" : ""))
            })
    }

    var body: some View {
        split
            .modifier(SplitStyleModifier(style: param("style")))
            .onAppear {
                visibility = requestedVisibility
                compactColumn = requestedCompact
                appliedTick = param("compactTick")
            }
            .onChange(of: param("visibility")) { value in visibility = Self.visibility(value) }
            // The request as one value ("<tick>|<column>"), read from what
            // onChange is handed: the closure's own view may be the one
            // before the change.
            .onChange(of: compactRequest) { request in
                let parts = request.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, parts[0] != appliedTick ?? "" else { return }
                appliedTick = parts[0]
                compactColumn = parts[1]
            }
    }

    private var compactRequest: String { (param("compactTick") ?? "") + "|" + requestedCompact }

    @ViewBuilder private var split: some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
            if param("columns") == "2" {
                NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: compactBinding) {
                    sidebar
                } detail: {
                    detail(1)
                }
            } else {
                NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: compactBinding) {
                    sidebar
                } content: {
                    column(1)
                } detail: {
                    detail(2)
                }
            }
        } else {
            // iOS 16: no preferred compact column; a phone's split opens the
            // detail when the sidebar's (native) List selection changes.
            if param("columns") == "2" {
                NavigationSplitView(columnVisibility: $visibility) {
                    sidebar
                } detail: {
                    detail(1)
                }
            } else {
                NavigationSplitView(columnVisibility: $visibility) {
                    sidebar
                } content: {
                    column(1)
                } detail: {
                    detail(2)
                }
            }
        }
    }

    /// The sidebar column; `.toolbar(removing: .sidebarToggle)` when the
    /// guest removed it (the sidebar stays put).
    @ViewBuilder private var sidebar: some View {
        // Column widths are applied where the app put them (colWidth).
        let base = column(0)
        if param("sidebarToggle") == "0", #available(iOS 17.0, macOS 14.0, *) {
            base.toolbar(removing: .sidebarToggle)
        } else {
            base
        }
    }

    @ViewBuilder private func column(_ index: Int) -> some View {
        if pnode.children.count > index {
            NodeView(pnode: pnode.children[index], send: send)
        } else {
            Color.clear
        }
    }

    /// The detail column; with nothing chosen on a phone it is not shown.
    @ViewBuilder private func detail(_ index: Int) -> some View {
        column(index)
    }
}

/// `.navigationSplitViewColumnWidth` from the guest (`<column>Width`, the
/// ideal, with `<column>WidthMin` / `WidthMax` when it gave bounds), else the
/// fallback (min, ideal).
@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
struct ColumnWidthModifier: ViewModifier {
    let ideal: Double?
    let min: Double?
    let max: Double?
    let fallback: (CGFloat, CGFloat)?

    init(_ node: PatchedNode, column: String, fallback: (CGFloat, CGFloat)?) {
        func param(_ key: String) -> Double? {
            for kv in node.flat.params where kv.key == key { return Double(kv.value) }
            return nil
        }
        ideal = param(column + "Width")
        min = param(column + "WidthMin")
        max = param(column + "WidthMax")
        self.fallback = fallback
    }

    func body(content: Content) -> some View {
        if let ideal, min != nil || max != nil {
            content.navigationSplitViewColumnWidth(min: min.map { CGFloat($0) }, ideal: CGFloat(ideal), max: max.map { CGFloat($0) })
        } else if let ideal {
            content.navigationSplitViewColumnWidth(CGFloat(ideal))
        } else if let fallback {
            content.navigationSplitViewColumnWidth(min: fallback.0, ideal: fallback.1)
        } else {
            content
        }
    }
}

/// `.navigationSplitViewStyle` from the guest ("balanced",
/// "prominentDetail"; absent: automatic).
@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
struct SplitStyleModifier: ViewModifier {
    let style: String?

    func body(content: Content) -> some View {
        switch style {
        case "balanced": content.navigationSplitViewStyle(.balanced)
        case "prominentDetail": content.navigationSplitViewStyle(.prominentDetail)
        default: content
        }
    }
}

/// The serialized navigation bar rendered with native SwiftUI components:
/// back chevron, inline title, and the screen's toolbar items
/// (`ToolbarItem(placement:)` — newline-joined `leading`/`trailingItems`
/// params, with the legacy single `trailing` as fallback).
struct NavBarBody: View {
    let node: IsoFlat_Node
    let send: (String, String) -> Void

    var body: some View {
        let leading = items("leading")
        var trailing = items("trailingItems")
        // A legacy single-trailing bundle (no item lists) gets the old
        // "trailing" event its dispatcher understands.
        var legacySingle = false
        if trailing.isEmpty, let legacy = param("trailing"), !legacy.isEmpty {
            trailing = [legacy]
            legacySingle = true
        }
        return HStack(spacing: 10) {
            if param("back") == "1" {
                Button {
                    if let edit = node.edit { send(edit, "back") }
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
            ForEach(leading.indices, id: \.self) { index in
                Button(leading[index]) {
                    if let edit = node.edit { send(edit, "leading:\(index)") }
                }
                .disabled(flag("leadingDisabled", index))
            }
            Text(param("title") ?? "").font(.system(size: 16, weight: .bold))
            Spacer()
            ForEach(trailing.indices, id: \.self) { index in
                Button(trailing[index]) {
                    if let edit = node.edit {
                        send(edit, legacySingle ? "trailing" : "trailingItem:\(index)")
                    }
                }
                .disabled(flag("trailingDisabled", index))
            }
        }
        .padding(.horizontal, 12)
    }

    private func param(_ key: String) -> String? {
        for kv in node.params where kv.key == key { return kv.value }
        return nil
    }

    /// Item `index` of a per-item "1"/"0" list is "1".
    private func flag(_ key: String, _ index: Int) -> Bool {
        let values = (param(key) ?? "").components(separatedBy: "\n")
        return index < values.count && values[index] == "1"
    }

    private func items(_ key: String) -> [String] {
        (param(key) ?? "").split(separator: "\n").map(String.init)
    }
}

struct TabBarBody: View {
    let node: IsoFlat_Node
    let send: (String, String) -> Void

    var body: some View {
        let count = countParam
        let selected = Int(node.v ?? "0") ?? 0
        HStack {
            ForEach(0..<max(count, 1), id: \.self) { index in
                Button {
                    if let edit = node.edit { send(edit, String(index)) }
                } label: {
                    Text(param("label\(index)") ?? "")
                        .font(.system(size: 12))
                        .foregroundColor(index == selected ? .accentColor : .secondary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var countParam: Int {
        Int(param("count") ?? "0") ?? 0
    }

    private func param(_ key: String) -> String? {
        for kv in node.params where kv.key == key { return kv.value }
        return nil
    }
}

struct NativeDatePicker: View {
    let title: String
    let iso: String
    let onChange: (String) -> Void

    var body: some View {
        DatePicker(
            title,
            selection: Binding(get: { parse(iso) }, set: { onChange(format($0)) }),
            displayedComponents: .date)
    }

    private func parse(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: value) ?? Date()
    }

    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

// MARK: - Presentations

struct PresentationBody: View {
    let pnode: PatchedNode
    let send: (String, String) -> Void

    var node: IsoFlat_Node { pnode.flat }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture {
                    if let dismiss = node.dismiss { send(dismiss, "") }
                }
            VStack(spacing: 10) {
                if let title = node.title, !title.isEmpty {
                    Text(title).font(.headline)
                }
                if let message = node.message, !message.isEmpty {
                    Text(message).font(.subheadline).foregroundColor(.secondary)
                }
                if !pnode.children.isEmpty {
                    NodeView(pnode: pnode.children[0], send: send)
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 14).fill(.background))
            .shadow(radius: 24)
            .padding(40)
        }
    }
}

// MARK: - Shared decorations

struct Decorations: ViewModifier {
    let node: IsoFlat_Node
    let send: (String, String) -> Void

    func body(content: Content) -> some View {
        var view = AnyView(content)
        // A Button's padding, fill, corners and tap are the system button's
        // own (its style draws them, its action is the tap).
        let isButton = paramValue("button") != nil || paramValue("share") != nil
        if !isButton, let padding = paddingInsets {
            view = AnyView(view.padding(padding))
        }
        // A fixed frame positions content by the frame's alignment too
        // (`.frame(width:height:alignment: .top)` pins content to the top).
        if node.width != nil || node.height != nil {
            view = AnyView(view.frame(
                width: node.width.map { CGFloat($0) },
                height: node.height.map { CGFloat($0) },
                alignment: frameAlignment))
        }
        // Grow flags become greedy frames — EXCEPT on spacers: a SwiftUI
        // Spacer already absorbs leftover space, and a maxWidth frame would
        // make it compete with siblings for their ideal width (an HStack's
        // Text then wraps despite room; the serializer's grow flag is for
        // the reimplementation's own layout engine).
        if let x = paramValue("posX").flatMap(Double.init), let y = paramValue("posY").flatMap(Double.init) {
            // `.position`: SwiftUI's own (it claims the proposed area itself).
            view = AnyView(view.position(x: CGFloat(x), y: CGFloat(y)))
        } else if node.kind != .spacer {
            // Finite bounds (`.frame(minWidth:maxWidth:…)`) ride the params.
            let minW = paramValue("minW").flatMap(Double.init).map { CGFloat($0) }
            let maxW = paramValue("maxW").flatMap(Double.init).map { CGFloat($0) }
            let minH = paramValue("minH").flatMap(Double.init).map { CGFloat($0) }
            let maxH = paramValue("maxH").flatMap(Double.init).map { CGFloat($0) }
            // A cap stands over greediness: a `.frame(maxWidth: 720)` round
            // greedy content (a transcript's rows, a composer) is the lesser
            // of 720 and what it is offered, as in SwiftUI, not the whole
            // width (an iPhone held sideways lost its chat column's cap).
            if maxW != nil {
                view = AnyView(view.frame(minWidth: minW, maxWidth: maxW, alignment: frameAlignment))
            } else if node.expandW || node.growW {
                view = AnyView(view.frame(minWidth: minW, maxWidth: .infinity, alignment: frameAlignment))
            } else if minW != nil {
                view = AnyView(view.frame(minWidth: minW, alignment: frameAlignment))
            }
            if maxH != nil {
                view = AnyView(view.frame(minHeight: minH, maxHeight: maxH, alignment: frameAlignment))
            } else if node.expandH || node.growH {
                view = AnyView(view.frame(minHeight: minH, maxHeight: .infinity, alignment: frameAlignment))
            } else if minH != nil {
                view = AnyView(view.frame(minHeight: minH, alignment: frameAlignment))
            }
        }
        if let tint = paramValue("tintName").flatMap(hostSystemColor) ?? paramValue("tint").flatMap(colorFromHex) {
            view = AnyView(view.tint(tint))
        }
        if paramValue("clip") == "1" {
            view = AnyView(view.clipped())
        }
        if let fixed = paramValue("fixed") {
            view = AnyView(view.fixedSize(horizontal: fixed.contains("h"), vertical: fixed.contains("v")))
        }
        if let ratio = paramValue("aspect").flatMap(Double.init) {
            view = AnyView(view.aspectRatio(CGFloat(ratio), contentMode: paramValue("aspectMode") == "fill" ? .fill : .fit))
        }
        if !isButton, node.kind != .shape, node.kind != .gradient {
            // A material's fill is drawn by its layer (the guest sends it as
            // both); only plain fills land on the node.
            if let gradient = node.gradient, node.kind != .gradient, MaterialFill(json: gradient) == nil,
               let paint = gradientPaint(gradient) {
                view = AnyView(view.background(
                    RoundedRectangle(cornerRadius: CGFloat(node.radius ?? 0)).fill(paint)))
            } else if let bg = node.bg {
                view = AnyView(view.background(
                    RoundedRectangle(cornerRadius: CGFloat(node.radius ?? 0))
                        .fill(paramValue("bgName").flatMap(hostSystemColor) ?? swiftColor(bg))))
            }
            // A radius that is the background's own (param "radiusOf")
            // rounds the fill above and clips nothing, as SwiftUI's
            // background and glass don't: clipped, a composer's glass lost
            // its rim.
            if let radius = node.radius, radius > 0, paramValue("radiusOf") != "bg" {
                view = AnyView(view.clipShape(RoundedRectangle(cornerRadius: CGFloat(radius))))
            }
        }
        // Always applied, at 1 when the guest sent none: a value that comes
        // and goes (a fade in, a row revealed) must not change what wraps
        // the view, or SwiftUI takes it for another view and builds it anew
        // — a list losing its scroll, a field its focus.
        view = AnyView(view.opacity(node.opacity ?? 1))
        if let shadow = node.shadow {
            view = AnyView(view.shadow(
                color: swiftColor(shadow.color),
                radius: CGFloat(shadow.radius),
                x: CGFloat(shadow.x),
                y: CGFloat(shadow.y)))
        }
        if !isButton, let tap = node.tap {
            IsomerTreeBenchHook.lastTapID = tap
            view = AnyView(view.contentShape(Rectangle()).onTapGesture(count: Int(paramValue("tapCount") ?? "") ?? 1) {
                IsomerTreeBenchHook.onTapReceived?()
                send(tap, "")
            })
        }
        // Row actions: `.swipeActions` (a list row's) and `.contextMenu`, the
        // system's own; the item's index goes back on the node's id.
        if let swipe = paramValue("swipe") {
            view = AnyView(view.modifier(SwipeActionsModifier(
                id: swipe, leading: RowAction.parse(paramValue("swipeLeading")),
                trailing: RowAction.parse(paramValue("swipeTrailing")),
                full: paramValue("swipeFull") == "1", send: send)))
        }
        if let menu = paramValue("ctxmenu") {
            let items = RowAction.parse(paramValue("ctxitems"))
            view = AnyView(view.contextMenu {
                ForEach(items) { item in
                    item.button { send(menu, item.index) }
                }
            })
        }
        // Visual transforms (`.offset` / `.scaleEffect`): the guest ships the
        // animator's per-frame values, so these are plain modifiers here.
        // Animated values, always applied (see opacity above).
        view = AnyView(view
            .scaleEffect(CGFloat(node.scale ?? 1))
            .offset(x: CGFloat(node.offsetX ?? 0), y: CGFloat(node.offsetY ?? 0)))
        // A guest DragGesture: report the running translation and the release
        // on the node's drag id; the guest's onChanged/onEnded run from them.
        if let drag = node.drag {
            view = AnyView(view.contentShape(Rectangle()).gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        send(drag, "changed:\(value.translation.width),\(value.translation.height)")
                    }
                    .onEnded { value in
                        send(drag, "ended:\(value.translation.width),\(value.translation.height)")
                    }))
        }
        // A pinch (`MagnifyGesture`), alongside any drag.
        if let magnify = paramValue("magnify") {
            view = AnyView(view.simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in send(magnify, "changed:\(value)") }
                    .onEnded { value in send(magnify, "ended:\(value)") }))
        }
        if let ideal = paramValue("colWidth").flatMap(Double.init), #available(iOS 16.0, macOS 13.0, *) {
            let min = paramValue("colWidthMin").flatMap(Double.init).map { CGFloat($0) }
            let max = paramValue("colWidthMax").flatMap(Double.init).map { CGFloat($0) }
            view = min == nil && max == nil
                ? AnyView(view.navigationSplitViewColumnWidth(CGFloat(ideal)))
                : AnyView(view.navigationSplitViewColumnWidth(min: min, ideal: CGFloat(ideal), max: max))
        }
        if let vid = paramValue("vid") { view = AnyView(view.id(vid)) }
        if let label = paramValue("a11yLabel") { view = AnyView(view.accessibilityLabel(label)) }
        if let hint = paramValue("a11yHint") { view = AnyView(view.accessibilityHint(hint)) }
        if let value = paramValue("a11yValue") { view = AnyView(view.accessibilityValue(value)) }
        if let id = paramValue("a11yId") { view = AnyView(view.accessibilityIdentifier(id)) }
        if paramValue("a11yHidden") == "1" { view = AnyView(view.accessibilityHidden(true)) }
        switch paramValue("a11yChildren") {
        case "combine": view = AnyView(view.accessibilityElement(children: .combine))
        case "ignore": view = AnyView(view.accessibilityElement(children: .ignore))
        case "contain": view = AnyView(view.accessibilityElement(children: .contain))
        default: break
        }
        if paramValue("safeArea") == "ignore" {
            view = AnyView(view.ignoresSafeArea())
        }
        if let popover = paramValue("popover") {
            view = AnyView(view.modifier(AnchoredPopover(id: popover, send: send)))
        }
        return view
    }

    private func paramValue(_ key: String) -> String? {
        for kv in node.params where kv.key == key { return kv.value }
        return nil
    }

    private var frameAlignment: Alignment {
        let horizontal: HorizontalAlignment
        switch node.alignH {
        case .start: horizontal = .leading
        case .end: horizontal = .trailing
        default: horizontal = .center
        }
        let vertical: VerticalAlignment
        switch node.alignV {
        case .start: vertical = .top
        case .end: vertical = .bottom
        default: vertical = .center
        }
        return Alignment(horizontal: horizontal, vertical: vertical)
    }

    private var paddingInsets: EdgeInsets? {
        guard node.padding.count == 4 else { return nil }
        return EdgeInsets(
            top: CGFloat(node.padding[0]),
            leading: CGFloat(node.padding[1]),
            bottom: CGFloat(node.padding[2]),
            trailing: CGFloat(node.padding[3]))
    }
}

// MARK: - Small helpers

/// Whether an SF Symbol name resolves on this OS.
func symbolExists(_ name: String) -> Bool {
    #if canImport(UIKit)
    return UIImage(systemName: name) != nil
    #elseif canImport(AppKit)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    #else
    return false
    #endif
}

/// "#rrggbbaa" → Color.
func colorFromHex(_ hex: String) -> Color? {
    var text = Substring(hex)
    if text.hasPrefix("#") { text = text.dropFirst() }
    guard text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
    return Color(
        red: Double((value >> 24) & 0xFF) / 255, green: Double((value >> 16) & 0xFF) / 255,
        blue: Double((value >> 8) & 0xFF) / 255, opacity: Double(value & 0xFF) / 255)
}

func swiftColor(_ value: IsoFlat_ColorRGBA) -> Color {
    Color(
        red: Double(value.r), green: Double(value.g), blue: Double(value.b),
        opacity: Double(value.a))
}

func flatFontWeight(_ weight: Int32) -> Font.Weight {
    switch weight {
    case ..<300: return .light
    case ..<500: return .regular
    case ..<600: return .medium
    case ..<700: return .semibold
    default: return .bold
    }
}


/// Benchmark hook (the iOS wasm cell; see apple/libraries/bench): the id of
/// the most recently built tap-able node, so the harness can inject the same
/// event a tap would send. One assignment per build; dormant otherwise.
public enum IsomerTreeBenchHook {
    nonisolated(unsafe) public static var lastTapID: String?
    /// Fires at each tree body evaluation (see TapCounterBenchBridge.bodyTick).
    nonisolated(unsafe) public static var bodyTick: (() -> Void)?
    /// Fires the instant a real tap gesture is received (the UIEvent →
    /// handler edge), BEFORE the reactor event is sent — the signpost-begin
    /// point for the interaction benchmark (see apple/libraries/bench).
    nonisolated(unsafe) public static var onTapReceived: (() -> Void)?
}


// MARK: - Remote images

#if canImport(UIKit)
import UIKit
typealias TreePlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias TreePlatformImage = NSImage
#endif

/// Process-wide cache + in-flight dedupe for remote image bytes, keyed by
/// URL. SwiftUI's `AsyncImage` restarts (and can strand on its placeholder)
/// whenever the hosting view is re-created mid-download — which the tree
/// renderer does on every patch that touches the row (a detail page's second
/// fetch landing, a list re-diff). Loads here outlive the views: a re-created
/// row joins the in-flight task and gets the cached image on the next pass.
final class RemoteImageStore: @unchecked Sendable {
    static let shared = RemoteImageStore()
    private let cache = NSCache<NSURL, TreePlatformImage>()
    private var inflight: [URL: Task<TreePlatformImage?, Never>] = [:]
    private let lock = NSLock()

    func cached(_ url: URL) -> TreePlatformImage? { cache.object(forKey: url as NSURL) }

    func image(for url: URL) async -> TreePlatformImage? {
        if let hit = cached(url) { return hit }
        lock.lock()
        let task: Task<TreePlatformImage?, Never>
        if let running = inflight[url] {
            task = running
        } else {
            task = Task.detached(priority: .userInitiated) { [cache] in
                // Two attempts: transient failures (a dropped cellular
                // connection mid-body) otherwise strand the placeholder.
                for attempt in 0..<2 {
                    do {
                        var request = URLRequest(url: url)
                        request.cachePolicy = .returnCacheDataElseLoad
                        let (data, response) = try await URLSession.shared.data(for: request)
                        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                            throw URLError(.badServerResponse)
                        }
                        if let image = TreePlatformImage(data: data) {
                            cache.setObject(image, forKey: url as NSURL)
                            return image
                        }
                        NSLog("[tree-image] undecodable image at %@ (%d bytes)", url.absoluteString, data.count)
                        return nil
                    } catch {
                        NSLog("[tree-image] attempt %d failed for %@: %@", attempt + 1, url.absoluteString, String(describing: error))
                        if attempt == 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
                    }
                }
                return nil
            }
            inflight[url] = task
        }
        lock.unlock()
        let result = await task.value
        lock.lock()
        inflight[url] = nil
        lock.unlock()
        return result
    }
}

/// A remote image node: cached bytes render immediately; otherwise the
/// placeholder shows while the shared store loads (surviving re-creation).
struct RemoteImageView: View {
    let url: URL
    let fit: Bool
    var pixelated = false
    @State private var loaded: TreePlatformImage?

    private var image: TreePlatformImage? { loaded ?? RemoteImageStore.shared.cached(url) }

    var body: some View {
        Group {
            if let image {
                #if canImport(UIKit)
                fitted(Image(uiImage: image).resizable().interpolation(pixelated ? .none : .medium))
                #else
                fitted(Image(nsImage: image).resizable().interpolation(pixelated ? .none : .medium))
                #endif
            } else {
                Color(white: 0.5, opacity: 0.08)
            }
        }
        // Keyed on the URL so a node whose source changes (an AsyncImage
        // swapped to another picture) reloads instead of keeping its first
        // image; the cache answers repeats without a flash.
        .task(id: url) {
            if let hit = RemoteImageStore.shared.cached(url) {
                loaded = hit
                return
            }
            loaded = nil
            loaded = await RemoteImageStore.shared.image(for: url)
        }
    }

    @ViewBuilder private func fitted(_ image: some View) -> some View {
        if fit {
            image.aspectRatio(contentMode: .fit)
        } else {
            image.aspectRatio(contentMode: .fill)
        }
    }
}


// MARK: - Text-input and scroll helpers

private func hostScrollTo(_ request: String?, proxy: ScrollViewProxy) {
    guard let request else { return }
    let parts = request.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard let target = parts.first, !target.isEmpty else { return }
    let anchor: UnitPoint?
    switch parts.count > 2 ? parts[2] : "auto" {
    case "top": anchor = .top
    case "bottom": anchor = .bottom
    case "center": anchor = .center
    default: anchor = nil
    }
    // Eased only when the app scrolled inside `withAnimation` ("a").
    if parts.count > 3, parts[3] == "a" {
        withAnimation { proxy.scrollTo(target, anchor: anchor) }
    } else {
        proxy.scrollTo(target, anchor: anchor)
    }
}

#if os(iOS)
private func hostKeyboardType(_ name: String) -> UIKeyboardType {
    switch name {
    case "asciiCapable": return .asciiCapable
    case "numbersAndPunctuation": return .numbersAndPunctuation
    case "URL": return .URL
    case "numberPad": return .numberPad
    case "phonePad": return .phonePad
    case "namePhonePad": return .namePhonePad
    case "emailAddress": return .emailAddress
    case "decimalPad": return .decimalPad
    case "twitter": return .twitter
    case "webSearch": return .webSearch
    case "asciiCapableNumberPad": return .asciiCapableNumberPad
    default: return .default
    }
}

private func hostAutocapitalization(_ name: String) -> TextInputAutocapitalization {
    switch name {
    case "never": return .never
    case "words": return .words
    case "characters": return .characters
    default: return .sentences
    }
}
#endif


// MARK: - Row actions

/// One row action on the wire: index, title, symbol, "d" when destructive,
/// tint ("#rrggbbaa"); fields record-separated, items unit-separated.
struct RowAction: Identifiable {
    let index: String
    let title: String
    let symbol: String
    let destructive: Bool
    let tint: Color?
    var id: String { index }

    static func parse(_ value: String?) -> [RowAction] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: "\u{1F}", omittingEmptySubsequences: false).map { item in
            let fields = item.split(separator: "\u{1E}", omittingEmptySubsequences: false).map(String.init)
            func field(_ i: Int) -> String { i < fields.count ? fields[i] : "" }
            return RowAction(index: field(0), title: field(1), symbol: field(2), destructive: field(3) == "d",
                             tint: colorFromHex(field(4)))
        }
    }

    /// The action as the system's button: a `Label` when it has a symbol.
    @ViewBuilder func button(_ action: @escaping () -> Void) -> some View {
        let button = Button(role: destructive ? .destructive : nil, action: action) {
            if symbol.isEmpty || !symbolExists(symbol) {
                Text(title)
            } else {
                Label(title, systemImage: symbol)
            }
        }
        if let tint {
            button.tint(tint)
        } else {
            button
        }
    }
}

/// `.swipeActions` on a row, from both edges.
struct SwipeActionsModifier: ViewModifier {
    let id: String
    let leading: [RowAction]
    let trailing: [RowAction]
    let full: Bool
    let send: (String, String) -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: full) {
                ForEach(leading) { item in item.button { send(id, item.index) } }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: full) {
                ForEach(trailing) { item in item.button { send(id, item.index) } }
            }
    }
}

// MARK: - Bottom bar

/// A screen's `.bottomBar` toolbar (the guest's column with a `bottomBar`
/// param: [content, the drawn bar]) as the system's own bottom toolbar —
/// on iOS 26 glass items floating over the content, the `.searchable` field
/// among them (`DefaultToolbarItem(kind: .search, placement: .bottomBar)`).
/// The drawn bar is the description: each item's tap, symbol and title (a
/// button), or its field (the search).
struct BottomBarBody: View {
    let pnode: PatchedNode
    let send: (String, String) -> Void

    var body: some View {
        let content = pnode.children.first.map { NodeView(pnode: $0, send: send) }
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content.modifier(BottomToolbar(items: items, send: send))
        } else {
            content.modifier(LegacyBottomToolbar(items: items, send: send))
        }
        #else
        // No bottom toolbar here: the drawn bar, under the content.
        VStack(spacing: 0) {
            ForEach(0..<pnode.children.count, id: \.self) { index in
                NodeView(pnode: pnode.children[index], send: send)
            }
        }
        #endif
    }

    private var items: [BottomBarItem] {
        let kinds = (pnode.flat.params.first { $0.key == "bottomBar" }?.value ?? "").split(separator: "\n").map(String.init)
        // bar box → its row → the item views (none for a fixed spacer).
        let views = pnode.children.count > 1 ? (pnode.children[1].children.first?.children ?? []) : []
        var out: [BottomBarItem] = []
        var next = 0
        for kind in kinds {
            if kind == "fixed" { out.append(.fixedSpacer); continue }
            guard next < views.count else { break }
            let view = views[next]
            next += 1
            switch kind {
            case "flex": out.append(.flexibleSpacer)
            case "search":
                if let field = Self.first(in: view, where: { $0.flat.kind == .textfield }) {
                    out.append(.search(edit: field.flat.edit, value: field.flat.v ?? "", prompt: field.flat.placeholder ?? ""))
                }
            case "button":
                let tap = Self.first(in: view) { $0.flat.tap != nil }?.flat.tap
                let symbol = Self.first(in: view) { Self.param($0, "symbol") != nil }.flatMap { Self.param($0, "symbol") }
                let label = Self.first(in: view) { Self.param($0, "a11yLabel") != nil }.flatMap { Self.param($0, "a11yLabel") }
                let title = Self.first(in: view) { $0.flat.kind == .text && Self.param($0, "symbol") == nil }?.flat.v
                out.append(.button(tap: tap, title: label ?? title ?? "", symbol: symbol))
            default:
                out.append(.view(view))
            }
        }
        return out
    }

    static func param(_ node: PatchedNode, _ key: String) -> String? {
        for kv in node.flat.params where kv.key == key { return kv.value }
        return nil
    }

    static func first(in node: PatchedNode, where test: (PatchedNode) -> Bool) -> PatchedNode? {
        if test(node) { return node }
        for child in node.children {
            if let found = first(in: child, where: test) { return found }
        }
        return nil
    }
}

enum BottomBarItem {
    case search(edit: String?, value: String, prompt: String)
    case fixedSpacer
    case flexibleSpacer
    case button(tap: String?, title: String, symbol: String?)
    case view(PatchedNode)

    var search: (edit: String?, value: String, prompt: String)? {
        if case let .search(edit, value, prompt) = self { return (edit, value, prompt) }
        return nil
    }
}

#if os(iOS)
/// `.searchable` for the bar's field, when it has one.
struct BarSearchable: ViewModifier {
    let search: (edit: String?, value: String, prompt: String)?
    let send: (String, String) -> Void

    func body(content: Content) -> some View {
        if let search {
            EchoedText(value: search.value, send: { value in if let edit = search.edit { send(edit, value) } }) { text in
                content.searchable(text: text, prompt: search.prompt)
            }
        } else {
            content
        }
    }
}

@available(iOS 26.0, *)
struct BottomToolbar: ViewModifier {
    let items: [BottomBarItem]
    let send: (String, String) -> Void

    func body(content: Content) -> some View {
        content
            .modifier(BarSearchable(search: items.lazy.compactMap(\.search).first, send: send))
            .toolbar {
                item(0)
                item(1)
                item(2)
                item(3)
                item(4)
                item(5)
                item(6)
                item(7)
            }
    }

    @ToolbarContentBuilder private func item(_ index: Int) -> some ToolbarContent {
        if index < items.count {
            switch items[index] {
            case .search:
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
            case .fixedSpacer:
                ToolbarSpacer(.fixed, placement: .bottomBar)
            case .flexibleSpacer:
                ToolbarSpacer(.flexible, placement: .bottomBar)
            case let .button(tap, title, symbol):
                ToolbarItem(placement: .bottomBar) {
                    BarButton(tap: tap, title: title, symbol: symbol, send: send)
                }
            case let .view(node):
                ToolbarItem(placement: .bottomBar) {
                    NodeView(pnode: node, send: send)
                }
            }
        }
    }
}

/// Before iOS 26: the search field in the navigation bar, the buttons in
/// the bottom toolbar.
struct LegacyBottomToolbar: ViewModifier {
    let items: [BottomBarItem]
    let send: (String, String) -> Void

    func body(content: Content) -> some View {
        content
            .modifier(BarSearchable(search: items.lazy.compactMap(\.search).first, send: send))
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    ForEach(0..<items.count, id: \.self) { index in
                        switch items[index] {
                        case .flexibleSpacer: Spacer()
                        case let .button(tap, title, symbol): BarButton(tap: tap, title: title, symbol: symbol, send: send)
                        case let .view(node): NodeView(pnode: node, send: send)
                        default: EmptyView()
                        }
                    }
                }
            }
    }
}

/// A bar button: the symbol (its title read out), or the title.
struct BarButton: View {
    let tap: String?
    let title: String
    let symbol: String?
    let send: (String, String) -> Void

    var body: some View {
        Button {
            if let tap { send(tap, "") }
        } label: {
            if let symbol, symbolExists(symbol) {
                Image(systemName: symbol)
            } else {
                Text(title)
            }
        }
        .accessibilityLabel(title)
    }
}
#endif


// MARK: - Buttons and text styles

/// A `Button` as the system's: its label (the box's content, without the
/// guest's drawing of the style), its style, size, shape and role; the
/// action is the node's tap.
struct NativeButtonBody: View {
    let pnode: PatchedNode
    let send: (String, String) -> Void

    private func param(_ key: String) -> String? {
        for kv in pnode.flat.params where kv.key == key { return kv.value }
        return nil
    }

    private var role: ButtonRole? {
        switch param("role") {
        case "destructive": return .destructive
        case "cancel": return .cancel
        default: return nil
        }
    }

    var body: some View {
        let label = pnode.children.filter { child in !child.flat.params.contains { $0.key == "layer" } }
        Button(role: role) {
            if let tap = pnode.flat.tap { send(tap, "") }
        } label: {
            ForEach(0..<label.count, id: \.self) { index in
                NodeView(pnode: label[index], send: send)
            }
        }
        .modifier(HostButtonStyle(name: param("button")))
        .modifier(HostControlSize(name: param("controlSize")))
        .modifier(HostBorderShape(name: param("borderShape")))
    }
}

struct HostButtonStyle: ViewModifier {
    let name: String?

    func body(content: Content) -> some View {
        switch name {
        case "plain": content.buttonStyle(.plain)
        case "borderless": content.buttonStyle(.borderless)
        case "bordered": content.buttonStyle(.bordered)
        case "borderedProminent": content.buttonStyle(.borderedProminent)
        case "glass":
            if #available(iOS 26.0, macOS 26.0, *) { content.buttonStyle(.glass) } else { content.buttonStyle(.bordered) }
        case "glassProminent":
            if #available(iOS 26.0, macOS 26.0, *) { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.borderedProminent) }
        default: content
        }
    }
}

struct HostControlSize: ViewModifier {
    let name: String?

    func body(content: Content) -> some View {
        switch name {
        case "mini": content.controlSize(.mini)
        case "small": content.controlSize(.small)
        case "large": content.controlSize(.large)
        case "extraLarge":
            if #available(iOS 17.0, macOS 14.0, *) { content.controlSize(.extraLarge) } else { content.controlSize(.large) }
        default: content
        }
    }
}

struct HostBorderShape: ViewModifier {
    let name: String?

    func body(content: Content) -> some View {
        if #available(iOS 15.0, macOS 14.0, *) {
            switch name {
            case "capsule": content.buttonBorderShape(.capsule)
            case "circle":
                if #available(iOS 17.0, macOS 14.0, *) { content.buttonBorderShape(.circle) } else { content.buttonBorderShape(.capsule) }
            case let name? where name.hasPrefix("roundedRectangle"):
                if let radius = name.split(separator: ":").last.flatMap({ Double($0) }) {
                    content.buttonBorderShape(.roundedRectangle(radius: CGFloat(radius)))
                } else {
                    content.buttonBorderShape(.roundedRectangle)
                }
            default: content
            }
        } else {
            content
        }
    }
}

/// A text style's name on the wire as SwiftUI's.
func hostTextStyle(_ name: String) -> Font.TextStyle? {
    switch name {
    case "largeTitle": return .largeTitle
    case "title": return .title
    case "title2": return .title2
    case "title3": return .title3
    case "headline": return .headline
    case "body": return .body
    case "callout": return .callout
    case "subheadline": return .subheadline
    case "footnote": return .footnote
    case "caption": return .caption
    case "caption2": return .caption2
    default: return nil
    }
}

// MARK: - Pictures the app decoded

/// The pictures a guest's ImageIO decoded (`isomer-image://` sources),
/// from the bytes that rode the tree with the node that first showed one.
final class HostImages: @unchecked Sendable {
    static let shared = HostImages()
    private let cache = NSCache<NSString, TreePlatformImage>()
    /// Bytes taken from patches, not drawn yet.
    private var pending: [String: Data] = [:]
    private let lock = NSLock()

    init() { cache.countLimit = 200 }

    /// A picture's bytes as a patch brings them.
    func remember(_ source: String, base64: String) {
        guard let data = Data(base64Encoded: base64) else { return }
        lock.lock()
        pending[source] = data
        lock.unlock()
    }

    func image(for source: String, base64: String?) -> TreePlatformImage? {
        if let hit = cache.object(forKey: source as NSString) { return hit }
        lock.lock()
        let kept = pending.removeValue(forKey: source)
        lock.unlock()
        guard let data = kept ?? base64.flatMap({ Data(base64Encoded: $0) }), let image = TreePlatformImage(data: data) else { return nil }
        cache.setObject(image, forKey: source as NSString)
        return image
    }
}

// MARK: - Materials and glass

/// A material or Liquid Glass from the guest's paint JSON ("material", and
/// for `.glassEffect` "glass", "glassTint", "interactive").
struct MaterialFill {
    let material: String
    let glass: String?
    let tint: Color?
    let interactive: Bool

    init?(json: String) {
        guard json.contains("\"material\""), let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let material = object["material"] as? String else { return nil }
        self.material = material
        glass = object["glass"] as? String
        if let c = object["glassTint"] as? [Double], c.count == 4 {
            tint = Color(red: c[0], green: c[1], blue: c[2], opacity: c[3])
        } else {
            tint = nil
        }
        interactive = (object["interactive"] as? Int) == 1
    }

    @ViewBuilder func view<S: Shape>(in shape: S) -> some View {
        if let glass, #available(iOS 26.0, macOS 26.0, *) {
            Color.clear.glassEffect(glassValue(glass), in: shape)
        } else {
            shape.fill(swiftMaterial)
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    func glassValue(_ variant: String) -> Glass {
        var value: Glass = variant == "clear" ? .clear : variant == "identity" ? .identity : .regular
        if let tint { value = value.tint(tint) }
        if interactive { value = value.interactive() }
        return value
    }

    var swiftMaterialFill: Material { swiftMaterial }

    private var swiftMaterial: Material {
        switch material {
        case "ultraThin", "glass": return .ultraThinMaterial
        case "thin": return .thinMaterial
        case "thick": return .thickMaterial
        case "ultraThick": return .ultraThickMaterial
        case "bar": return .bar
        default: return .regularMaterial
        }
    }
}

/// `.glassEffect(_:in:)` on a view: on iOS 26 the system's glass, its
/// content in it; before, the material behind it.
struct GlassEffectModifier: ViewModifier {
    let fill: MaterialFill?
    let shape: NodeShape?

    func body(content: Content) -> some View {
        if let fill, let shape {
            fill.applied(to: content, in: shape)
        } else {
            content
        }
    }
}

extension MaterialFill {
    @ViewBuilder func applied<V: View, S: Shape>(to content: V, in shape: S) -> some View {
        if let glass, #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(glassValue(glass), in: shape)
        } else {
            content.background(shape.fill(swiftMaterialFill))
        }
    }
}

/// A system colour by the name the guest gave it ("green", "green@0.5"):
/// SwiftUI's own, dynamic and treated by glass and vibrancy as the
/// system's are.
func hostSystemColor(_ spec: String) -> Color? {
    let parts = spec.split(separator: "@")
    let color: Color
    switch parts.first.map(String.init) ?? "" {
    case "red": color = .red
    case "orange": color = .orange
    case "yellow": color = .yellow
    case "green": color = .green
    case "mint": color = .mint
    case "teal": color = .teal
    case "cyan": color = .cyan
    case "blue": color = .blue
    case "indigo": color = .indigo
    case "purple": color = .purple
    case "pink": color = .pink
    case "brown": color = .brown
    case "gray": color = .gray
    case "black": color = .black
    case "white": color = .white
    case "clear": color = .clear
    case "primary": color = .primary
    case "secondary": color = .secondary
    case "accentColor": color = .accentColor
    default: return nil
    }
    if parts.count > 1, let opacity = Double(parts[1]) { return color.opacity(opacity) }
    return color
}

/// `.presentationDetents`, `.presentationDragIndicator` and
/// `.interactiveDismissDisabled` from the sheet's params.
struct SheetTraits: ViewModifier {
    let sheet: PatchedNode

    private func param(_ key: String) -> String? {
        for kv in sheet.flat.params where kv.key == key { return kv.value }
        return nil
    }

    func body(content: Content) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            let names = (param("detents") ?? "").split(separator: ",")
            let detents: Set<PresentationDetent> = Set(names.compactMap { $0 == "medium" ? .medium : $0 == "large" ? .large : nil })
            let grabber: Visibility = param("grabber") == "0" ? .hidden : param("grabber") == "1" ? .visible : .automatic
            content
                .presentationDetents(detents.isEmpty ? [.large] : detents)
                .presentationDragIndicator(grabber)
                .interactiveDismissDisabled(param("nodismiss") == "1")
        } else {
            content.interactiveDismissDisabled(param("nodismiss") == "1")
        }
    }
}

// MARK: - Form

/// A drawn Form (its parts marked "form": the form, its sections, their
/// header, card, rows and footer) as SwiftUI's Form: the system's grouped
/// rows, section headers and footers. Rows outside any section share an
/// implicit one, as SwiftUI's do.
struct FormBody: View {
    let pnode: PatchedNode
    let send: (String, String) -> Void

    struct Part: Identifiable {
        let id: Int
        let header: PatchedNode?
        let rows: [PatchedNode]
        let footer: PatchedNode?
    }

    var body: some View {
        let parts = Self.parts(of: pnode)
        Form {
            ForEach(parts) { part in
                FormSectionView(part: part, send: send)
            }
        }
    }

    static func role(_ node: PatchedNode) -> String? {
        for kv in node.flat.params where kv.key == "form" { return kv.value }
        return nil
    }

    /// The section a wrapper box holds (`Section {…}.id(…)` and the like).
    static func sectionWithin(_ node: PatchedNode) -> PatchedNode? {
        var current = node
        while role(current) != "section" {
            guard current.flat.kind == .box, current.children.count == 1 else { return nil }
            current = current.children[0]
        }
        return current
    }

    /// A view with nothing in it (an `if` that is false, an EmptyView): a
    /// header or footer of nothing is none, as SwiftUI's is.
    static func isEmpty(_ node: PatchedNode) -> Bool {
        switch node.flat.kind {
        case .box, .stack: return node.children.allSatisfy(isEmpty)
        case .text: return (node.flat.v ?? "").isEmpty
        default: return false
        }
    }

    static func parts(of form: PatchedNode) -> [Part] {
        guard let scroll = form.children.first(where: { $0.flat.kind == .scroll }),
              let column = scroll.children.first else { return [] }
        var out: [Part] = []
        var loose: [PatchedNode] = []
        func flushLoose() {
            if !loose.isEmpty { out.append(Part(id: out.count, header: nil, rows: loose, footer: nil)) }
            loose = []
        }
        for wrapped in column.children {
            // A section behind modifiers (a box around it) is that section;
            // an empty view between sections is nothing.
            let child = sectionWithin(wrapped) ?? wrapped
            if role(child) != "section" {
                if !isEmpty(child) { loose.append(child) }
                continue
            }
            flushLoose()
            var header: PatchedNode?
            var footer: PatchedNode?
            var rows: [PatchedNode] = []
            for piece in child.children {
                switch role(piece) {
                case "header": header = piece.children.first.flatMap { isEmpty($0) ? nil : $0 }
                case "footer": footer = piece.children.first.flatMap { isEmpty($0) ? nil : $0 }
                case "card":
                    rows = (piece.children.first?.children ?? []).filter { role($0) == "row" }.compactMap(\.children.first)
                default: break
                }
            }
            out.append(Part(id: out.count, header: header, rows: rows, footer: footer))
        }
        flushLoose()
        return out
    }
}

struct FormSectionView: View {
    let part: FormBody.Part
    let send: (String, String) -> Void

    @ViewBuilder private var rows: some View {
        ForEach(0..<part.rows.count, id: \.self) { index in
            NodeView(pnode: part.rows[index], send: send)
        }
    }

    var body: some View {
        switch (part.header, part.footer) {
        case let (header?, footer?):
            Section { rows } header: { NodeView(pnode: header, send: send) } footer: { NodeView(pnode: footer, send: send) }
        case let (header?, nil):
            Section { rows } header: { NodeView(pnode: header, send: send) }
        case let (nil, footer?):
            Section { rows } footer: { NodeView(pnode: footer, send: send) }
        default:
            Section { rows }
        }
    }
}

/// `.pickerStyle` from the guest ("" for the platform's automatic one).
struct HostPickerStyle: ViewModifier {
    let name: String?

    func body(content: Content) -> some View {
        switch name {
        case "segmented": content.pickerStyle(.segmented)
        case "menu": content.pickerStyle(.menu)
        case "inline": content.pickerStyle(.inline)
        #if os(iOS)
        case "wheel": content.pickerStyle(.wheel)
        #endif
        default: content
        }
    }
}

/// `.labelsHidden()` from the guest.
struct LabelsHiddenModifier: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if hidden { content.labelsHidden() } else { content }
    }
}

/// `.defaultScrollAnchor(.bottom)` from the guest ("anchor", with its role
/// in "anchorFor": "initialOffset", "sizeChanges"; none for every role) and
/// `.defaultScrollAnchor(.bottom, for: .alignment)` ("anchorAlign"): a chat
/// opens at its end and stays there as rows come in above or below, as the
/// app's own would.
struct ScrollAnchorModifier: ViewModifier {
    let anchor: String?
    let role: String?
    let align: String?

    // One structure whatever the values: a branch for each would make the
    // scroll another view, back at its top, whenever the app moves its
    // anchor (a chat lets go of its bottom while a reply comes in).
    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            let bottom = anchor == "bottom"
            content
                .defaultScrollAnchor(bottom && role != "sizeChanges" ? .bottom : nil, for: .initialOffset)
                .defaultScrollAnchor(bottom && role != "initialOffset" ? .bottom : nil, for: .sizeChanges)
                .defaultScrollAnchor(align == "bottom" ? .bottom : nil, for: .alignment)
        } else if #available(iOS 17.0, macOS 14.0, *) {
            content.defaultScrollAnchor(anchor == "bottom" ? .bottom : nil)
        } else {
            content
        }
    }
}

/// A list held at its bottom as its content changes size
/// (`.defaultScrollAnchor(.bottom, for: .sizeChanges)`, or for every role):
/// at the bottom before, at the bottom after. The native List lets rows
/// above the reader that change height (built from their placeholders as
/// the build window moves) push what is on screen up.
struct BottomPin: ViewModifier {
    let on: Bool
    let window: RowWindow
    let proxy: ScrollViewProxy

    struct State: Equatable {
        var height: CGFloat
        var atBottom: Bool
    }

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollGeometryChange(for: State.self) { geometry in
                let bottom = geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom
                return State(height: geometry.contentSize.height, atBottom: geometry.contentOffset.y >= bottom - 2)
            } action: { old, new in
                guard on, old.atBottom, !new.atBottom, new.height != old.height,
                      let last = window.keys.last else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
        } else {
            content
        }
    }
}

/// `.scrollEdgeEffectStyle(_:for:)` from the guest ("soft" / "hard" at the
/// top and bottom edges; none: the scroll's own, a plain List's being hard).
struct ScrollEdgeModifier: ViewModifier {
    let top: String?
    let bottom: String?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .scrollEdgeEffectStyle(Self.style(top), for: .top)
                .scrollEdgeEffectStyle(Self.style(bottom), for: .bottom)
        } else {
            content
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    static func style(_ name: String?) -> ScrollEdgeEffectStyle? {
        switch name {
        case "soft": return .soft
        case "hard": return .hard
        default: return nil
        }
    }
}

/// A list's rows on screen and what was last reported of them; the report
/// waits for a pause in the rows' coming and going.
final class RowWindow {
    var shown: Set<Int> = []
    var reported = ""
    /// Rows' keys, by the `.id` each had when last built.
    var targets: [String: String] = [:]
    /// The rows' keys as of the list's last body.
    var keys: [String] = []
    /// Built rows' content heights, by key, and their running total.
    private var heights: [String: CGFloat] = [:]
    private var heightTotal: CGFloat = 0

    func recordHeight(_ height: CGFloat, for key: String) {
        guard height > 0 else { return }
        heightTotal += height - (heights[key] ?? 0)
        heights[key] = height
    }

    /// What a row not built stands at: its last height, else the average
    /// of the rows measured (44 before any).
    func placeholderHeight(_ key: String) -> CGFloat {
        if let height = heights[key] { return height }
        return heights.isEmpty ? 44 : (heightTotal / CGFloat(heights.count)).rounded()
    }
    private var pending: DispatchWorkItem?

    func schedule(_ report: @escaping () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem(block: report)
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}

/// A native field's text, kept here while the guest's value catches up with
/// what was typed: each keystroke goes to the guest at once, and the guest's
/// value comes back a frame later. Bound to the guest's value alone, the
/// field took an older echo ("s" while "sy" was on screen) and put it back,
/// and keystrokes were lost when typing fast. An echo of a value sent here
/// is taken only once nothing typed after it is outstanding; any other value
/// is the app's own change (a cleared field, a correction) and replaces the
/// text.
struct EchoedText<Content: View>: View {
    let value: String
    let send: (String) -> Void
    @ViewBuilder let content: (Binding<String>) -> Content

    @State private var text = ""
    /// Sent to the guest and not yet seen back, oldest first.
    @State private var outstanding: [String] = []
    /// Typed into since the guest's value was last taken.
    @State private var edited = false
    /// The typing signposts of `outstanding`, in step with it (a box: not
    /// state the view reads).
    @State private var echoes = EchoSignposts()

    var body: some View {
        content(Binding(
            get: { edited ? text : value },
            set: { newValue in
                let input = echoes.began(newValue)
                text = newValue
                edited = true
                outstanding.append(newValue)
                TextEditScope.active = true
                send(newValue)
                TextEditScope.active = false
                os_signpost(.end, log: typingLog, name: "input", signpostID: input)
            }))
            .onChange(of: value) { newValue in
                if let echo = outstanding.firstIndex(of: newValue) {
                    outstanding.removeFirst(echo + 1)
                    // The last is the guest's echo; those before it were
                    // overtaken (the guest took them, but its frame shows
                    // the later value).
                    echoes.ended(count: echo + 1, outcome: .acked)
                    if outstanding.isEmpty { edited = false }
                } else {
                    // The guest's value is none of ours: its own change
                    // replaces the edits not yet seen back.
                    outstanding.removeAll()
                    echoes.ended(count: echoes.pending.count, outcome: .replaced)
                    edited = false
                }
            }
            .onDisappear { echoes.ended(count: echoes.pending.count, outcome: .abandoned) }
    }
}

/// A field whose selection crosses to the guest (`TextField(_:text:selection:)`
/// there): the person's caret and selection go to it as UTF-16 offsets
/// ("start,end", deduplicated), and a selection the app set ("start,end,
/// request") is shown once per request, when the field holds the guest's
/// text of the frame that asked (EchoedText may still show typing the guest
/// hasn't echoed); once the guest's text has moved on, the request is
/// dropped, the person's typing winning over it.
@available(iOS 18.0, macOS 15.0, *)
struct SelectionTextField: View {
    let placeholder: String
    @Binding var text: String
    let vertical: Bool
    let minLines: Int
    let maxLines: Int?
    let request: String?
    let guestText: String
    let report: (String) -> Void

    struct Waiting: Equatable {
        let start: Int, end: Int, request: Int, text: String
    }

    @State private var selection: TextSelection?
    @State private var reported = ""
    @State private var shown = 0
    @State private var waiting: Waiting?

    var body: some View {
        field
            .onAppear { take(request) }
            .onChange(of: request) { _, request in take(request) }
            .onChange(of: text) { _, _ in apply() }
            .onChange(of: guestText) { _, _ in apply() }
            .onChange(of: selection) { _, selection in
                // (A selection of a text the binding doesn't show yet, as
                // EchoedText catches up, waits for the next change.)
                guard let selection, case .selection(let range) = selection.indices,
                      range.upperBound <= text.endIndex else { return }
                let offsets = "\(range.lowerBound.utf16Offset(in: text)),\(range.upperBound.utf16Offset(in: text))"
                guard offsets != reported else { return }
                reported = offsets
                report(offsets)
            }
    }

    @ViewBuilder private var field: some View {
        if vertical, let maxLines {
            TextField(placeholder, text: $text, selection: $selection, axis: .vertical).lineLimit(minLines...max(minLines, maxLines))
        } else if vertical {
            TextField(placeholder, text: $text, selection: $selection, axis: .vertical).lineLimit(minLines...)
        } else {
            TextField(placeholder, text: $text, selection: $selection)
        }
    }

    private func take(_ request: String?) {
        let parts = (request ?? "").split(separator: ",").compactMap { Int($0) }
        guard parts.count == 3, parts[2] > shown, waiting?.request != parts[2] else { return }
        waiting = Waiting(start: parts[0], end: parts[1], request: parts[2], text: guestText)
        apply()
    }

    private func apply() {
        guard let wanted = waiting else { return }
        guard guestText == wanted.text else {
            waiting = nil
            shown = wanted.request
            return
        }
        guard text == wanted.text else { return }
        waiting = nil
        shown = wanted.request
        let units = text.utf16.count
        let start = min(max(0, wanted.start), units), end = min(max(start, wanted.end), units)
        let index = { (offset: Int) in String.Index(utf16Offset: offset, in: text) }
        reported = "\(start),\(end)"
        selection = TextSelection(range: index(start) ..< index(end))
    }
}

/// Set while a text field hands an edit to the guest (EchoedText): the
/// host has already changed the field's text itself, so the frame the edit
/// asks for can wait for this run-loop turn's commit, which draws that text
/// (WasmView's scheduling reads it; other events render as before).
@MainActor package enum TextEditScope {
    package static var active = false
}

/// The typing signposts' log (the wasm host's IsomerTypingSignposts: same
/// subsystem and category).
let typingLog = OSLog(subsystem: "dev.isomer.typing", category: "Typing")

/// A text field's typing signposts (IsomerTypingSignposts lists them). Each
/// edit has an input number, unique in the process, in the message of each
/// of its signposts:
///
///   input "input=N len=L"       the native callback (guest-event inside it,
///                               on the same thread: the event that carried
///                               edit N)
///   local-commit "inputs=N…"    to the end of the CA commit that drew the
///                               field's own text
///   echo "input=N"              to the guest's echo reaching the field; it
///                               ends "input=N acked" (the last of a frame's
///                               edits: the others it ends "overtaken"),
///                               "replaced" (the guest's value was none of
///                               them) or "abandoned" (the field went away)
///   ack-commit "inputs=N…"      from the echo to the end of the CA commit
///                               that drew it
final class EchoSignposts {
    enum Outcome: String { case acked, replaced, abandoned }
    struct Edit { let input: Int; let echo: OSSignpostID }
    var pending: [Edit] = []
    @MainActor static var nextInput = 0

    /// An edit begins: its input and echo signposts; the local commit's.
    @MainActor func began(_ value: String) -> OSSignpostID {
        Self.nextInput += 1
        let number = Self.nextInput
        let input = OSSignpostID(log: typingLog)
        os_signpost(.begin, log: typingLog, name: "input", signpostID: input,
                    "input=%{public}d len=%{public}d", number, value.utf16.count)
        let echo = OSSignpostID(log: typingLog)
        os_signpost(.begin, log: typingLog, name: "echo", signpostID: echo, "input=%{public}d", number)
        pending.append(Edit(input: number, echo: echo))
        TypingCommits.shared.local(number)
        return input
    }

    /// The oldest `count` edits end with `outcome` (when "acked", the last
    /// of them alone; those before it were overtaken).
    @MainActor func ended(count: Int, outcome: Outcome) {
        let done = pending.prefix(count)
        for (index, edit) in done.enumerated() {
            let last = index == done.count - 1
            let how = outcome == .acked && !last ? "overtaken" : outcome.rawValue
            os_signpost(.end, log: typingLog, name: "echo", signpostID: edit.echo,
                        "input=%{public}d %{public}s", edit.input, how)
        }
        if outcome == .acked, let last = done.last { TypingCommits.shared.acked(last.input) }
        pending.removeFirst(min(count, pending.count))
    }
}

/// The `local-commit`, `ack-commit` and `swiftui-commit` signposts: from an
/// edit, from its echo, and from a new tree, to the end of the Core
/// Animation commit that draws it, stamped by one run-loop observer ordered
/// after CA's commit observer (2,000,000) in the same before-waiting pass,
/// as the bench's InteractionSignpost. Each such pass has a number,
/// "commit=N", in all three's end messages: the commit that carried an
/// input, its echo and the frame with it.
@MainActor package final class TypingCommits {
    package static let shared = TypingCommits()
    private var local: (id: OSSignpostID, inputs: [Int])?
    private var acked: (id: OSSignpostID, inputs: [Int])?
    private var tree: (id: OSSignpostID, first: Int, last: Int)?
    private var observing = false
    private var commits = 0

    func local(_ input: Int) {
        if local == nil { local = (begin("local-commit"), []) }
        local!.inputs.append(input)
        observe()
    }

    func acked(_ input: Int) {
        if acked == nil { acked = (begin("ack-commit"), []) }
        acked!.inputs.append(input)
        observe()
    }

    /// A patch (numbered `frame`, as the runtime's tree-delivered and the
    /// model's patch-apply) went onto the tree SwiftUI draws.
    package func tree(_ frame: Int) {
        if tree == nil { tree = (begin("swiftui-commit"), frame, frame) }
        tree!.last = frame
        observe()
    }

    private func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: typingLog)
        os_signpost(.begin, log: typingLog, name: name, signpostID: id)
        return id
    }

    private func observe() {
        guard !observing else { return }
        observing = true
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 2_500_000
        ) { _, _ in
            MainActor.assumeIsolated { TypingCommits.shared.committed() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func committed() {
        observing = false
        commits += 1
        if let local {
            os_signpost(.end, log: typingLog, name: "local-commit", signpostID: local.id,
                        "commit=%{public}d inputs=%{public}s", commits, local.inputs.map(String.init).joined(separator: ","))
        }
        if let acked {
            os_signpost(.end, log: typingLog, name: "ack-commit", signpostID: acked.id,
                        "commit=%{public}d inputs=%{public}s", commits, acked.inputs.map(String.init).joined(separator: ","))
        }
        if let tree {
            os_signpost(.end, log: typingLog, name: "swiftui-commit", signpostID: tree.id,
                        "commit=%{public}d frames=%{public}d-%{public}d", commits, tree.first, tree.last)
        }
        local = nil
        acked = nil
        tree = nil
    }
}

/// The guest's `.safeAreaInset(edge:spacing:)` / `.safeAreaBar(edge:spacing:)`
/// (iOS 26; an inset before).
struct SafeAreaSlot<Inset: View>: ViewModifier {
    let edge: VerticalEdge
    let spacing: CGFloat?
    let bar: Bool
    let inset: Inset

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *), bar {
            content.safeAreaBar(edge: edge, spacing: spacing) { inset }
        } else {
            content.safeAreaInset(edge: edge, spacing: spacing) { inset }
        }
    }
}

/// A built row's height, kept for when it is a placeholder again.
struct RowHeightRecorder: ViewModifier {
    let window: RowWindow
    let key: String

    func body(content: Content) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { window.recordHeight($0, for: key) }
        } else {
            content
        }
    }
}

/// `onScrollGeometryChange` in the guest: the scroll's geometry reported on
/// its `geometry` id ("offsetX,offsetY,contentW,contentH,containerW,
/// containerH,insetTop,insetLeading,insetBottom,insetTrailing"). A change of
/// size goes at once (rows laid out, the keyboard); the offset alone, as the
/// reader scrolls, at most every tenth of a second.
struct ScrollGeometryReporter: ViewModifier {
    let id: String?
    let send: (String, String) -> Void
    @State private var throttle = GeometryThrottle()

    func body(content: Content) -> some View {
        if let id, #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollGeometryChange(for: GeometryReport.self) { geometry in
                GeometryReport(geometry)
            } action: { _, report in
                throttle.offer(report) { send(id, $0.wire) }
            }
        } else {
            content
        }
    }
}

struct GeometryReport: Equatable {
    var offset: CGPoint
    var size: [CGFloat]

    @available(iOS 18.0, macOS 15.0, *)
    init(_ geometry: ScrollGeometry) {
        offset = CGPoint(x: geometry.contentOffset.x.rounded(), y: geometry.contentOffset.y.rounded())
        size = [geometry.contentSize.width, geometry.contentSize.height, geometry.containerSize.width,
                geometry.containerSize.height, geometry.contentInsets.top, geometry.contentInsets.leading,
                geometry.contentInsets.bottom, geometry.contentInsets.trailing].map { $0.rounded() }
    }

    var wire: String {
        ([offset.x, offset.y] + size).map { String(Double($0)) }.joined(separator: ",")
    }
}

final class GeometryThrottle {
    private var lastSize: [CGFloat] = []
    private var pending: GeometryReport?
    private var waiting = false

    func offer(_ report: GeometryReport, send: @escaping (GeometryReport) -> Void) {
        if report.size != lastSize {
            lastSize = report.size
            pending = nil
            send(report)
            return
        }
        pending = report
        guard !waiting else { return }
        waiting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.waiting = false
            if let report = self.pending {
                self.pending = nil
                send(report)
            }
        }
    }
}

private struct IsomerInScrollKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Inside a scroll (a ScrollView, a List), where a geometry reader's
    /// place in the window changes with every frame of a scroll: it reports
    /// its size alone there.
    var isomerInScroll: Bool {
        get { self[IsomerInScrollKey.self] }
        set { self[IsomerInScrollKey.self] = newValue }
    }
}

// MARK: - Popovers

/// The popover layers of this frame, by id (IsomerTreeView's root).
private struct IsoPopoversKey: EnvironmentKey {
    static var defaultValue: [String: PatchedNode] { [:] }
}

extension EnvironmentValues {
    var isoPopovers: [String: PatchedNode] {
        get { self[IsoPopoversKey.self] }
        set { self[IsoPopoversKey.self] = newValue }
    }
}

/// The guest's `.popover(isPresented:attachmentAnchor:arrowEdge:)` on the
/// view it hangs from: SwiftUI's own, its content the popover layer the
/// frame brought, shown while there is one. Dismissed by the system (a tap
/// outside), it tells the guest, which takes the layer away.
struct AnchoredPopover: ViewModifier {
    let id: String
    let send: (String, String) -> Void
    @Environment(\.isoPopovers) private var popovers

    func body(content: Content) -> some View {
        let layer = popovers[id]
        content.popover(
            isPresented: Binding(
                get: { layer != nil },
                set: { if !$0, let dismiss = layer?.flat.dismiss { send(dismiss, "") } }),
            attachmentAnchor: Self.attachment(layer),
            arrowEdge: Self.edge(layer)
        ) {
            if let layer, let inner = layer.children.first {
                NodeView(pnode: inner, send: send)
                    .modifier(CompactAdaptation(spec: Self.param(layer, "compact")))
            }
        }
    }

    static func param(_ layer: PatchedNode?, _ key: String) -> String? {
        layer?.flat.params.first(where: { $0.key == key })?.value
    }

    static func attachment(_ layer: PatchedNode?) -> PopoverAttachmentAnchor {
        guard let spec = param(layer, "attach"), spec.hasPrefix("point:") else { return .rect(.bounds) }
        let parts = spec.dropFirst("point:".count).split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? .point(UnitPoint(x: parts[0], y: parts[1])) : .rect(.bounds)
    }

    static func edge(_ layer: PatchedNode?) -> Edge {
        switch param(layer, "arrowEdge") {
        case "leading": .leading
        case "bottom": .bottom
        case "trailing": .trailing
        default: .top
        }
    }
}

/// `.presentationCompactAdaptation(horizontal:vertical:)` from the guest
/// ("popover,popover"): a popover that stays a popover on a phone.
struct CompactAdaptation: ViewModifier {
    let spec: String?

    func body(content: Content) -> some View {
        #if os(iOS)
        if let spec, #available(iOS 16.4, *) {
            let parts = spec.split(separator: ",").map(String.init)
            content.presentationCompactAdaptation(
                horizontal: Self.adaptation(parts.first),
                vertical: Self.adaptation(parts.count > 1 ? parts[1] : parts.first))
        } else {
            content
        }
        #else
        content
        #endif
    }

    #if os(iOS)
    @available(iOS 16.4, *)
    static func adaptation(_ name: String?) -> PresentationAdaptation {
        switch name {
        case "popover": .popover
        case "sheet": .sheet
        case "fullScreenCover": .fullScreenCover
        case "none": .none
        default: .automatic
        }
    }
    #endif
}
