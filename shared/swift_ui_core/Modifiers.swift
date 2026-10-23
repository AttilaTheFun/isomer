// View modifiers. Each modifier wraps its content in a `.box` render node
// carrying the relevant decoration, or adjusts the inherited environment.

/// Walks single-child wrappers (frame/padding boxes) down to an image node and
/// applies a corner radius to it, so the host rounds/clips the image directly.
/// Push a fixed `.frame` size down to a wrapped image (through box wrappers,
/// like the radius propagation below): element-styled hosts (the React
/// renderer's <img>) size the image itself — percentage sizing against
/// content-sized flex wrappers resolves to the natural size, which is how
/// thumbnails end up at varying widths.
import Foundation

func propagateImageFixedSize(_ node: RenderNode, width: CGFloat?, height: CGFloat?) {
    var current: RenderNode? = node
    while let n = current {
        if case .image = n.kind {
            if n.fixedWidth == nil { n.fixedWidth = width }
            if n.fixedHeight == nil { n.fixedHeight = height }
            return
        }
        if case .box = n.kind, n.children.count == 1 {
            current = n.children.first
        } else {
            return
        }
    }
}

func propagateImageCornerRadius(_ node: RenderNode, _ radius: CGFloat, force: Bool = false) {
    var current: RenderNode? = node
    while let n = current {
        if case .image = n.kind {
            if force || radius > 0 { n.imageCornerRadius = radius }
            return
        }
        if case .box = n.kind, n.children.count == 1 {
            current = n.children.first
        } else {
            return
        }
    }
}

/// An image (through single-child wrappers) fits or fills its frame.
func propagateImageContentMode(_ node: RenderNode, _ mode: ContentMode) {
    var current: RenderNode? = node
    while let n = current {
        if case .image(let source, let isRemote, let resizable, _) = n.kind {
            n.kind = .image(source: source, isRemote: isRemote, resizable: resizable, fit: mode != .fill)
            return
        }
        if case .box = n.kind, n.children.count == 1 {
            current = n.children.first
        } else {
            return
        }
    }
}

/// Push a `.cornerRadius` down to the box that carries the fill: self-drawing
/// renderers draw a node's background with the node's OWN radius (their
/// scissor clips are axis-aligned and can't round), so a radius held only by
/// an enclosing wrapper box would leave the fill square. Walks through
/// single-child wrapper boxes (padding/frame) and rounds each box's own
/// decorations until it reaches the one with a background.
func propagateBackgroundCornerRadius(_ node: RenderNode, _ radius: CGFloat) {
    var current: RenderNode? = node
    while let n = current {
        guard case .box = n.kind else { return }
        if n.cornerRadius == 0 { n.cornerRadius = radius }
        if !n.background.isEmpty { return } // reached the fill carrier
        current = n.children.count == 1 ? n.children.first : nil
    }
}

/// A clip wrapper (`.cornerRadius`/`.clipShape`/`.clipped`) lays out exactly
/// like its content: when the wrapped child (through box wrappers) carries a
/// fixed `.frame`, the wrapper adopts it. Element-styled hosts (the React
/// renderer) otherwise leave the wrapper content-sized and compressible —
/// flexbox squeezes it below the fixed child, and the clip crops the child to
/// a sliver.
func adoptFixedSize(_ box: RenderNode, from inner: RenderNode) {
    var current: RenderNode? = inner
    while let n = current {
        if n.fixedWidth != nil || n.fixedHeight != nil {
            if box.fixedWidth == nil { box.fixedWidth = n.fixedWidth }
            if box.fixedHeight == nil { box.fixedHeight = n.fixedHeight }
            return
        }
        if case .box = n.kind, n.children.count == 1 {
            current = n.children.first
        } else {
            return
        }
    }
}

/// The building block behind most modifiers: builds `child`, then hands the
/// node to `configure`. SPI for `SwiftUIExtensions` (and other modules that
/// extend the framework): `import SwiftUI`.
package struct _ModifiedView {
    let child: any View
    let descend: String
    /// Run while the tree is built, on the main actor (it builds child views).
    let configure: @MainActor (RenderNode, inout BuildContext) -> RenderNode
    /// The configuration only shapes the node (no runtime state read or
    /// registered): subtrees holding it can be reused (Reuse.swift).
    let pure: Bool

    package init(child: any View, descend: String, pure: Bool = false, configure: @escaping @MainActor (RenderNode, inout BuildContext) -> RenderNode) {
        self.child = child
        self.descend = descend
        self.pure = pure
        self.configure = configure
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension _ModifiedView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var sub = ctx.descend(descend)
        let inner = buildNode(view: child, ctx: &sub)
        var outer = ctx
        let node = configure(inner, &outer)
        // Changed in place: made again on the node a view built alone builds
        // (InPlace.swift).
        if node === inner, let site = inner.rebuildSite {
            site.mutators.append(_NodeMutator(configure: configure, ctx: ctx))
        }
        return node
    }
}

struct _EnvironmentModifier {
    let child: any View
    let descend: String
    let transform: (inout EnvironmentValues) -> Void

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _EnvironmentModifier: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var sub = ctx.descend(descend)
        transform(&sub.env)
        return buildNode(view: child, ctx: &sub)
    }
}

extension View {
    // MARK: Padding

    nonisolated public func padding(_ insets: EdgeInsets) -> some View {
        _ModifiedView(child: self, descend: "padding", pure: true) { inner, _ in
            let box = RenderNode.box(child: inner)
            box.padding = insets
            return box
        }
    }

    nonisolated public func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View {
        let amount = length ?? 16
        return padding(EdgeInsets(
            top: edges.contains(.top) ? amount : 0,
            leading: edges.contains(.leading) ? amount : 0,
            bottom: edges.contains(.bottom) ? amount : 0,
            trailing: edges.contains(.trailing) ? amount : 0
        ))
    }

    nonisolated public func padding(_ length: CGFloat) -> some View {
        padding(.all, length)
    }

    // MARK: Frame

    nonisolated public func frame(
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        alignment: Alignment = .center
    ) -> some View {
        _ModifiedView(child: self, descend: "frame", pure: true) { inner, _ in
            if width != nil || height != nil {
                propagateImageFixedSize(inner, width: width, height: height)
            }
            let box = RenderNode.box(child: inner)
            box.fixedWidth = width
            box.fixedHeight = height
            box.alignment = alignment
            return box
        }
    }

