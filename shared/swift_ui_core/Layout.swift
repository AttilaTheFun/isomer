// Layout: a simplified SwiftUI-style negotiation. Parents propose sizes,
// children report what they need; flexible children (spacers, expanding
// frames, bare shapes) absorb leftover space in stacks.

import Foundation
internal import IsomerSwiftUI

struct LayoutContext {
    let measureText: (String, Font, CGFloat?) -> CGSize
    let imageInfo: (String, Bool) -> ImageStatus
    /// Axis of the enclosing stack (affects Divider / Spacer orientation).
    var parentAxis: StackAxis = .vertical
}

func isFlexible(_ node: RenderNode, along axis: StackAxis) -> Bool {
    if axis == .horizontal {
        if node.fixedWidth != nil { return false }
        if node.expandsWidth { return true }
    } else {
        if node.fixedHeight != nil { return false }
        if node.expandsHeight { return true }
    }
    switch node.kind {
    case .spacer:
        return node.spacerAxis == nil || node.spacerAxis == axis
    case .divider, .text, .hostView:
        return false
    case .shape, .scroll, .gradient, .geometryReader:
        return true
    case .progress(let value):
        // Determinate bar stretches horizontally; spinner is fixed.
        return value != nil && axis == .horizontal
    case .textField, .slider:
        return axis == .horizontal
    case .image(_, _, let resizable, _):
        return resizable
    case .box:
        // A ViewThatFits is flexible as the candidate it chose (last laid out).
        let shown = node.fitsAxes == nil ? node.children.first
            : node.children.indices.contains(node.fitsChosen) ? node.children[node.fitsChosen] : nil
        return shown.map { isFlexible($0, along: axis) } ?? false
    case .stack:
        return node.children.contains { isFlexible($0, along: axis) }
    }
}

func measure(_ node: RenderNode, proposal: ProposedSize, ctx: LayoutContext) -> CGSize {
    // Size constraints (`.frame(...)`) apply to every node kind.
    var inner = proposal
    // `.fixedSize`: nothing proposed on a fixed axis, so the content takes
    // its ideal size there.
    if let fixed = node.fixedSize {
        if fixed.contains("h") { inner.width = nil }
        if fixed.contains("v") { inner.height = nil }
    }
    if let w = node.fixedWidth { inner.width = w }
    if let h = node.fixedHeight { inner.height = h }
    if let mw = node.maxWidth, let w = inner.width { inner.width = min(w, mw) }
    if let mh = node.maxHeight, let h = inner.height { inner.height = min(h, mh) }
    // `.aspectRatio`: derive the missing dimension from the known one; with
    // both known, the largest box of that ratio inside them (fit) or the
    // smallest covering them (fill).
    var aspectBox: CGSize?
    if let ratio = node.aspectRatio, ratio > 0 {
        switch (inner.width, inner.height) {
        case let (w?, nil): aspectBox = CGSize(width: w, height: w / ratio)
        case let (nil, h?): aspectBox = CGSize(width: h * ratio, height: h)
        case let (w?, h?):
            let byWidth = CGSize(width: w, height: w / ratio)
            let byHeight = CGSize(width: h * ratio, height: h)
            let fits = byWidth.height <= h
            aspectBox = node.aspectFill ? (fits ? byHeight : byWidth) : (fits ? byWidth : byHeight)
        default: break
        }
        if let box = aspectBox { inner.width = box.width; inner.height = box.height }
    }

    var size = measureContent(node, proposal: inner, ctx: ctx)
    if let box = aspectBox { size = box }

    if let w = node.fixedWidth { size.width = w }
    if let h = node.fixedHeight { size.height = h }
    if node.expandsWidth, let pw = proposal.width { size.width = max(size.width, pw) }
    if node.expandsHeight, let ph = proposal.height { size.height = max(size.height, ph) }
    if let minW = node.minWidth { size.width = max(size.width, minW) }
    if let minH = node.minHeight { size.height = max(size.height, minH) }
    if let maxW = node.maxWidth { size.width = min(size.width, maxW) }
    if let maxH = node.maxHeight { size.height = min(size.height, maxH) }
    return size
}

