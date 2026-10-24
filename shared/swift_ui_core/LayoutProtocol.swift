// Layouts as values, as SwiftUI spells them: `HStackLayout`,
// `VStackLayout` and `ZStackLayout`, and `AnyLayout` to switch between them
// (`let layout = wide ? AnyLayout(HStackLayout()) : AnyLayout(VStackLayout())`)
// with the children kept: their identity doesn't change with the layout,
// so their state stays. The stack layouts are Isomer's stacks; the hosts
// lay them out. The `Layout` protocol is SwiftUI's, but a layout of an
// app's own is drawn as a vertical stack here: Isomer measures and places
// on each host, not through `sizeThatFits` and `placeSubviews` (its
// subviews' proxies measure nothing).

import Foundation

/// A proposed size: nil in a dimension for the view's ideal size there.
public struct ProposedViewSize: Equatable, Sendable {
    public var width: CGFloat?
    public var height: CGFloat?

    public init(width: CGFloat?, height: CGFloat?) {
        self.width = width
        self.height = height
    }

    public init(_ size: CGSize) {
        self.init(width: size.width, height: size.height)
    }

    public static let zero = ProposedViewSize(width: 0, height: 0)
    public static let unspecified = ProposedViewSize(width: nil, height: nil)
    public static let infinity = ProposedViewSize(width: .infinity, height: .infinity)

    public func replacingUnspecifiedDimensions(by size: CGSize = CGSize(width: 10, height: 10)) -> CGSize {
        CGSize(width: width ?? size.width, height: height ?? size.height)
    }
}

/// The space a view wants around it.
public struct ViewSpacing: Sendable {
    let amount: CGFloat

    public static let zero = ViewSpacing(amount: 0)

    /// The platform's standard spacing.
    public init() { amount = 8 }

    init(amount: CGFloat) { self.amount = amount }

    public mutating func formUnion(_ other: ViewSpacing, edges: Edge.Set = .all) {
        self = union(other, edges: edges)
    }

    public func union(_ other: ViewSpacing, edges: Edge.Set = .all) -> ViewSpacing {
        ViewSpacing(amount: max(amount, other.amount))
    }

    public func distance(to next: ViewSpacing, along axis: Axis) -> CGFloat {
        max(amount, next.amount)
    }
}

/// What a layout says about itself.
public struct LayoutProperties: Sendable {
    public init() {}
    /// The axis it stacks along, for views that adapt to it (a Divider).
    public var stackOrientation: Axis?
}

/// A child, as a layout sees it.
public struct LayoutSubview: Equatable {
    let index: Int

    public var priority: Double { 0 }

    public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    public func dimensions(in proposal: ProposedViewSize) -> ViewDimensions {
        let size = sizeThatFits(proposal)
        return ViewDimensions(width: size.width, height: size.height)
    }

    public var spacing: ViewSpacing { ViewSpacing() }

    public func place(at position: CGPoint, anchor: UnitPoint = .topLeading, proposal: ProposedViewSize) {}
}

/// A layout's children.
public struct LayoutSubviews: Equatable, RandomAccessCollection, Sendable {
    public typealias SubSequence = LayoutSubviews
    public typealias Element = LayoutSubview
    public typealias Index = Int
    public typealias Indices = Range<Int>
    public typealias Iterator = IndexingIterator<LayoutSubviews>

    let indices_: [Int]
    public var layoutDirection: LayoutDirection

    public var startIndex: Int { 0 }
    public var endIndex: Int { indices_.count }

    public subscript(index: Int) -> LayoutSubview { LayoutSubview(index: indices_[index]) }

    public subscript(bounds: Range<Int>) -> LayoutSubviews {
        LayoutSubviews(indices_: Array(indices_[bounds]), layoutDirection: layoutDirection)
    }

    public subscript<S: Sequence>(indices: S) -> LayoutSubviews where S.Element == Int {
        LayoutSubviews(indices_: indices.map { indices_[$0] }, layoutDirection: layoutDirection)
    }
}

/// A way of sizing and placing views.
@preconcurrency public protocol Layout: Sendable {
    static var layoutProperties: LayoutProperties { get }
    associatedtype Cache = Void
    typealias Subviews = LayoutSubviews
    func makeCache(subviews: Self.Subviews) -> Self.Cache
    func updateCache(_ cache: inout Self.Cache, subviews: Self.Subviews)
    func spacing(subviews: Self.Subviews, cache: inout Self.Cache) -> ViewSpacing
    func sizeThatFits(proposal: ProposedViewSize, subviews: Self.Subviews, cache: inout Self.Cache) -> CGSize
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Self.Subviews, cache: inout Self.Cache)
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Self.Subviews, cache: inout Self.Cache) -> CGFloat?
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Self.Subviews, cache: inout Self.Cache) -> CGFloat?
}

extension Layout {
    public static var layoutProperties: LayoutProperties { LayoutProperties() }

    public func updateCache(_ cache: inout Self.Cache, subviews: Self.Subviews) {
        cache = makeCache(subviews: subviews)
    }