    nonisolated public func frame(
        minWidth: CGFloat? = nil,
        idealWidth: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        minHeight: CGFloat? = nil,
        idealHeight: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        alignment: Alignment = .center
    ) -> some View {
        _ModifiedView(child: self, descend: "flexframe", pure: true) { inner, _ in
            let box = RenderNode.box(child: inner)
            box.minWidth = minWidth
            box.minHeight = minHeight
            if let maxWidth {
                if maxWidth == .infinity {
                    box.expandsWidth = true
                } else {
                    box.maxWidth = maxWidth
                }
            }
            if let maxHeight {
                if maxHeight == .infinity {
                    box.expandsHeight = true
                } else {
                    box.maxHeight = maxHeight
                }
            }
            box.alignment = alignment
            return box
        }
    }

    // MARK: Decoration

    @_disfavoredOverload
    nonisolated public func background<Background: View>(_ background: Background, alignment: Alignment = .center) -> some View {
        _ModifiedView(child: self, descend: "bg", pure: true) { inner, ctx in
            let box = RenderNode.box(child: inner)
            var sub = ctx.descend("bg-content")
            sub.env.containerAlignment = ContainerAlignment(alignment, layer: true)
            box.background = buildChildren(of: background, ctx: &sub)
            box.backgroundAlignment = alignment
            return box
        }
    }

    nonisolated public func background<Background: View>(
        alignment: Alignment = .center,
        @ViewBuilder content: () -> Background
    ) -> some View {
        background(content(), alignment: alignment)
    }

    /// A background of `style` (`.background(.red)`, `.background(.thinMaterial)`).
    /// Edges are not tracked: the background fills the view's box.
    nonisolated public func background<S: ShapeStyle>(_ style: S, ignoresSafeAreaEdges edges: Edge.Set = .all) -> some View {
        _ModifiedView(child: self, descend: "bg", pure: true) { inner, ctx in
            let box = RenderNode.box(child: inner)
            var sub = ctx.descend("bg-content")
            box.background = buildChildren(of: _styleView(style), ctx: &sub)
            return box
        }
    }

    /// `.aspectRatio(_:contentMode:)`: keeps the view at `ratio`
    /// (width/height) — fitting inside its proposal or filling it. A nil
    /// ratio is accepted (the view's own ideal ratio is not tracked here).
    nonisolated public func aspectRatio(_ ratio: CGFloat? = nil, contentMode: ContentMode) -> some View {
        _ModifiedView(child: self, descend: "aspect", pure: true) { inner, _ in
            guard let ratio, ratio > 0 else {
                // No ratio: an image keeps its own and fits or fills its
                // frame (`.resizable().scaledToFit()`).
                propagateImageContentMode(inner, contentMode)
                return inner
            }
            let box = RenderNode.box(child: inner)
            box.aspectRatio = ratio
            box.aspectFill = contentMode == .fill
            box.expandsWidth = true
            return box
        }
    }

    nonisolated public func aspectRatio(_ size: CGSize, contentMode: ContentMode) -> some View {
        aspectRatio(size.height > 0 ? size.width / size.height : nil, contentMode: contentMode)
    }

    nonisolated public func scaledToFit() -> some View {
        aspectRatio(nil, contentMode: .fit)
    }

    nonisolated public func scaledToFill() -> some View {
        aspectRatio(nil, contentMode: .fill)
    }

    /// `.scrollDismissesKeyboard`: how scrolling in this subtree dismisses
    /// the soft keyboard (hosts: `.immediately` / `.interactively` blur the
    /// focused field as a scroll starts; `.never` keeps it; `.automatic` is
    /// the host's default).
    nonisolated public func scrollDismissesKeyboard(_ mode: ScrollDismissesKeyboardMode) -> some View {
        _EnvironmentModifier(child: self, descend: "dismisskb") { env in env.scrollDismissesKeyboard = mode.name }
    }

    /// `.scrollDisabled`: scroll views in this subtree don't scroll. As in
    /// SwiftUI, a subtree disabled by an ancestor stays disabled
    /// (`.scrollDisabled(false)` under it changes nothing).
    nonisolated public func scrollDisabled(_ disabled: Bool) -> some View {
        _EnvironmentModifier(child: self, descend: "scrolldisabled") { env in
            if disabled { env._isScrollEnabled = false }
        }
    }

    /// `.scrollBounceBehavior`: whether scroll views in this subtree bounce
    /// at their edges when their content fits (`.basedOnSize` bounces only
    /// content that scrolls). Hosts whose scroll views don't overscroll
    /// content that fits already behave as `.basedOnSize`.
    nonisolated public func scrollBounceBehavior(_ behavior: ScrollBounceBehavior, axes: Axis.Set = [.vertical]) -> some View {
        _EnvironmentModifier(child: self, descend: "bounce") { env in
            let axisNames = (axes.contains(.vertical) ? "v" : "") + (axes.contains(.horizontal) ? "h" : "")
            env.scrollBounceBehavior = behavior.name + ":" + axisNames
        }
    }

    /// `.inspectorColumnWidth`: the inspector pane's width, applied to the
    /// pane's content (Apple's shape).
    nonisolated public func inspectorColumnWidth(_ width: CGFloat) -> some View {
        _ModifiedView(child: self, descend: "inspectorwidth") { inner, _ in
            Runtime.shared.inspectorWidthHint = Double(width)
            return inner
        }
    }

