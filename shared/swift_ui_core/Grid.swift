// `LazyVGrid` / `LazyHGrid` with `GridItem`s: the cells laid out in rows of
// equal-width columns (or columns of equal-height rows) built from the
// existing stack primitives — a fixed number of tracks (`.flexible` /
// `.fixed` items), or `.adaptive(minimum:)` estimated from the canvas.

import Foundation

public struct GridItem: Sendable {
    public enum Size: Sendable {
        case fixed(CGFloat)
        case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity)
        case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity)
    }

    public var size: Size
    public var spacing: CGFloat?
    public var alignment: Alignment?

    public init(_ size: Size = .flexible(), spacing: CGFloat? = nil, alignment: Alignment? = nil) {
        self.size = size
        self.spacing = spacing
        self.alignment = alignment
    }
}

public struct LazyVGrid<Content: View> {
    let columns: [GridItem]
    let alignment: HorizontalAlignment
    let spacing: CGFloat?
    let content: Content

    public init(
        columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil,
        pinnedViews: PinnedScrollableViews = [], @ViewBuilder content: () -> Content
    ) {
        self.columns = columns
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public typealias Body = Never
}

public struct LazyHGrid<Content: View> {
    let rows: [GridItem]
    let alignment: VerticalAlignment
    let spacing: CGFloat?
    let content: Content

    public init(
        rows: [GridItem], alignment: VerticalAlignment = .center, spacing: CGFloat? = nil,
        pinnedViews: PinnedScrollableViews = [], @ViewBuilder content: () -> Content
    ) {
        self.rows = rows
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public typealias Body = Never
}

/// `pinnedViews:` accepted (section headers do not pin here).
public struct PinnedScrollableViews: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let sectionHeaders = PinnedScrollableViews(rawValue: 1)
    public static let sectionFooters = PinnedScrollableViews(rawValue: 2)
}

/// How many tracks a GridItem list yields along `extent` points.
func gridTrackCount(_ items: [GridItem], extent: CGFloat, spacing: CGFloat) -> Int {
    if let first = items.first, items.count == 1, case .adaptive(let minimum, _) = first.size {
        return max(1, Int((extent + spacing) / (max(1, minimum) + spacing)))
    }
    return max(1, items.count)
}

/// Rows (or columns) of cells: each cell fills its track; a fixed track
/// keeps its width.
func gridNode(
    cells: [RenderNode], items: [GridItem], mainAxis: StackAxis, trackSpacing: CGFloat, lineSpacing: CGFloat,
    extent: CGFloat
) -> RenderNode {
    let tracks = gridTrackCount(items, extent: extent, spacing: trackSpacing)
    let lines = RenderNode(kind: .stack(mainAxis))
    lines.stackSpacing = lineSpacing
    lines.expandsWidth = mainAxis == .vertical
    lines.expandsHeight = mainAxis == .horizontal
    var index = 0
    while index < cells.count {
        let line = RenderNode(kind: .stack(mainAxis == .vertical ? .horizontal : .vertical))
        line.stackSpacing = trackSpacing
        line.expandsWidth = mainAxis == .vertical
        line.expandsHeight = mainAxis == .horizontal
        for track in 0..<tracks {
            let cell = RenderNode.box(child: index < cells.count ? cells[index] : nil)
            let item = items.count == tracks ? items[track] : items.first
            if case .fixed(let length)? = item?.size {
                if mainAxis == .vertical { cell.fixedWidth = length } else { cell.fixedHeight = length }
            } else if mainAxis == .vertical {
                cell.expandsWidth = true
            } else {
                cell.expandsHeight = true
            }
            if let alignment = item?.alignment { cell.alignment = alignment }
            line.children.append(cell)
            index += 1
        }
        lines.children.append(line)
    }
    return lines
}

extension LazyVGrid: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var sub = ctx.descend("vgrid")
        let cells = buildChildren(of: content, ctx: &sub)
        let trackSpacing = columns.first?.spacing ?? spacing ?? 8
        return gridNode(
            cells: cells, items: columns, mainAxis: .vertical, trackSpacing: trackSpacing,
            lineSpacing: spacing ?? 8, extent: Runtime.shared.width)
    }
}

extension LazyHGrid: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var sub = ctx.descend("hgrid")
        let cells = buildChildren(of: content, ctx: &sub)
        let trackSpacing = rows.first?.spacing ?? spacing ?? 8
        return gridNode(
            cells: cells, items: rows, mainAxis: .horizontal, trackSpacing: trackSpacing,
            lineSpacing: spacing ?? 8, extent: Runtime.shared.height)
    }
}

/// `Grid`: rows of cells in columns shared by every row — each column as wide
/// as its widest cell, or, when the grid is offered less than that, the
/// columns shrink toward their narrowest (text wraps and its row grows
/// taller), as a browser lays out a table. A line that is not a `GridRow` (a
/// `Divider`) spans all the columns.
public struct Grid<Content: View> {
    let alignment: Alignment
    let horizontalSpacing: CGFloat?
    let verticalSpacing: CGFloat?
    let content: Content

    public init(
        alignment: Alignment = .center, horizontalSpacing: CGFloat? = nil, verticalSpacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.content = content()
    }

    public typealias Body = Never
}

/// One row of a `Grid`: its views are the row's cells, one per column.
public struct GridRow<Content: View> {
    let alignment: VerticalAlignment?
    let content: Content

    public init(alignment: VerticalAlignment? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }

    public typealias Body = Never
}

extension GridRow: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let node = RenderNode(kind: .stack(.horizontal))
        node.isGridRow = true
        if let alignment { node.stackAlignment = Alignment(horizontal: .center, vertical: alignment) }
        node.gridRowAligned = alignment != nil
        var sub = ctx.descend("GR")
        node.children = buildChildren(of: content, ctx: &sub)
        return node
    }
}

extension Grid: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let node = RenderNode(kind: .stack(.vertical))
        node.stackAlignment = alignment
        node.stackSpacing = verticalSpacing
        var sub = ctx.descend("G")
        node.children = buildChildren(of: content, ctx: &sub)
        var columns = 0
        for (index, line) in node.children.enumerated() {
            line.gridLine = index
            guard line.isGridRow else { continue }
            line.stackSpacing = horizontalSpacing
            // Cells align in their column by the grid's alignment; a row's
            // own vertical alignment wins over the grid's.
            line.stackAlignment = Alignment(
                horizontal: alignment.horizontal,
                vertical: line.gridRowAligned ? line.stackAlignment.vertical : alignment.vertical)
            columns = max(columns, line.children.count)
        }
        node.gridColumns = max(1, columns)
        return node
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension LazyVGrid: View {}
extension LazyHGrid: View {}
extension Grid: View {}
extension GridRow: View {}