    public func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                                  subviews: Self.Subviews, cache: inout Self.Cache) -> CGFloat? { nil }

    public func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                                  subviews: Self.Subviews, cache: inout Self.Cache) -> CGFloat? { nil }

    public func spacing(subviews: Self.Subviews, cache: inout Self.Cache) -> ViewSpacing {
        subviews.reduce(ViewSpacing.zero) { $0.union($1.spacing) }
    }

    /// The views `content` makes, laid out by this layout.
    public func callAsFunction<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        _LayoutView(layout: self, content: content())
    }
}

extension Layout where Self.Cache == () {
    public func makeCache(subviews: Self.Subviews) -> Self.Cache { () }
}

/// Views side by side.
public struct HStackLayout: Layout {
    public var alignment: VerticalAlignment
    public var spacing: CGFloat?

    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil) {
        self.alignment = alignment
        self.spacing = spacing
    }

    public typealias Cache = Void

    public static var layoutProperties: LayoutProperties {
        var properties = LayoutProperties()
        properties.stackOrientation = .horizontal
        return properties
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let gaps = CGFloat(max(0, sizes.count - 1)) * (spacing ?? 8)
        return CGSize(width: sizes.reduce(0) { $0 + $1.width } + gaps, height: sizes.map(\.height).max() ?? 0)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(size))
            x += size.width + (spacing ?? 8)
        }
    }
}

/// Views one above another.
public struct VStackLayout: Layout {
    public var alignment: HorizontalAlignment
    public var spacing: CGFloat?

    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil) {
        self.alignment = alignment
        self.spacing = spacing
    }

    public typealias Cache = Void

    public static var layoutProperties: LayoutProperties {
        var properties = LayoutProperties()
        properties.stackOrientation = .vertical
        return properties
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let gaps = CGFloat(max(0, sizes.count - 1)) * (spacing ?? 8)
        return CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.reduce(0) { $0 + $1.height } + gaps)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(size))
            y += size.height + (spacing ?? 8)
        }
    }
}

/// Views one over another.
public struct ZStackLayout: Layout {
    public var alignment: Alignment

    public init(alignment: Alignment = .center) {
        self.alignment = alignment
    }

    public typealias Cache = Void

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).max() ?? 0)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

/// Any layout, so that one place in a view can switch between layouts and
/// keep its children.
public struct AnyLayout: Layout, Sendable {
    let layout: any Layout

    public init<L: Layout>(_ layout: L) {
        self.layout = (layout as? AnyLayout)?.layout ?? layout
    }

    public struct Cache: Sendable {}

    public func makeCache(subviews: Subviews) -> Cache { Cache() }

    public func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    public func spacing(subviews: Subviews, cache: inout Cache) -> ViewSpacing {
        subviews.reduce(ViewSpacing.zero) { $0.union($1.spacing) }
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        func measure<L: Layout>(_ layout: L) -> CGSize {
            var inner = layout.makeCache(subviews: subviews)
            return layout.sizeThatFits(proposal: proposal, subviews: subviews, cache: &inner)
        }
        return measure(layout)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        func place<L: Layout>(_ layout: L) {
            var inner = layout.makeCache(subviews: subviews)
            layout.placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &inner)
        }
        place(layout)
    }

    public func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                                  subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }

    public func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                                  subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
}

/// A layout's views, built as the stack the layout is. Their identity is
/// the layout's place, not its kind, so switching layouts keeps them.
struct _LayoutView<L: Layout, Content: View> {
    let layout: L
    let content: Content
    typealias Body = Never
}

extension _LayoutView: View {}

/// Each custom layout's type, logged once.
@MainActor private var announcedLayouts: Set<String> = []

extension _LayoutView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let chosen: any Layout = (layout as? AnyLayout)?.layout ?? layout
        let node: RenderNode
        var sub = ctx.descend("layout")
        let axis: Axis?
        switch chosen {
        case let stack as HStackLayout:
            node = RenderNode(kind: .stack(.horizontal))
            node.stackAlignment = Alignment(horizontal: .center, vertical: stack.alignment)
            node.stackSpacing = stack.spacing
            sub.env.containerAlignment = ContainerAlignment(vertical: stack.alignment)
            axis = .horizontal
        case let stack as ZStackLayout:
            node = RenderNode(kind: .stack(.depth))
            node.stackAlignment = stack.alignment
            sub.env.containerAlignment = ContainerAlignment(stack.alignment)
            axis = nil
        default:
            let stack = chosen as? VStackLayout ?? VStackLayout()
            if !(chosen is VStackLayout) {
                let name = String(describing: type(of: chosen))
                if announcedLayouts.insert(name).inserted {
                    print("Isomer: the custom Layout \(name) is drawn as a VStack (custom layouts aren't run yet)")
                }
            }
            node = RenderNode(kind: .stack(.vertical))
            node.stackAlignment = Alignment(horizontal: stack.alignment, vertical: .center)
            node.stackSpacing = stack.spacing
            sub.env.containerAlignment = ContainerAlignment(horizontal: stack.alignment)
            axis = .vertical
        }
        node.children = buildChildren(of: content, ctx: &sub)
        if let axis {
            for child in node.children {
                if case .spacer = child.kind {
                    child.pinRebuildSite()
                    child.spacerAxis = axis == .horizontal ? .horizontal : .vertical
                }
            }
        }
        return node
    }
}