    nonisolated public func inspectorColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil) -> some View {
        inspectorColumnWidth(ideal)
    }

    /// `.toolbar(removing: .sidebarToggle)`: the enclosing split view keeps
    /// no sidebar collapse control (the sidebar stays put); `.title`
    /// accepted. Apply it to the sidebar column's content, as on Apple.
    nonisolated public func toolbar(removing kind: ToolbarDefaultItemKind?) -> some View {
        _ModifiedView(child: self, descend: "toolbarremoving", pure: true) { inner, _ in
            if kind?.kind == .sidebarToggle {
                Runtime.shared.registerFrameEffect {
                    if Runtime.shared.splitColumnBuilding == "sidebar" { Runtime.shared.sidebarToggleRemoved = true }
                }
            }
            return inner
        }
    }

    /// `.navigationSplitViewStyle`: accepted; hosts keep their column layout.
    /// `.navigationSplitViewStyle`: how a split view shares its width out
    /// (param "style" on the split, for hosts that have the styles).
    nonisolated public func navigationSplitViewStyle<S: NavigationSplitViewStyle>(_ style: S) -> some View {
        _ModifiedView(child: self, descend: "splitstyle", pure: true) { inner, _ in
            if case .hostView(var spec) = inner.kind, spec.kind == "navsplit" {
                spec.params["style"] = styleName(style, otherwise: "automatic")
                inner.kind = .hostView(spec)
            }
            return inner
        }
    }

    /// `.onSubmit`: runs when a text field in this subtree submits (Return;
    /// in a multi-line field Enter submits and Shift/Option+Enter inserts a
    /// newline, the Messages-composer shape).
    nonisolated public func onSubmit(of triggers: SubmitTriggers = .text, _ action: @escaping () -> Void) -> some View {
        _EnvironmentModifier(child: self, descend: "submit") { env in env.onSubmit = action }
    }

    /// `.submitLabel`: the keyboard's return-key label (accepted; hosts keep
    /// their default key).
    nonisolated public func submitLabel(_ label: SubmitLabel) -> some View { self }

    /// `.tint`: the accent color for the controls in this subtree (buttons,
    /// toggles, sliders, progress, links); nil restores the system accent.
    nonisolated public func tint(_ color: Color?) -> some View {
        // The subtree reads the tint from the environment (core controls);
        // the node carries it for component hosts.
        let tinted = _EnvironmentModifier(child: self, descend: "tintenv") { env in env.tint = color }
        return _ModifiedView(child: tinted, descend: "tint", pure: true) { inner, _ in
            inner.tint = color
            return inner
        }
    }

    // MARK: Accessibility

    /// `.accessibilityLabel`: what assistive tech reads for this view (and
    /// what UI tests find it by). Set on the view's own node, so a Button
    /// keeps a single accessibility element. Apple's shape: the accessibility
    /// modifiers return `ModifiedContent<Self, AccessibilityAttachmentModifier>`.
    nonisolated public func accessibilityLabel<S: StringProtocol>(_ label: S) -> ModifiedContent<Self, AccessibilityAttachmentModifier> {
        let label = String(label)
        return modifier(AccessibilityAttachmentModifier { $0.accessibilityLabel = label })
    }

    nonisolated public func accessibilityHint<S: StringProtocol>(_ hint: S) -> ModifiedContent<Self, AccessibilityAttachmentModifier> {
        let hint = String(hint)
        return modifier(AccessibilityAttachmentModifier { $0.accessibilityHint = hint })
    }

    nonisolated public func accessibilityValue<S: StringProtocol>(_ value: S) -> ModifiedContent<Self, AccessibilityAttachmentModifier> {
        let value = String(value)
        return modifier(AccessibilityAttachmentModifier { $0.accessibilityValue = value })
    }

    nonisolated public func accessibilityIdentifier(_ identifier: String) -> ModifiedContent<Self, AccessibilityAttachmentModifier> {
        modifier(AccessibilityAttachmentModifier { $0.accessibilityIdentifier = identifier })
    }

    /// Makes this view one accessibility element: its children's labels
    /// merged into it (`.combine`), replaced by its own (`.ignore`), or kept
    /// as children of a container (`.contain`).
    nonisolated public func accessibilityElement(children: AccessibilityChildBehavior = .ignore) -> some View {
        _ModifiedView(child: self, descend: "a11y", pure: true) { inner, _ in
            inner.accessibilityChildren = children.name
            return inner
        }
    }

    nonisolated public func accessibilityHidden(_ hidden: Bool) -> ModifiedContent<Self, AccessibilityAttachmentModifier> {
        modifier(AccessibilityAttachmentModifier { $0.accessibilityHidden = hidden })
    }

    /// `.accessibilityAddTraits` / `.accessibilityRemoveTraits`: accepted for
    /// source compatibility; hosts derive traits from the native element.
    nonisolated public func accessibilityAddTraits(_ traits: AccessibilityTraits) -> ModifiedContent<Self, AccessibilityAttachmentModifier> {
        modifier(AccessibilityAttachmentModifier { _ in })
    }

    nonisolated public func accessibilityRemoveTraits(_ traits: AccessibilityTraits) -> ModifiedContent<Self, AccessibilityAttachmentModifier> {
        modifier(AccessibilityAttachmentModifier { _ in })
    }

    /// `.ignoresSafeArea()`: lets this view extend under the host's safe
    /// areas (status bar, home indicator, a navigation bar). The regions and
    /// edges are accepted for source compatibility; hosts extend all edges.
    nonisolated public func ignoresSafeArea(_ regions: SafeAreaRegions = .all, edges: Edge.Set = .all) -> some View {
        _ModifiedView(child: self, descend: "safearea", pure: true) { inner, ctx in
            let box = RenderNode.box(child: inner)
            box.ignoresSafeArea = true
            box.expandsWidth = true
            box.expandsHeight = true
            return box
        }
    }

    /// The pre-iOS 14 spelling.
    nonisolated public func edgesIgnoringSafeArea(_ edges: Edge.Set) -> some View {
        ignoresSafeArea(.all, edges: edges)
    }

    nonisolated public func overlay<Overlay: View>(_ overlay: Overlay, alignment: Alignment = .center) -> some View {
        _ModifiedView(child: self, descend: "overlay", pure: true) { inner, ctx in
            let box = RenderNode.box(child: inner)
            var sub = ctx.descend("overlay-content")
            sub.env.containerAlignment = ContainerAlignment(alignment, layer: true)
            box.overlay = buildChildren(of: overlay, ctx: &sub)
            box.overlayAlignment = alignment
            return box
        }
    }

    nonisolated public func overlay<Overlay: View>(
        alignment: Alignment = .center,
        @ViewBuilder content: () -> Overlay
    ) -> some View {
        overlay(content(), alignment: alignment)
    }

    nonisolated public func cornerRadius(_ radius: CGFloat, antialiased: Bool = true) -> some View {
        _ModifiedView(child: self, descend: "radius", pure: true, configure: _roundCorners(radius))
    }

    /// `.clipShape`: a rounded rect rounds the view's corners (a circle or a
    /// capsule fully, the avatar idiom); any other shape clips to the view's
    /// bounds.
    nonisolated public func clipShape<S: Shape>(_ shape: S, style: FillStyle = FillStyle()) -> some View {
        switch shape.shapeKind {
        case .roundedRectangle(let radius):
            return _ModifiedView(child: self, descend: "radius", pure: true, configure: _roundCorners(radius))
        case .circle, .capsule:
            return _ModifiedView(child: self, descend: "radius", pure: true, configure: _roundCorners(9999))
        default:
            return _ModifiedView(child: self, descend: "clipped", pure: true, configure: _clipToBounds)
        }
    }

    /// Clips content to its bounds. For an image this means cropping any
    /// aspect-fill overflow to the frame (the common `.scaledToFill().frame()`
    /// → `.clipped()` idiom).
    nonisolated public func clipped(antialiased: Bool = false) -> some View {
        _ModifiedView(child: self, descend: "clipped", pure: true, configure: _clipToBounds)
    }
}