private func measureContent(_ node: RenderNode, proposal: ProposedSize, ctx: LayoutContext) -> CGSize {
    switch node.kind {
    case .text(let string):
        // Half-point of slack on the wrap width: a stack shrinks to a text's
        // measured width and then re-measures the text at exactly that width, so
        // sub-pixel rounding in the host's font metrics (logical⇄device round
        // trips) could wrap a line against its own width. The slack is well
        // below a real wrap's deficit, so genuine wrapping is unaffected.
        let wrap = proposal.width.map { $0 + 0.5 }
        var size = ctx.measureText(string, node.font, wrap)
        // An unbreakable run wider than the wrap width (a long URL, say) makes the
        // host report a width past the proposal; clamp it so one such line can't
        // stretch the whole column past the screen (the glyphs clip instead).
        if let w = wrap { size.width = min(size.width, w) }
        if let limit = node.lineLimit, limit > 0 {
            // Cap to N lines (line height mirrors the hosts' 1.3 factor).
            size.height = min(size.height, CGFloat(limit) * node.font.size * 1.3)
        }
        return size

    case .shape(let kind, _, _), .gradient(let kind, _):
        let width = proposal.width ?? 10
        let height = proposal.height ?? 10
        if case .circle = kind {
            let d = min(width, height)
            return CGSize(width: d, height: d)
        }
        return CGSize(width: width, height: height)

    case .hostView(let spec):
        // Media/web host views (`.frame(height:)`) should fill a proposed
        // height; controls (Picker/Menu) sit in stacks that propose nil along
        // the axis, so they still take their intrinsic height.
        let intrinsic = hostViewIntrinsicSize(spec)
        let fillsHeight = spec.kind == "video" || spec.kind == "webview" || spec.kind == "image"
            || spec.kind == "map" || spec.kind == "metal"
        return CGSize(
            width: proposal.width ?? intrinsic.width,
            height: fillsHeight ? (proposal.height ?? intrinsic.height) : intrinsic.height
        )

    case .spacer(let minLength):
        let m = minLength ?? 0
        if ctx.parentAxis == .horizontal {
            return CGSize(width: max(m, proposal.width ?? 0), height: 0)
        }
        return CGSize(width: 0, height: max(m, proposal.height ?? 0))

    case .divider:
        if ctx.parentAxis == .horizontal {
            return CGSize(width: 1, height: proposal.height ?? 10)
        }
        return CGSize(width: proposal.width ?? 10, height: 1)

    case .box:
        return measureBox(node, proposal: proposal, ctx: ctx)

    case .textField:
        return CGSize(
            width: proposal.width ?? 200,
            height: node.font.size * 1.3 + 14
        )

    case .slider:
        return CGSize(width: proposal.width ?? 180, height: 24)

    case .progress(let value):
        if value != nil {
            return CGSize(width: proposal.width ?? 180, height: 4)
        }
        return CGSize(width: 20, height: 20)

    case .geometryReader:
        // Greedy: fills whatever it is offered.
        return CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)

    case .image(let source, let isRemote, let resizable, _):
        let intrinsic: CGSize
        switch ctx.imageInfo(source, isRemote) {
        case .ready(let size):
            intrinsic = size
        case .loading, .failed:
            intrinsic = CGSize(width: 80, height: 80)
        }
        if resizable {
            return CGSize(
                width: proposal.width ?? intrinsic.width,
                height: proposal.height ?? intrinsic.height
            )
        }
        return intrinsic

    case .scroll(let axis):
        let contentProposal = axis == .vertical
            ? ProposedSize(width: proposal.width, height: nil)
            : ProposedSize(width: nil, height: proposal.height)
        let contentSize = node.children.first.map {
            measure($0, proposal: contentProposal, ctx: ctx)
        } ?? .zero
        node.scrollContentSize = contentSize
        if axis == .vertical {
            return CGSize(
                width: proposal.width ?? contentSize.width,
                height: proposal.height ?? contentSize.height
            )
        }
        return CGSize(
            width: proposal.width ?? contentSize.width,
            height: proposal.height ?? contentSize.height
        )

    case .stack(let axis):
        switch axis {
        case .horizontal, .vertical:
            return measureStack(node, axis: axis, proposal: proposal, ctx: ctx)
        case .depth:
            var size = CGSize.zero
            node.measuredChildSizes = node.children.map { child in
                let childSize = measure(child, proposal: proposal, ctx: ctx)
                size.width = max(size.width, childSize.width)
                size.height = max(size.height, childSize.height)
                return childSize
            }
            return size
        }
    }
}

