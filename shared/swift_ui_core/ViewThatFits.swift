// ViewThatFits: the first of its views whose ideal size fits the space it
// is offered along the axes given, else the last. A box whose children are
// the candidates: the core's layout chooses for the GPU renderer
// (Layout.swift's measureFits); the component renderers measure and choose
// themselves, by the box's "fits" param ("h", "v", "hv"; TreeEncoder).

public struct ViewThatFits<Content: View> {
    let axes: Axis.Set
    let content: Content

    public init(in axes: Axis.Set = [.horizontal, .vertical], @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }

    public typealias Body = Never
}

extension ViewThatFits: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let node = RenderNode(kind: .box)
        node.fitsAxes = axes
        var sub = ctx.descend("Fits")
        node.children = buildChildren(of: content, ctx: &sub)
        return node
    }
}

extension ViewThatFits: View {}