/// `.cornerRadius`'s node change.
func _roundCorners(_ radius: CGFloat) -> @MainActor (RenderNode, inout BuildContext) -> RenderNode {
    { inner, _ in
        // If this rounds an image (through `.frame`/padding wrappers), round
        // and clip the image itself — host scissor clips can't round.
        propagateImageCornerRadius(inner, radius)
        // Likewise push the radius down to the background-carrying box so
        // self-drawing renderers round the fill itself (the classic
        // `.background(color).cornerRadius(r)` button).
        propagateBackgroundCornerRadius(inner, radius)
        let box = RenderNode.box(child: inner)
        box.cornerRadius = radius
        adoptFixedSize(box, from: inner)
        return box
    }
}

/// `.clipped()`'s node change.
@MainActor func _clipToBounds(_ inner: RenderNode, _ ctx: inout BuildContext) -> RenderNode {
    // Component hosts clip the box (param "clip"); an image inside
    // also crops itself for the self-drawing path.
    inner.clipsContent = true
    propagateImageCornerRadius(inner, 0, force: true)
    let box = RenderNode.box(child: inner)
    adoptFixedSize(box, from: inner)
    return box
}

/// A style as a view to draw behind or in something: a colour as itself,
/// any other style as a rectangle filled with it.
func _styleView<S: ShapeStyle>(_ style: S) -> any View {
    if let color = style as? Color { return color }
    return Rectangle().fill(style)
}

extension View {
    nonisolated public func border<S: ShapeStyle>(_ content: S, width: CGFloat = 1) -> some View {
        overlay(_ShapeView(kind: .rectangle, fill: nil, stroke: (resolveStyleColor(content), width)))
    }

    /// Drops a soft shadow behind the view's frame (rounded to any enclosing
    /// `.cornerRadius`). The reimplementation shadows the frame silhouette
    /// rather than the exact content alpha — accurate for cards/containers.
    nonisolated public func shadow(
        color: Color = Color(white: 0, opacity: 0.33),
        radius: CGFloat = 10,
        x: CGFloat = 0,
        y: CGFloat = 0
    ) -> some View {
        _ModifiedView(child: self, descend: "shadow", pure: true) { inner, _ in
            let box = RenderNode.box(child: inner)
            box.shadow = ShadowSpec(color: color, radius: radius, x: x, y: y)
            // Round the shadow to the content's silhouette: its own corner
            // radius, or the shape it draws / is filled with (a Circle
            // background must cast a round shadow, not a square one). Circles
            // and capsules use a fully-rounded sentinel; renderers clamp it
            // to half the resolved size.
            box.cornerRadius = inner.cornerRadius
            if box.cornerRadius == 0 {
                var silhouette: ShapeKind?
                if case .shape(let shape, _, _) = inner.kind {
                    silhouette = shape
                } else if case .gradient(let shape, _) = inner.kind {
                    silhouette = shape
                } else if let background = inner.background.first {
                    if case .shape(let shape, _, _) = background.kind {
                        silhouette = shape
                    } else if case .gradient(let shape, _) = background.kind {
                        silhouette = shape
                    }
                }
                switch silhouette {
                case .circle, .capsule: box.cornerRadius = 9999
                case .roundedRectangle(let r): box.cornerRadius = r
                case .rectangle, .path, nil: break
                }
            }
            return box
        }
    }

    // MARK: Environment

    nonisolated public func foregroundColor(_ color: Color?) -> some View {
        _EnvironmentModifier(child: self, descend: "fg") { env in
            if let color {
                env.foregroundColor = color
                env.foregroundColorSet = true
            }
        }
    }

    /// The one form, as SwiftUI's: a colour, or a hierarchical level —
    /// `.foregroundStyle(.primary)` is the level, not `Color.primary` (a
    /// concrete Color overload would capture it), so it follows the
    /// foreground in effect.
    nonisolated public func foregroundStyle(_ style: some ShapeStyle) -> some View {
        // A hierarchical level is a level of the foreground in effect, as
        // SwiftUI's: `.primary` under `.foregroundColor(.green)` is green,
        // `.secondary` green at its opacity; with none set, the system's
        // label colours.
        let unwrapped: any ShapeStyle = (style as? AnyShapeStyle)?.base ?? style
        return _EnvironmentModifier(child: self, descend: "fg") { env in
            env.foregroundColor = styleColor(unwrapped, foreground: env.foregroundColorSet ? env.foregroundColor : nil)
                ?? resolveStyleColor(unwrapped)
            env.foregroundColorSet = true
        }
    }

    /// Two styles: a symbol's primary layer (its glyph) and secondary layer
    /// (the badge a `.fill` symbol draws it on); other content takes the first.
    nonisolated public func foregroundStyle<S1: ShapeStyle, S2: ShapeStyle>(_ primary: S1, _ secondary: S2) -> some View {
        _EnvironmentModifier(child: self, descend: "fg2") { env in
            env.foregroundColor = resolveStyleColor(primary)
            env.foregroundSecondary = resolveStyleColor(secondary)
            env.foregroundColorSet = true
        }
    }

    nonisolated public func font(_ font: Font?) -> some View {
        _EnvironmentModifier(child: self, descend: "font") { env in
            if let font {
                env.font = font
                env.fontSet = true
            }
        }
    }


    /// `.fontWeight(_:)` on any view: the text in it at this weight.
    nonisolated public func fontWeight(_ weight: Font.Weight?) -> some View {
        _EnvironmentModifier(child: self, descend: "fontweight") { env in
            guard let weight else { return }
            env.font = env.font.weight(weight)
            env.fontSet = true
        }
    }