private func measureBox(_ node: RenderNode, proposal: ProposedSize, ctx: LayoutContext) -> CGSize {
    var inner = proposal
    inner.width = inner.width.map { max(0, $0 - node.padding.horizontal) }
    inner.height = inner.height.map { max(0, $0 - node.padding.vertical) }

    let childSize = node.fitsAxes.map { measureFits(node, axes: $0, proposal: inner, ctx: ctx) }
        ?? node.children.first.map { measure($0, proposal: inner, ctx: ctx) } ?? .zero

    return CGSize(
        width: childSize.width + node.padding.horizontal,
        height: childSize.height + node.padding.vertical
    )
}

/// `ViewThatFits`: the first child whose ideal size along the axes given
/// (measured with nothing proposed along them) fits the proposal, else the
/// last; measured then at the proposal, as the child laid out.
private func measureFits(_ node: RenderNode, axes: Axis.Set, proposal: ProposedSize, ctx: LayoutContext) -> CGSize {
    guard !node.children.isEmpty else { return .zero }
    var chosen = node.children.count - 1
    let ideal = ProposedSize(
        width: axes.contains(.horizontal) ? nil : proposal.width,
        height: axes.contains(.vertical) ? nil : proposal.height)
    for (index, child) in node.children.enumerated().dropLast() {
        let size = measure(child, proposal: ideal, ctx: ctx)
        let fitsWidth = !axes.contains(.horizontal) || proposal.width.map { size.width <= $0 + 0.5 } ?? true
        let fitsHeight = !axes.contains(.vertical) || proposal.height.map { size.height <= $0 + 0.5 } ?? true
        if fitsWidth && fitsHeight {
            chosen = index
            break
        }
    }
    node.fitsChosen = chosen
    return measure(node.children[chosen], proposal: proposal, ctx: ctx)
}

private func measureStack(
    _ node: RenderNode,
    axis: StackAxis,
    proposal: ProposedSize,
    ctx: LayoutContext
) -> CGSize {
    if axis == .vertical, let columns = node.gridColumns {
        return measureGrid(node, columns: columns, proposal: proposal, ctx: ctx)
    }
    var childCtx = ctx
    childCtx.parentAxis = axis
    let spacing = node.stackSpacing ?? 8
    let count = node.children.count
    if count == 0 { return .zero }
    let totalSpacing = spacing * CGFloat(count - 1)

    let axisLength: (CGSize) -> CGFloat = { axis == .horizontal ? $0.width : $0.height }
    let crossLength: (CGSize) -> CGFloat = { axis == .horizontal ? $0.height : $0.width }
    let proposedAxis = axis == .horizontal ? proposal.width : proposal.height
    let proposedCross = axis == .horizontal ? proposal.height : proposal.width

    var sizes = [CGSize](repeating: .zero, count: count)
    var flexibleIndices: [Int] = []
    var rigidTotal: CGFloat = 0

    // For a horizontal stack with a bounded width, hand each rigid child the
    // width still unclaimed (after spacing and earlier children) so wrapping
    // content — a Text column, a label — wraps to fit instead of overflowing,
    // and the stack's height reflects the wrapped result. (A vertical stack
    // already bounds its children's width via `proposedCross`.) When the width
    // is unbounded — e.g. inside a horizontal scroll — children size naturally.
    var remainingAxis = (axis == .horizontal ? proposedAxis : nil)
        .map { max(0, $0 - totalSpacing) }

    for (i, child) in node.children.enumerated() {
        if isFlexible(child, along: axis) {
            flexibleIndices.append(i)
        } else {
            let childProposal = axis == .horizontal
                ? ProposedSize(width: remainingAxis, height: proposedCross)
                : ProposedSize(width: proposedCross, height: nil)
            sizes[i] = measure(child, proposal: childProposal, ctx: childCtx)
            rigidTotal += axisLength(sizes[i])
            if axis == .horizontal, let r = remainingAxis {
                remainingAxis = max(0, r - sizes[i].width)
            }
        }
    }

    if !flexibleIndices.isEmpty {
        if let available = proposedAxis {
            let leftover = max(0, available - rigidTotal - totalSpacing)
            let share = leftover / CGFloat(flexibleIndices.count)
            for i in flexibleIndices {
                let childProposal = axis == .horizontal
                    ? ProposedSize(width: share, height: proposedCross)
                    : ProposedSize(width: proposedCross, height: share)
                sizes[i] = measure(node.children[i], proposal: childProposal, ctx: childCtx)
            }
        } else {
            for i in flexibleIndices {
                let childProposal = axis == .horizontal
                    ? ProposedSize(width: nil, height: proposedCross)
                    : ProposedSize(width: proposedCross, height: nil)
                sizes[i] = measure(node.children[i], proposal: childProposal, ctx: childCtx)
            }
        }
    }

    node.measuredChildSizes = sizes

    var total: CGFloat = totalSpacing
    var cross: CGFloat = 0
    for size in sizes {
        total += axisLength(size)
        cross = max(cross, crossLength(size))
    }

    return axis == .horizontal
        ? CGSize(width: total, height: cross)
        : CGSize(width: cross, height: total)
}

