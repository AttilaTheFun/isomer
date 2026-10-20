public struct VStack<Content: View> {
    let alignment: HorizontalAlignment
    let spacing: CGFloat?
    let content: Content

    public init(
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public typealias Body = Never
}

extension VStack: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let node = RenderNode(kind: .stack(.vertical))
        node.stackAlignment = Alignment(horizontal: alignment, vertical: .center)
        node.stackSpacing = spacing
        var sub = ctx.descend("V")
        sub.env.containerAlignment = ContainerAlignment(horizontal: alignment)
        node.children = buildChildren(of: content, ctx: &sub)
        for child in node.children {
            if case .spacer = child.kind {
                child.pinRebuildSite()
                child.spacerAxis = .vertical
            }
        }
        return node
    }
}

public struct HStack<Content: View> {
    let alignment: VerticalAlignment
    let spacing: CGFloat?
    let content: Content

    public init(
        alignment: VerticalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public typealias Body = Never
}

extension HStack: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let node = RenderNode(kind: .stack(.horizontal))
        node.stackAlignment = Alignment(horizontal: .center, vertical: alignment)
        node.stackSpacing = spacing
        var sub = ctx.descend("H")
        sub.env.containerAlignment = ContainerAlignment(vertical: alignment)
        node.children = buildChildren(of: content, ctx: &sub)
        for child in node.children {
            if case .spacer = child.kind {
                child.pinRebuildSite()
                child.spacerAxis = .horizontal
            }
        }
        return node
    }
}

public struct ZStack<Content: View> {
    let alignment: Alignment
    let content: Content

    public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }

    public typealias Body = Never
}

extension ZStack: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let node = RenderNode(kind: .stack(.depth))
        node.stackAlignment = alignment
        var sub = ctx.descend("Z")
        sub.env.containerAlignment = ContainerAlignment(alignment)
        node.children = buildChildren(of: content, ctx: &sub)
        return node
    }
}

public struct Spacer {
    let minLength: CGFloat?

    public init(minLength: CGFloat? = nil) {
        self.minLength = minLength
    }

    public typealias Body = Never
}

extension Spacer: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        RenderNode(kind: .spacer(minLength))
    }
}

public struct Divider {
    public init() {}

    public typealias Body = Never
}

extension Divider: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let node = RenderNode(kind: .divider)
        node.color = Color(white: 0, opacity: 0.15)
        return node
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension VStack: View {}
extension HStack: View {}
extension ZStack: View {}
extension Spacer: View {}
extension Divider: View {}