    /// `.italic(_:)` on any view.
    nonisolated public func italic(_ isActive: Bool = true) -> some View {
        _EnvironmentModifier(child: self, descend: "italic") { env in
            guard isActive else { return }
            env.font = env.font.italic()
            env.fontSet = true
        }
    }

    /// `.monospaced(_:)` on any view.
    nonisolated public func monospaced(_ isActive: Bool = true) -> some View {
        _EnvironmentModifier(child: self, descend: "monospaced") { env in
            guard isActive else { return }
            env.font = env.font.monospaced()
            env.fontSet = true
        }
    }

    /// `.fontDesign(_:)`: the text in it in this design (serif, rounded,
    /// monospaced; nil keeps it).
    nonisolated public func fontDesign(_ design: Font.Design?) -> some View {
        _EnvironmentModifier(child: self, descend: "fontdesign") { env in
            guard let design else { return }
            var font = env.font
            font.design = design
            env.font = font
            env.fontSet = true
        }
    }

    /// Bold when `isActive`; otherwise unchanged.
    nonisolated public func bold(_ isActive: Bool = true) -> some View {
        _EnvironmentModifier(child: self, descend: "bold") { env in
            if isActive {
                env.font = env.font.weight(.bold)
                env.fontSet = true
            }
        }
    }

    /// The view keeps its place in the layout but is not drawn, and is
    /// left out of accessibility (SwiftUI's `hidden()`): measuring views
    /// rely on that.
    nonisolated public func hidden() -> some View {
        opacity(0).accessibilityHidden(true)
    }

    /// Sets the color scheme for this view and its descendants.
    nonisolated public func preferredColorScheme(_ colorScheme: ColorScheme?) -> some View {
        _EnvironmentModifier(child: self, descend: "scheme") { env in
            if let colorScheme {
                env.colorScheme = colorScheme
                Runtime.shared.colorScheme = colorScheme
                Runtime.shared.preferredColorScheme = colorScheme
                Runtime.shared.markBuildVolatile()
            }
        }
    }

    nonisolated public func opacity(_ value: Double) -> some View {
        _AnimatableEnvModifier(child: self, descend: "opacity") { env, path, now in
            let resolved = Runtime.shared.animator.value(
                key: path + "#opacity", target: value, animation: env.animation, now: now)
            env.opacity *= resolved
        }
    }

    // MARK: Interaction

    nonisolated public func onTapGesture(count: Int = 1, perform action: @escaping () -> Void) -> some View {
        _ModifiedView(child: self, descend: "tap", pure: true) { inner, ctx in
            let box = RenderNode.box(child: inner)
            if ctx.env.isEnabled {
                box.tapAction = action
                box.tapCount = max(1, count)
            }
            return box
        }
    }

    nonisolated public func disabled(_ disabled: Bool) -> some View {
        _EnvironmentModifier(child: self, descend: "disabled") { env in
            if disabled {
                env.isEnabled = false
                env.opacity *= 0.45
            }
        }
    }

    /// Caps descendant text at `limit` lines (clipping the overflow on the
    /// reimplementation; native truncation with an ellipsis on Apple).
    nonisolated public func lineLimit(_ limit: Int?) -> some View {
        _EnvironmentModifier(child: self, descend: "linelimit") { env in
            env.lineLimit = limit
        }
    }

    /// The ranged form (`.lineLimit(1...6)`): caps descendant text at the
    /// upper bound, and bounds a growing `TextField(_:text:axis: .vertical)`
    /// between the two (it starts at `lowerBound` lines and grows to
    /// `upperBound` before scrolling internally).
    nonisolated public func lineLimit(_ range: ClosedRange<Int>) -> some View {
        _EnvironmentModifier(child: self, descend: "linelimit") { env in
            env.lineLimit = range.upperBound
            env.lineRange = range
        }
    }

    /// At least `limit.lowerBound` lines, as many more as the text needs
    /// (`.lineLimit(1...)`: a growing field with no ceiling). The hosts take
    /// a field's bounds as numbers of lines; a thousand stands for none.
    nonisolated public func lineLimit(_ limit: PartialRangeFrom<Int>) -> some View {
        _EnvironmentModifier(child: self, descend: "linelimit") { env in
            env.lineLimit = nil
            env.lineRange = limit.lowerBound ... max(limit.lowerBound, 1000)
        }
    }

    /// At most `limit.upperBound` lines (`.lineLimit(...3)`).
    nonisolated public func lineLimit(_ limit: PartialRangeThrough<Int>) -> some View {
        lineLimit(1 ... max(1, limit.upperBound))
    }

    /// Parity no-op: on the reimplementation every view's full layout
    /// bounds are already hit-testable (DOM elements and the runtime's
    /// rect-based tap regions don't distinguish transparent pixels), which
    /// is exactly what `.contentShape(Rectangle())` requests. Provided so
    /// shared SwiftUI source compiles unchanged; non-rectangular content
    /// shapes are approximated by their bounds.
    nonisolated public func contentShape<S: Shape>(_ shape: S, eoFill: Bool = false) -> some View {
        self
    }

    /// Fixes the view at its ideal size on the given axes, whatever its
    /// parent proposes (a `Text` measured in a background, a label that
    /// must not wrap). Only the horizontal axis needs a node: the layout
    /// never compresses text below its natural height (a flex column
    /// doesn't shrink children), so the common
    /// `.fixedSize(horizontal: false, vertical: true)` already holds and
    /// stays the view as it was. The wrapper carries `fixed` ("h" or "hv")
    /// for every renderer: the Swift layout proposes nothing on those axes,
    /// the React renderer sizes the box at `max-content`, Compose wraps
    /// the content unbounded.
    nonisolated public func fixedSize(horizontal: Bool = true, vertical: Bool = true) -> some View {
        _ModifiedView(child: self, descend: "fixed", pure: true) { inner, _ in
            // Either axis: a vertical-only one (text as tall as its lines
            // beside something, in a list cell) matters to native hosts.
            guard horizontal || vertical else { return inner }
            let box = RenderNode.box(child: inner)
            box.fixedSize = (horizontal ? "h" : "") + (vertical ? "v" : "")
            return box
        }
    }