/// Assigns absolute frames. `measure` must have been called with the final
/// proposal first (containers re-measure their children here to be safe).
/// Shifts a placed node and its whole subtree (children + decorations) by a
/// translation — used by `.offset`.
func translateSubtree(_ node: RenderNode, dx: CGFloat, dy: CGFloat) {
    node.frame = CGRect(
        x: node.frame.minX + dx, y: node.frame.minY + dy,
        width: node.frame.width, height: node.frame.height
    )
    for child in node.children { translateSubtree(child, dx: dx, dy: dy) }
    for decoration in node.background { translateSubtree(decoration, dx: dx, dy: dy) }
    for decoration in node.overlay { translateSubtree(decoration, dx: dx, dy: dy) }
}

@MainActor
func place(_ node: RenderNode, in frame: CGRect, ctx: LayoutContext) {
    node.frame = frame

    switch node.kind {
    case .text, .shape, .spacer, .divider, .image, .textField, .slider, .gradient, .hostView, .progress:
        break

    case .geometryReader:
        // Now that our frame is known, build the content and lay it out to fill.
        guard let build = node.geometryBuild else { break }
        let child = build(frame.size, frame.origin)
        node.children = [child]
        // The content was built after the pre-layout expansion pass, so
        // expand any semantic chrome inside it here.
        expandDrawnChrome(node)
        _ = measure(child, proposal: ProposedSize(width: frame.width, height: frame.height), ctx: ctx)
        place(child, in: frame, ctx: ctx)

    case .scroll(let axis):
        guard let content = node.children.first else { break }
        let contentProposal = axis == .vertical
            ? ProposedSize(width: frame.width, height: nil)
            : ProposedSize(width: nil, height: frame.height)
        let contentSize = measure(content, proposal: contentProposal, ctx: ctx)
        node.scrollContentSize = contentSize
        let offset = Runtime.shared.scrollOffset(
            for: node.identityPath ?? "",
            axis: axis,
            content: contentSize,
            viewport: frame.size
        )
        // Edge overscroll rubber-band (driven by the host's native EdgeEffect):
        // shifts the content past the clamped scroll edge and springs back.
        let over = Runtime.shared.overscrollOffsets[node.identityPath ?? ""] ?? 0
        let origin = axis == .vertical
            ? CGPoint(x: frame.minX, y: frame.minY - offset + over)
            : CGPoint(x: frame.minX - offset, y: frame.minY)
        place(content, in: CGRect(
            origin: origin,
            size: CGSize(
                width: max(contentSize.width, axis == .vertical ? frame.width : 0),
                height: max(contentSize.height, axis == .horizontal ? frame.height : 0)
            )
        ), ctx: ctx)

    case .box:
        let content = CGRect(
            x: frame.minX + node.padding.leading,
            y: frame.minY + node.padding.top,
            width: max(0, frame.width - node.padding.horizontal),
            height: max(0, frame.height - node.padding.vertical)
        )
        // A ViewThatFits places the candidate it chose; the rest are not
        // drawn.
        let shown = node.fitsAxes == nil ? node.children.first
            : node.children.indices.contains(node.fitsChosen) ? node.children[node.fitsChosen] : nil
        if let child = shown {
            let childSize = measure(
                child,
                proposal: ProposedSize(width: content.width, height: content.height),
                ctx: ctx
            )
            var rect = alignedRect(size: childSize, container: content, alignment: node.alignment)
            if let x = node.positionX, let y = node.positionY {
                // `.position`: the child's center at (x, y) in this box.
                rect = CGRect(
                    x: frame.minX + x - childSize.width / 2, y: frame.minY + y - childSize.height / 2,
                    width: childSize.width, height: childSize.height)
            }
            place(child, in: rect, ctx: ctx)
        }
        let backgrounds: [(RenderNode, Alignment)] = node.background.map { ($0, node.backgroundAlignment) }
        let overlays: [(RenderNode, Alignment)] = node.overlay.map { ($0, node.overlayAlignment) }
        for (decoration, alignment) in backgrounds + overlays {
            let size = measure(
                decoration,
                proposal: ProposedSize(width: frame.width, height: frame.height),
                ctx: ctx
            )
            let rect = alignedRect(size: size, container: frame, alignment: alignment)
            place(decoration, in: rect, ctx: ctx)
        }
        // `.offset` translates the placed subtree without affecting siblings.
        if node.offsetX != 0 || node.offsetY != 0 {
            translateSubtree(node, dx: node.offsetX, dy: node.offsetY)
        }

    case .stack(let axis):
        switch axis {
        case .depth:
            for child in node.children {
                let size = measure(
                    child,
                    proposal: ProposedSize(width: frame.width, height: frame.height),
                    ctx: ctx
                )
                let rect = alignedRect(size: size, container: frame, alignment: node.stackAlignment)
                place(child, in: rect, ctx: ctx)
            }
        case .horizontal, .vertical:
            placeStack(node, axis: axis, in: frame, ctx: ctx)
        }
    }
}

