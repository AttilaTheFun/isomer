// `.alignmentGuide`: a view's own value for one of its alignment guides,
// which counts where its container aligns its children by that guide (an
// overlay's or a background's alignment, a ZStack's, a VStack's horizontal
// one, an HStack's vertical one: BuildContext's `containerAlignment`). The
// view is measured as it is laid out (`onGeometryChange`) and moved by the
// guide's default value less the one computed, hidden until its size is
// known; its container keeps its own size, as an overlay's does in SwiftUI
// (in a stack SwiftUI's would grow to hold the moved view). AgentUI's
// composer floats its suggestions above its box so: `.overlay(alignment:
// .topLeading) { menu.alignmentGuide(.top) { $0[.bottom] + gap } }`.

/// How a container aligns the views built in it, along each axis it aligns
/// on (nil where it doesn't: a VStack's vertical).
struct ContainerAlignment: Equatable {
    var horizontal: HorizontalAlignment?
    var vertical: VerticalAlignment?
    /// An overlay's or a background's layer, which a view its guide moves
    /// out of floats above the screen's chrome (`floatsAboveChrome`).
    var layer = false

    init(horizontal: HorizontalAlignment? = nil, vertical: VerticalAlignment? = nil) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    init(_ alignment: Alignment, layer: Bool = false) {
        self.init(horizontal: alignment.horizontal, vertical: alignment.vertical)
        self.layer = layer
    }
}

/// A view's size, and where its alignment guides are in it.
public struct ViewDimensions {
    public let width: CGFloat
    public let height: CGFloat

    init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    public subscript(guide: HorizontalAlignment) -> CGFloat {
        switch guide.kind {
        case .leading: return 0
        case .center: return width / 2
        case .trailing: return width
        }
    }

    public subscript(guide: VerticalAlignment) -> CGFloat {
        switch guide.kind {
        case .top: return 0
        case .center: return height / 2
        case .bottom: return height
        }
    }

    /// None set explicitly: what a view computes is not recorded here.
    public subscript(explicit guide: HorizontalAlignment) -> CGFloat? { nil }

    public subscript(explicit guide: VerticalAlignment) -> CGFloat? { nil }
}

extension View {
    nonisolated public func alignmentGuide(_ g: HorizontalAlignment, computeValue: @escaping @Sendable (ViewDimensions) -> CGFloat) -> some View {
        _AlignmentGuide(content: self, horizontal: g, vertical: nil, compute: computeValue)
    }

    nonisolated public func alignmentGuide(_ g: VerticalAlignment, computeValue: @escaping @Sendable (ViewDimensions) -> CGFloat) -> some View {
        _AlignmentGuide(content: self, horizontal: nil, vertical: g, compute: computeValue)
    }
}

struct _AlignmentGuide<Content: View> {
    let content: Content
    let horizontal: HorizontalAlignment?
    let vertical: VerticalAlignment?
    let compute: @Sendable (ViewDimensions) -> CGFloat

    typealias Body = Never
}

extension _AlignmentGuide: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let container = ctx.env.containerAlignment
        let counts = (horizontal != nil && horizontal == container.horizontal)
            || (vertical != nil && vertical == container.vertical)
        var sub = ctx.descend("guide")
        // What is inside the view is aligned by its own containers.
        sub.env.containerAlignment = ContainerAlignment()
        guard counts else { return buildNode(view: content, ctx: &sub) }
        let node = buildNode(view: _GuideOffset(content: content, horizontal: horizontal, vertical: vertical, compute: compute), ctx: &sub)
        // Moved by its guide within an overlay's or a background's layer
        // (out of the view it decorates, as a menu floated above a box):
        // drawn above the screen's bars, which a host draws over its content.
        if container.layer { node.floatsAboveChrome = true }
        return node
    }
}

extension _AlignmentGuide: View {}

/// The view moved by its guide's default value less the one computed, once
/// its size is known.
struct _GuideOffset<Content: View>: View {
    let content: Content
    let horizontal: HorizontalAlignment?
    let vertical: VerticalAlignment?
    let compute: @Sendable (ViewDimensions) -> CGFloat
    @State private var size: CGSize?

    var body: some View {
        let shift = size.map { size -> CGFloat in
            let dimensions = ViewDimensions(width: size.width, height: size.height)
            if let horizontal { return dimensions[horizontal] - compute(dimensions) }
            if let vertical { return dimensions[vertical] - compute(dimensions) }
            return 0
        } ?? 0
        content
            // Its own size only: not the canvas's stand-in a reader is built
            // with before its host has measured it.
            .background(GeometryReader { proxy in
                Color.clear.onChange(of: proxy.measured ? proxy.size : nil, initial: true) { _, new in
                    if let new { size = new }
                }
            })
            .offset(x: horizontal != nil ? shift : 0, y: vertical != nil ? shift : 0)
            .opacity(size == nil ? 0 : 1)
    }
}