    /// Where scroll content rests by default (`.defaultScrollAnchor(.bottom)`
    /// for a chat log): the enclosing scroll starts at the anchor and stays
    /// pinned there while the user is at that edge and content grows. Walks
    /// through wrapper boxes to the first scroll node (like the image-frame
    /// propagation above).
    // Apple shipped this in iOS 17 / macOS 14, so it is spelled that way
    // here too: on Apple the rules must be Apple's, whichever renderer is
    // drawing. The attribute names only Apple's platforms, so the `*` case
    // covers the ones we implement ourselves and it costs them nothing.
    #if !ISOMER_COMPILED_FEATURE
    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
    #endif
    nonisolated public func defaultScrollAnchor(_ anchor: UnitPoint?) -> some View {
        _ModifiedView(child: self, descend: "scrollanchor", pure: true) { inner, _ in
            var current: RenderNode? = inner
            while let n = current {
                if case .scroll = n.kind {
                    n.scrollAnchor = anchor
                    n.scrollAlignment = anchor
                    n.noteListAnchor()
                    break
                }
                if case .box = n.kind, n.children.count == 1 {
                    current = n.children.first
                } else {
                    break
                }
            }
            return inner
        }
    }

    /// `.defaultScrollAnchor(_:for:)`: the anchor for one role — where the
    /// scroll starts (`.initialOffset`), where it stays as its content or
    /// size changes (`.sizeChanges`), or how content smaller than it sits
    /// (`.alignment`). The first two are the anchor hosts already keep (open
    /// at it, and hold it as content grows while the reader is there).
    #if !ISOMER_COMPILED_FEATURE
    @available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, *)
    #endif
    nonisolated public func defaultScrollAnchor(_ anchor: UnitPoint?, for role: ScrollAnchorRole) -> some View {
        _ModifiedView(child: self, descend: "scrollanchor-\(role.name)", pure: true) { inner, _ in
            var current: RenderNode? = inner
            while let n = current {
                if case .scroll = n.kind {
                    if role == .alignment {
                        n.scrollAlignment = anchor
                    } else {
                        n.scrollAnchor = anchor
                        // Which role it is, for hosts with the roles (param
                        // anchorFor): opening at it, or holding it.
                        n.scrollAnchorRole = role.name
                        n.noteListAnchor()
                    }
                    break
                }
                if case .box = n.kind, n.children.count == 1 {
                    current = n.children.first
                } else {
                    break
                }
            }
            return inner
        }
    }

    // MARK: Lifecycle

    /// `.task { }`: starts an async task when the view appears and cancels
    /// it when the view disappears, as SwiftUI does. The closure runs as the
    /// actor it is written in (a view's: the main actor).
    nonisolated public func task(name: String? = nil, priority: TaskPriority = .userInitiated,
                                 file: String = #fileID, line: Int = #line,
                     @_inheritActorContext _ action: @escaping @Sendable () async -> Void) -> some View {
        _TaskModifier(child: self, id: nil, priority: priority, action: action)
    }

    /// `.task(id:)`: the same, and when `id` changes the running task is
    /// cancelled and a new one started.
    nonisolated public func task<T: Equatable>(id: T, name: String? = nil, priority: TaskPriority = .userInitiated,
                                               file: String = #fileID, line: Int = #line,
                                   @_inheritActorContext _ action: @escaping @Sendable () async -> Void) -> some View {
        _TaskModifier(child: self, id: AnyEquatableBox(id), priority: priority, action: action)
    }

    nonisolated public func onAppear(perform action: (() -> Void)? = nil) -> some View {
        _ModifiedView(child: self, descend: "appear", pure: true) { inner, ctx in
            let box = RenderNode.box(child: inner)
            box.identityPath = ctx.path + "/appear"
            box.onAppear = action
            return box
        }
    }

    nonisolated public func onDisappear(perform action: (() -> Void)? = nil) -> some View {
        _ModifiedView(child: self, descend: "disappear", pure: true) { inner, ctx in
            let box = RenderNode.box(child: inner)
            box.identityPath = ctx.path + "/disappear"
            box.onDisappear = action
            return box
        }
    }

    /// Runs `action` after the frame whenever `value` differs from its value
    /// in the previous build (not on first appearance, nor when the view
    /// comes back after leaving the tree), matching SwiftUI.
    nonisolated public func onChange<V: Equatable>(
        of value: V,
        perform action: @escaping (V) -> Void
    ) -> some View {
        _OnChangeView(child: self, value: value, initial: false) { _, new in action(new) }
    }

    /// The iOS 17 form: `action` gets the old value and the new one. With
    /// `initial`, it also runs on first appearance (old and new the same).
    nonisolated public func onChange<V: Equatable>(
        of value: V,
        initial: Bool = false,
        _ action: @escaping (_ oldValue: V, _ newValue: V) -> Void
    ) -> some View {
        _OnChangeView(child: self, value: value, initial: initial, action: action)
    }

    /// `action` with what `transform` reads of the view's geometry, when the
    /// view first has a size and whenever that changes: a reader behind the
    /// view, the size it is given the view's.
    nonisolated public func onGeometryChange<T: Equatable & Sendable>(
        for type: T.Type, of transform: @escaping @Sendable (GeometryProxy) -> T, action: @escaping (T) -> Void
    ) -> some View {
        background(GeometryReader { proxy in
            Color.clear.onChange(of: transform(proxy), initial: true) { _, new in action(new) }
        })
    }

    /// The same, with the value before the change.
    nonisolated public func onGeometryChange<T: Equatable & Sendable>(
        for type: T.Type, of transform: @escaping @Sendable (GeometryProxy) -> T, action: @escaping (T, T) -> Void
    ) -> some View {
        background(GeometryReader { proxy in
            Color.clear.onChange(of: transform(proxy), initial: true) { old, new in action(old, new) }
        })
    }

    /// The iOS 17 form that takes no values.
    nonisolated public func onChange<V: Equatable>(
        of value: V,
        initial: Bool = false,
        _ action: @escaping () -> Void
    ) -> some View {
        _OnChangeView(child: self, value: value, initial: initial) { _, _ in action() }
    }
}