/// `Grid`: each column as wide as its widest cell when the grid fits the
/// width offered; otherwise every column starts at its narrowest (the width
/// its cells wrap to) and the rest of the width is shared in proportion to
/// how much wider each would like to be — a browser's automatic table layout.
/// Rows are as tall as their tallest cell; lines that are not rows span the
/// columns.
private func measureGrid(_ node: RenderNode, columns: Int, proposal: ProposedSize, ctx: LayoutContext) -> CGSize {
    var cellCtx = ctx
    cellCtx.parentAxis = .horizontal
    let horizontalSpacing = node.children.first(where: { $0.isGridRow })?.stackSpacing ?? 8
    let verticalSpacing = node.stackSpacing ?? 8
    var narrowest = [CGFloat](repeating: 0, count: columns)
    var widest = [CGFloat](repeating: 0, count: columns)
    for row in node.children where row.isGridRow {
        for (column, cell) in row.children.enumerated() where column < columns {
            let natural = measure(cell, proposal: ProposedSize(), ctx: cellCtx).width
            let narrow = narrowestWidth(cell, ctx: cellCtx)
            widest[column] = max(widest[column], natural)
            narrowest[column] = max(narrowest[column], min(narrow, natural))
        }
    }
    let gaps = horizontalSpacing * CGFloat(columns - 1)
    var widths = widest
    let wanted = widest.reduce(0, +)
    if let offered = proposal.width.map({ max(0, $0 - gaps) }), wanted > offered {
        let least = narrowest.reduce(0, +)
        if least >= offered {
            widths = narrowest
        } else {
            let slack = wanted - least
            widths = (0..<columns).map { narrowest[$0] + (widest[$0] - narrowest[$0]) * (offered - least) / slack }
        }
    }
    node.gridColumnWidths = widths
    let gridWidth = widths.reduce(0, +) + gaps
    var sizes: [CGSize] = []
    for line in node.children {
        if line.isGridRow {
            var cellSizes: [CGSize] = []
            for (column, cell) in line.children.enumerated() {
                let width = column < columns ? widths[column] : 0
                cellSizes.append(measure(cell, proposal: ProposedSize(width: width, height: nil), ctx: cellCtx))
            }
            line.measuredChildSizes = cellSizes
            sizes.append(CGSize(width: gridWidth, height: cellSizes.map(\.height).max() ?? 0))
        } else {
            sizes.append(measure(line, proposal: ProposedSize(width: gridWidth, height: nil), ctx: ctx))
        }
    }
    node.measuredChildSizes = sizes
    let height = sizes.map(\.height).reduce(0, +) + verticalSpacing * CGFloat(max(0, sizes.count - 1))
    return CGSize(width: gridWidth, height: height)
}

/// The narrowest a view can be without breaking inside a word (a browser's
/// min-content width): its text's longest word, a row's cells side by side.
private func narrowestWidth(_ node: RenderNode, ctx: LayoutContext) -> CGFloat {
    if let fixed = node.fixedWidth { return fixed }
    var width: CGFloat
    switch node.kind {
    case .text(let string):
        width = string.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { ctx.measureText(String($0), node.font, nil).width }.max() ?? 0
    case .box:
        width = (node.children.first.map { narrowestWidth($0, ctx: ctx) } ?? 0) + node.padding.horizontal
    case .stack(.horizontal):
        width = node.children.map { narrowestWidth($0, ctx: ctx) }.reduce(0, +)
            + (node.stackSpacing ?? 8) * CGFloat(max(0, node.children.count - 1))
    case .stack:
        width = node.children.map { narrowestWidth($0, ctx: ctx) }.max() ?? 0
    default:
        width = measure(node, proposal: ProposedSize(), ctx: ctx).width
    }
    if let least = node.minWidth { width = max(width, least) }
    if let most = node.maxWidth { width = min(width, most) }
    return width
}

@MainActor
private func placeGrid(_ node: RenderNode, columns: Int, in frame: CGRect, ctx: LayoutContext) {
    _ = measureGrid(node, columns: columns, proposal: ProposedSize(width: frame.width, height: frame.height), ctx: ctx)
    var cellCtx = ctx
    cellCtx.parentAxis = .horizontal
    let widths = node.gridColumnWidths
    let horizontalSpacing = node.children.first(where: { $0.isGridRow })?.stackSpacing ?? 8
    let verticalSpacing = node.stackSpacing ?? 8
    let gridWidth = widths.reduce(0, +) + horizontalSpacing * CGFloat(columns - 1)
    var y = frame.minY
    for (index, line) in node.children.enumerated() {
        let height = node.measuredChildSizes[index].height
        let lineRect = CGRect(x: frame.minX, y: y, width: gridWidth, height: height)
        if line.isGridRow {
            line.frame = lineRect
            var x = frame.minX
            for (column, cell) in line.children.enumerated() {
                let width = column < widths.count ? widths[column] : 0
                let slot = CGRect(x: x, y: y, width: width, height: height)
                place(cell, in: alignedRect(size: line.measuredChildSizes[column], container: slot, alignment: line.stackAlignment), ctx: cellCtx)
                x += width + horizontalSpacing
            }
        } else {
            place(line, in: alignedRect(size: node.measuredChildSizes[index], container: lineRect, alignment: node.stackAlignment), ctx: ctx)
        }
        y += height + verticalSpacing
    }
}

@MainActor
private func placeStack(_ node: RenderNode, axis: StackAxis, in frame: CGRect, ctx: LayoutContext) {
    if axis == .vertical, let columns = node.gridColumns {
        placeGrid(node, columns: columns, in: frame, ctx: ctx)
        return
    }
    var childCtx = ctx
    childCtx.parentAxis = axis

    // Re-measure with the final proposal so flexible children fill `frame`.
    _ = measureStack(
        node,
        axis: axis,
        proposal: ProposedSize(width: frame.width, height: frame.height),
        ctx: ctx
    )
    let sizes = node.measuredChildSizes
    let spacing = node.stackSpacing ?? 8

    var cursor = axis == .horizontal ? frame.minX : frame.minY
    for (i, child) in node.children.enumerated() {
        let size = sizes[i]
        var rect: CGRect
        if axis == .horizontal {
            let y: CGFloat
            switch node.stackAlignment.vertical.kind {
            case .top: y = frame.minY
            case .center: y = frame.minY + (frame.height - size.height) / 2
            case .bottom: y = frame.maxY - size.height
            }
            rect = CGRect(x: cursor, y: y, width: size.width, height: size.height)
            cursor += size.width + spacing
        } else {
            let x: CGFloat
            switch node.stackAlignment.horizontal.kind {
            case .leading: x = frame.minX
            case .center: x = frame.minX + (frame.width - size.width) / 2
            case .trailing: x = frame.maxX - size.width
            }
            rect = CGRect(x: x, y: cursor, width: size.width, height: size.height)
            cursor += size.height + spacing
        }
        place(child, in: rect, ctx: childCtx)
    }
}

func alignedRect(size: CGSize, container: CGRect, alignment: Alignment) -> CGRect {
    let x: CGFloat
    switch alignment.horizontal.kind {
    case .leading: x = container.minX
    case .center: x = container.minX + (container.width - size.width) / 2
    case .trailing: x = container.maxX - size.width
    }
    let y: CGFloat
    switch alignment.vertical.kind {
    case .top: y = container.minY
    case .center: y = container.minY + (container.height - size.height) / 2
    case .bottom: y = container.maxY - size.height
    }
    return CGRect(x: x, y: y, width: size.width, height: size.height)
}