struct _OnChangeView<Child: View, V: Equatable> {
    let child: Child
    let value: V
    let initial: Bool
    let action: (V, V) -> Void

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _OnChangeView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let key = ctx.path + "/onchange"
        let previous = Runtime.shared.onChangeStore[key] as? V
        Runtime.shared.onChangeStore[key] = value
        let action = self.action
        let value = self.value
        // Queued during a frame's build, an action runs in the build passes
        // that follow. Queued as the tree is handed to the renderer (a
        // GeometryReader's content, built as it is encoded), after those
        // passes, it runs with the frame's deferred actions, which then ask
        // for a frame (an `.onGeometryChange` measured once never acted).
        // Outside any frame, a frame is asked for.
        let runtime = Runtime.shared
        var pending: (() -> Void)?
        if let previous {
            if previous != value { pending = { action(previous, value) } }
        } else if initial {
            pending = { action(value, value) }
        }
        if let pending {
            if runtime.buildingFrame {
                runtime.onChangeActions.append(pending)
            } else if runtime.renderingTree {
                runtime.deferredActions.append(pending)
            } else {
                runtime.onChangeActions.append(pending)
                runtime.requestFrame()
            }
        }
        var sub = ctx.descend("onchange")
        let inner = buildNode(view: child, ctx: &sub)
        // The value kept is the view's while it is in the tree: its key rides
        // on the child's node, and when that node leaves (a screen popped, a
        // branch no longer taken) the lifecycle that runs onDisappear lets the
        // value go, so a view put back in the same place starts afresh, as
        // SwiftUI's does, rather than reporting a change against the value its
        // predecessor last saw. On the child's node, not a box of its own:
        // a level per `.onChange` deepened the full example app's recursion
        // past the interpreter's stack (WAMR's, the engine before WasmKit).
        // Made again on the node a partial frame builds in place
        // (InPlace.swift), as a modifier's in-place change is.
        let keep: @MainActor (RenderNode, inout BuildContext) -> RenderNode = { node, _ in
            if !node.onChangeKeys.contains(key) { node.onChangeKeys.append(key) }
            return node
        }
        var outer = ctx
        let node = keep(inner, &outer)
        if let site = inner.rebuildSite {
            site.mutators.append(_NodeMutator(configure: keep, ctx: ctx))
        }
        return node
    }
}

// MARK: - Advisory no-ops (API compatibility)

extension View {
    /// How the view comes and goes when it is inserted or removed under an
    /// animation. Accepted so shared source needs no `#if`; the view comes
    /// and goes at once (the hosts do not animate insertions yet). Missing,
    /// a `.transition` in a long modifier chain left the type checker trying
    /// every overload of the rest until it gave up on the expression.
    nonisolated public func transition(_ transition: AnyTransition) -> some View { self }
}

/// SwiftUI's transitions, as values `.transition(_:)` takes.
public struct AnyTransition: Sendable {
    let name: String

    public static let identity = AnyTransition(name: "identity")
    public static let opacity = AnyTransition(name: "opacity")
    public static let scale = AnyTransition(name: "scale")
    public static let slide = AnyTransition(name: "slide")
    public static func scale(scale: CGFloat, anchor: UnitPoint = .center) -> AnyTransition { AnyTransition(name: "scale") }
    public static func move(edge: Edge) -> AnyTransition { AnyTransition(name: "move") }
    public static func push(from edge: Edge) -> AnyTransition { AnyTransition(name: "push") }
    public static func offset(_ offset: CGSize) -> AnyTransition { AnyTransition(name: "offset") }
    public static func offset(x: CGFloat = 0, y: CGFloat = 0) -> AnyTransition { AnyTransition(name: "offset") }
    public static func asymmetric(insertion: AnyTransition, removal: AnyTransition) -> AnyTransition {
        AnyTransition(name: insertion.name + "|" + removal.name)
    }
    public func combined(with other: AnyTransition) -> AnyTransition { AnyTransition(name: name + "+" + other.name) }
    public func animation(_ animation: Animation?) -> AnyTransition { self }
}

/// `Transaction` / `withTransaction`: the reimplementation's animation
/// system keys off `withAnimation`; a transaction with `disablesAnimations`
/// runs the body without an implicit animation, otherwise with its animation.
public struct Transaction: Sendable {
    public var animation: Animation?
    public var disablesAnimations = false

    public init(animation: Animation? = nil) {
        self.animation = animation
    }
}

public func withTransaction<Result>(_ transaction: Transaction, _ body: () throws -> Result) rethrows -> Result {
    let previous = Runtime.shared.transactionAnimation
    Runtime.shared.transactionAnimation = transaction.disablesAnimations ? nil : transaction.animation
    defer {
        Runtime.shared.requestFrame()
        Runtime.shared.transactionAnimation = previous
    }
    return try body()
}


/// `.scrollBounceBehavior` behaviors.
public struct ScrollBounceBehavior: Sendable {
    let name: String
    public static let automatic = ScrollBounceBehavior(name: "automatic")
    public static let always = ScrollBounceBehavior(name: "always")
    public static let basedOnSize = ScrollBounceBehavior(name: "basedOnSize")
}

/// `.scrollDismissesKeyboard` modes.
public struct ScrollDismissesKeyboardMode: Sendable {
    let name: String
    public static let automatic = ScrollDismissesKeyboardMode(name: "automatic")
    public static let immediately = ScrollDismissesKeyboardMode(name: "immediately")
    public static let interactively = ScrollDismissesKeyboardMode(name: "interactively")
    public static let never = ScrollDismissesKeyboardMode(name: "never")
}

/// What submits (`.onSubmit(of:)`): a text field's Return, a search.
public struct SubmitTriggers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let text = SubmitTriggers(rawValue: 1 << 0)
    public static let search = SubmitTriggers(rawValue: 1 << 1)
}

/// SwiftUI's return-key labels (accepted for source compatibility).
public struct SubmitLabel: Sendable {
    enum Kind: Hashable, Sendable { case done, go, send, join, route, search, `return`, next, `continue` }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    public static let done = SubmitLabel(.done)
    public static let go = SubmitLabel(.go)
    public static let send = SubmitLabel(.send)
    public static let join = SubmitLabel(.join)
    public static let route = SubmitLabel(.route)
    public static let search = SubmitLabel(.search)
    public static let `return` = SubmitLabel(.`return`)
    public static let next = SubmitLabel(.next)
    public static let `continue` = SubmitLabel(.`continue`)
}

/// SwiftUI's accessibility traits (accepted for source compatibility).
public struct AccessibilityTraits: SetAlgebra, Sendable {
    var bits: UInt64
    init(bits: UInt64) { self.bits = bits }
    public init() { bits = 0 }
    public static let isButton = AccessibilityTraits(bits: 1 << 0)
    public static let isHeader = AccessibilityTraits(bits: 1 << 1)
    public static let isSelected = AccessibilityTraits(bits: 1 << 2)
    public static let isLink = AccessibilityTraits(bits: 1 << 3)
    public static let isSearchField = AccessibilityTraits(bits: 1 << 4)
    public static let isImage = AccessibilityTraits(bits: 1 << 5)
    public static let playsSound = AccessibilityTraits(bits: 1 << 6)
    public static let isKeyboardKey = AccessibilityTraits(bits: 1 << 7)
    public static let isStaticText = AccessibilityTraits(bits: 1 << 8)
    public static let isSummaryElement = AccessibilityTraits(bits: 1 << 9)
    public static let updatesFrequently = AccessibilityTraits(bits: 1 << 10)
    public static let startsMediaSession = AccessibilityTraits(bits: 1 << 11)
    public static let allowsDirectInteraction = AccessibilityTraits(bits: 1 << 12)
    public static let causesPageTurn = AccessibilityTraits(bits: 1 << 13)
    public static let isModal = AccessibilityTraits(bits: 1 << 14)
    public static let isToggle = AccessibilityTraits(bits: 1 << 15)
    public static let isTabBar = AccessibilityTraits(bits: 1 << 16)

    public typealias Element = AccessibilityTraits
    public typealias ArrayLiteralElement = AccessibilityTraits
    public static func == (a: AccessibilityTraits, b: AccessibilityTraits) -> Bool { a.bits == b.bits }
    public func contains(_ member: AccessibilityTraits) -> Bool { bits & member.bits == member.bits }
    public func union(_ other: AccessibilityTraits) -> AccessibilityTraits { AccessibilityTraits(bits: bits | other.bits) }
    public func intersection(_ other: AccessibilityTraits) -> AccessibilityTraits { AccessibilityTraits(bits: bits & other.bits) }
    public func symmetricDifference(_ other: AccessibilityTraits) -> AccessibilityTraits { AccessibilityTraits(bits: bits ^ other.bits) }
    @discardableResult
    public mutating func insert(_ newMember: AccessibilityTraits) -> (inserted: Bool, memberAfterInsert: AccessibilityTraits) {
        let inserted = !contains(newMember)
        bits |= newMember.bits
        return (inserted, newMember)
    }
    @discardableResult
    public mutating func remove(_ member: AccessibilityTraits) -> AccessibilityTraits? {
        guard contains(member) else { return nil }
        bits &= ~member.bits
        return member
    }
    @discardableResult
    public mutating func update(with newMember: AccessibilityTraits) -> AccessibilityTraits? {
        let present = contains(newMember)
        bits |= newMember.bits
        return present ? newMember : nil
    }
    public mutating func formUnion(_ other: AccessibilityTraits) { bits |= other.bits }
    public mutating func formIntersection(_ other: AccessibilityTraits) { bits &= other.bits }
    public mutating func formSymmetricDifference(_ other: AccessibilityTraits) { bits ^= other.bits }
}

/// The safe-area regions `.ignoresSafeArea` can opt out of (accepted for
/// source compatibility; hosts treat every region alike).
public struct SafeAreaRegions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let container = SafeAreaRegions(rawValue: 1)
    public static let keyboard = SafeAreaRegions(rawValue: 2)
    public static let all: SafeAreaRegions = [.container, .keyboard]
}

/// Type-erased equality for `.task(id:)`.
struct AnyEquatableBox: Equatable {
    let value: Any
    let equals: (Any) -> Bool
    init<T: Equatable>(_ value: T) {
        self.value = value
        self.equals = { ($0 as? T) == value }
    }
    static func == (lhs: AnyEquatableBox, rhs: AnyEquatableBox) -> Bool { lhs.equals(rhs.value) }
}

struct _TaskModifier<Child: View> {
    let child: Child
    let id: AnyEquatableBox?
    let priority: TaskPriority
    let action: @Sendable () async -> Void

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _TaskModifier: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        // The task belongs to the view at this build path: started when it
        // appears, cancelled when it disappears, and — with an id — cancelled
        // and started again when the id changes while the view is up.
        let key = ctx.path + "#task"
        var sub = ctx.descend("task")
        let box = RenderNode.box(child: buildNode(view: child, ctx: &sub))
        box.identityPath = ctx.path + "/task"
        let action = self.action
        let priority = self.priority
        box.onAppear = { Runtime.shared.startViewTask(key: key, priority: priority, action) }
        box.onDisappear = {
            Runtime.shared.endViewTask(key: key)
            Runtime.shared.taskIDs[key] = nil
        }
        if let id {
            let previous = Runtime.shared.taskIDs[key]
            Runtime.shared.taskIDs[key] = id
            if let previous, previous != id {
                Runtime.shared.deferredActions.append { Runtime.shared.startViewTask(key: key, priority: priority, action) }
            }
        }
        return box
    }
}

/// How an accessibility element treats its children (`.accessibilityElement`).
public struct AccessibilityChildBehavior: Hashable, Sendable {
    let name: String
    public static let ignore = AccessibilityChildBehavior(name: "ignore")
    public static let contain = AccessibilityChildBehavior(name: "contain")
    public static let combine = AccessibilityChildBehavior(name: "combine")
}

/// What a `.defaultScrollAnchor(_:for:)` anchor is for.
public struct ScrollAnchorRole: Hashable, Sendable {
    let name: String
    public static let initialOffset = ScrollAnchorRole(name: "initialOffset")
    public static let sizeChanges = ScrollAnchorRole(name: "sizeChanges")
    public static let alignment = ScrollAnchorRole(name: "alignment")
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension _ModifiedView: View {}
extension _EnvironmentModifier: View {}
extension _OnChangeView: View {}
extension _TaskModifier: View {}


/// Apple's: what the accessibility modifiers attach to a view. Isomer's sets
/// the attributes on the view's own node (a Button keeps one element).
public struct AccessibilityAttachmentModifier {
    let attach: @MainActor (RenderNode) -> Void

    nonisolated init(_ attach: @escaping @MainActor (RenderNode) -> Void) {
        self.attach = attach
    }
}

extension AccessibilityAttachmentModifier: ViewModifier {
    public func body(content: Content) -> some View {
        let attach = attach
        return _ModifiedView(child: content, descend: "a11y", pure: true) { inner, _ in
            attach(inner)
            return inner
        }
    }
}
