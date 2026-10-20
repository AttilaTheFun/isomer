// Scrolling containers. Scroll offsets persist across renders keyed by the
// node's structural identity; the host clips via pushClip/popClip and routes
// wheel/drag input through the runtime.

public enum Axis: Int8, CaseIterable, Sendable {
    case horizontal, vertical

    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }

        public static let horizontal = Set(rawValue: 1 << 0)
        public static let vertical = Set(rawValue: 1 << 1)
    }
}

public struct ScrollView<Content: View> {
    let axes: Axis.Set
    let showsIndicators: Bool
    let content: Content

    public init(
        _ axes: Axis.Set = .vertical,
        showsIndicators: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.axes = axes
        self.showsIndicators = showsIndicators
        self.content = content()
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension ScrollView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let axis: StackAxis = axes.contains(.horizontal) && !axes.contains(.vertical)
            ? .horizontal
            : .vertical
        let node = RenderNode(kind: .scroll(axis))
        node.dismissesKeyboard = ctx.env.scrollDismissesKeyboard
        node.scrollBounce = ctx.env.scrollBounceBehavior
        node.scrollDisabled = !ctx.env._isScrollEnabled
        node.scrollEdgeTop = ctx.env.scrollEdgeTop
        node.scrollEdgeBottom = ctx.env.scrollEdgeBottom
        node.identityPath = ctx.path
        node.showsIndicators = showsIndicators && !ctx.env.scrollIndicatorsHidden
        var sub = ctx.descend("scroll")
        node.children = [buildNode(view: content, ctx: &sub)]
        return node
    }
}

// MARK: - Lazy stacks (eager equivalents; laziness is an optimization the
// flat draw-list renderer does not need yet).

public struct LazyVStack<Content: View> {
    let alignment: HorizontalAlignment
    let spacing: CGFloat?
    let content: Content

    public init(
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        pinnedViews: PinnedScrollableViews = .init(),
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public typealias Body = Never
}

extension LazyVStack: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        VStack(alignment: alignment, spacing: spacing, content: { content }).makeNode(&ctx)
    }
}

public struct LazyHStack<Content: View> {
    let alignment: VerticalAlignment
    let spacing: CGFloat?
    let content: Content

    public init(
        alignment: VerticalAlignment = .center,
        spacing: CGFloat? = nil,
        pinnedViews: PinnedScrollableViews = .init(),
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public typealias Body = Never
}

extension LazyHStack: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        HStack(alignment: alignment, spacing: spacing, content: { content }).makeNode(&ctx)
    }
}

// MARK: - List

/// A plain-style list: a vertical scroll view of full-width rows with
/// standard insets and separators.
public struct List<Content: View> {
    let content: Content
    /// Selection plumbing (set by the `selection:` initializer). `onSelect`
    /// fires with a tapped row's `.tag(_:)` value; `isSelected` highlights the
    /// current one.
    var onSelect: ((AnyHashable) -> Void)?
    var isSelected: ((AnyHashable) -> Bool)?
    /// The current selection (for a split view column to notice selection
    /// changes; see Runtime.splitSelectionSnapshot).
    var currentSelection: (() -> AnyHashable?)?
    /// Sets the selection to none (a compact split returning to this list).
    var clearSelection: (() -> Void)?

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension List {
    /// Single-selection list. Rows carry their selection value via `.tag(_:)`.
    public init<SelectionValue: Hashable>(
        selection: Binding<SelectionValue?>?,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        guard let selection else { return }
        self.onSelect = { tag in
            guard let value = tag as? SelectionValue else { return }
            if value == selection.wrappedValue {
                // Tapping the already-selected row: a compact split view
                // still advances to that row's detail (as on a phone).
                Runtime.shared.splitReselectRequested = true
                // The split views read it as they build: built again now.
                for split in Runtime.shared.splitViewPaths { Runtime.shared.stateDidChange(key: split + "#reselect") }
                Runtime.shared.requestFrame()
            }
            selection.wrappedValue = value
        }
        self.isSelected = { tag in (tag as? SelectionValue) == selection.wrappedValue }
        self.currentSelection = { selection.wrappedValue.map { AnyHashable($0) } }
        self.clearSelection = { selection.wrappedValue = nil }
    }
}


extension List {
    public init<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Data.Element: Identifiable, Content == ForEach<Data, RowContent> {
        self.init { ForEach(data, content: rowContent) }
    }

    /// `List(items, selection: $selected) { row }`: rows select by their id
    /// (each row is the tagged view the list's row collector recognizes).
    public init<Data: RandomAccessCollection, RowContent: View, SelectionValue: Hashable>(
        _ data: Data,
        selection: Binding<SelectionValue?>?,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Data.Element: Identifiable, Content == ForEach<Data, RowContent> {
        self.init(selection: selection) {
            ForEach(taggingRowsOf: data, content: rowContent)
        }
    }

    public init<Data: RandomAccessCollection, ID: Hashable, RowContent: View>(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == ForEach<Data, RowContent> {
        self.init { ForEach(data, id: id, content: rowContent) }
    }

    /// `List($items) { $item in … }`: each row with a binding to its element.
    public init<C: MutableCollection & RandomAccessCollection, RowContent: View>(
        _ data: Binding<C>,
        @ViewBuilder rowContent: @escaping (Binding<C.Element>) -> RowContent
    ) where C.Element: Identifiable, Content == ForEach<C, RowContent> {
        self.init { ForEach(data, content: rowContent) }
    }
}

extension List: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        // A sidebar's selection, for its split view to follow (made again
        // when a view around the list is reused).
        if let currentSelection, Runtime.shared.splitColumnBuilding != nil {
            let clear = clearSelection
            Runtime.shared.registerFrameEffect {
                guard Runtime.shared.splitColumnBuilding != nil else { return }
                Runtime.shared.splitSelectionSnapshot = currentSelection()
                Runtime.shared.splitSelectionClearer = clear
            }
        }
        let scroll = RenderNode(kind: .scroll(.vertical))
        scroll.identityPath = ctx.path
        scroll.dismissesKeyboard = ctx.env.scrollDismissesKeyboard
        scroll.scrollBounce = ctx.env.scrollBounceBehavior
        scroll.scrollDisabled = !ctx.env._isScrollEnabled
        scroll.scrollEdgeTop = ctx.env.scrollEdgeTop
        scroll.scrollEdgeBottom = ctx.env.scrollEdgeBottom
        scroll.showsIndicators = !ctx.env.scrollIndicatorsHidden
        scroll.contentBackgroundHidden = ctx.env.scrollContentBackgroundHidden
        scroll.expandsWidth = true
        scroll.isList = true
        scroll.listStyle = ctx.env.listStyle
        scroll.listRowSeparators = ctx.env.listRowSeparators
        if ctx.env.defaultMinListRowHeight != 44 { scroll.minListRowHeight = ctx.env.defaultMinListRowHeight }

        // Semantic hosts (native list components / cell-styled hosts) own
        // the row chrome: cells carry a `cell` marker instead of baked-in
        // padding/height/dividers, and each host applies its platform's row
        // metrics and separators. They also lay rows out lazily, so only
        // the rows near what they show are built (as SwiftUI's List builds
        // rows as they come on screen); the rest go as keyed placeholders.
        let semantic = Renderer.hostRendersNavigation
        var sub = ctx.descend("list")
        sub.env.formRow = true
        var slots: [_RowSlot] = []
        collectRowSlots(of: content, ctx: &sub, into: &slots)
        let window = semantic ? Runtime.shared.listBuildWindow(list: ctx.path, rowPaths: slots.map(\.ctx.path)) : nil
        if semantic { scroll.lazyRows = true }
        var rows: [(node: RenderNode, tag: AnyHashable?, isHeader: Bool, path: String)] = []
        rows.reserveCapacity(slots.count)
        for (index, slot) in slots.enumerated() {
            if let window, !window.contains(index) {
                // Off screen: last frame's placeholder cell when it had one
                // (nothing to make), else a new placeholder.
                if !slot.isHeader, let cached = Runtime.shared.listCells[slot.ctx.path], cached.placeholder,
                   cached.hidesSeparator == !slot.ctx.env.listRowSeparators {
                    rows.append((cached.cell, nil, false, slot.ctx.path))
                } else {
                    rows.append((slot.placeholder(), nil, slot.isHeader, slot.ctx.path))
                }
            } else {
                let before = rows.count
                slot.build(into: &rows)
                // Where a row's `.id` is, for scroll requests to build it
                // again when it is off screen.
                for row in rows[before...] {
                    if let target = scrollTargetNear(row.node) {
                        Runtime.shared.listRowTargets[ctx.path, default: [:]][target] = row.path
                    }
                }
            }
        }
        // Rows that all hide their separators (`.listRowSeparator(.hidden)`
        // on the rows, as SwiftUI allows) make a list without lines.
        let bodyRows = rows.filter { !$0.isHeader }
        if !bodyRows.isEmpty, bodyRows.allSatisfy({ $0.node.hidesRowSeparator }) { scroll.listRowSeparators = false }

        let column = RenderNode(kind: .stack(.vertical))
        column.stackAlignment = Alignment(horizontal: .leading, vertical: .center)
        column.stackSpacing = 0
        column.expandsWidth = true

        for (index, row) in rows.enumerated() {
            if row.isHeader, row.path.hasSuffix("/" + _sectionFooterComponent) {
                // A section's footer: under its group, in line with its rows.
                let footer = RenderNode.box(child: row.node)
                footer.padding = EdgeInsets(top: 6, leading: 16, bottom: 4, trailing: 16)
                footer.expandsWidth = true
                footer.alignment = .leading
                footer.buildPath = row.path + "~footer"
                if semantic { footer.listCell = "footer" }
                column.children.append(footer)
                continue
            }
            if row.isHeader {
                let header = sectionHeaderCell(row.node)
                header.buildPath = row.path + "~header"
                header.isRowPlaceholder = row.node.isRowPlaceholder
                if semantic { header.listCell = "header" }
                column.children.append(header)
                continue
            }
            // The cell is the row's: it keys on the row's identity (its
            // place in the list's content, the same built or not). On a
            // semantic host an unchanged row keeps last frame's cell, which
            // renderers keep what they derived from (Reuse.swift).
            let selectable = onSelect != nil && row.tag != nil
            let selected = selectable && isSelected?(row.tag!) == true
            if semantic, let cached = Runtime.shared.listCells[row.path],
               cached.placeholder == row.node.isRowPlaceholder,
               cached.placeholder ? cached.cell === row.node || row.node.children.isEmpty : cached.content === row.node,
               cached.selectable == selectable, cached.selected == selected,
               cached.hidesSeparator == row.node.hidesRowSeparator,
               cached.cell.listRowInsets == row.node.listRowInsets, cached.cell.listRowBackground == row.node.listRowBackground,
               cached.cell.listRowBackgroundNode == nil, row.node.listRowBackgroundNode == nil {
                Runtime.shared.listCellsTouched.insert(row.path)
                column.children.append(cached.cell)
                continue
            }
            let cell = row.node.isRowPlaceholder ? row.node : RenderNode.box(child: row.node)
            cell.buildPath = row.path + "~cell"
            if semantic {
                cell.isReusedSubtreeRoot = true
                Runtime.shared.listCells[row.path] = _ListCell(
                    content: row.node.isRowPlaceholder ? nil : row.node, placeholder: row.node.isRowPlaceholder,
                    selectable: selectable, selected: selected, hidesSeparator: row.node.hidesRowSeparator, cell: cell)
                Runtime.shared.listCellsTouched.insert(row.path)
            }
            // `.listRowInsets` / `.listRowBackground` on the row: semantic
            // hosts apply them to their cell; here they are the cell's.
            cell.listRowInsets = row.node.listRowInsets
            cell.listRowBackground = row.node.listRowBackground
            // A view behind the row (`.listRowBackground(view)`): the cell's
            // background layer, on every host, in place of its own fill
            // and selection.
            cell.listRowBackgroundNode = row.node.listRowBackgroundNode
            if let background = row.node.listRowBackgroundNode { cell.background = [background] }
            if semantic {
                cell.listCell = "row"
                // `.listRowSeparator(.hidden)` on the row: the host draws no
                // line under this cell.
                cell.hidesRowSeparator = row.node.hidesRowSeparator
            } else {
                let standard = EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)
                cell.padding = row.node.listRowInsets?.resolvingListDefaults(standard) ?? standard
                cell.minHeight = ctx.env.defaultMinListRowHeight
                if let background = row.node.listRowBackground, row.node.listRowBackgroundNode == nil { cell.background = [filledSelection(background)] }
            }
            cell.expandsWidth = true
            cell.alignment = .leading
            // Selection: tap sets the binding; the current row is highlighted.
            if let onSelect, let tag = row.tag {
                cell.tapAction = { onSelect(tag) }
                cell.pressFeedback = .ripple
                if isSelected?(tag) == true {
                    cell.listSelected = true
                    // (A row with a view behind it draws its own selection.)
                    if !semantic, row.node.listRowBackgroundNode == nil { cell.background = [filledSelection(Color.accentColor.opacity(0.18))] }
                }
            }
            column.children.append(cell)
            // A divider after a row, except before a section header or at the
            // end — only for hosts that draw their own chrome (semantic
            // hosts add native separators).
            let nextIsHeader = index + 1 < rows.count && rows[index + 1].isHeader
            if !semantic, ctx.env.listRowSeparators, !row.node.hidesRowSeparator, index < rows.count - 1, !nextIsHeader {
                let separator = RenderNode(kind: .divider)
                separator.color = Color.separator
                let inset = RenderNode.box(child: separator)
                inset.padding = EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
                inset.expandsWidth = true
                inset.buildPath = row.path + "~separator"
                column.children.append(inset)
            }
        }

        scroll.children = [column]
        // Its cells stay cached while a view around the list is reused.
        let touched = rows.map(\.path)
        Runtime.shared.registerFrameEffect(local: true) { Runtime.shared.listCellsTouched.formUnion(touched) }
        return scroll
    }
}

/// The path component a section's footer slot is built under.
let _sectionFooterComponent = "sectionfooter"

/// A non-selectable section-header cell (iOS plain-list style: inset, extra top
/// space).
private func sectionHeaderCell(_ headerNode: RenderNode) -> RenderNode {
    let cell = RenderNode.box(child: headerNode)
    cell.padding = EdgeInsets(top: 18, leading: 16, bottom: 6, trailing: 16)
    cell.expandsWidth = true
    cell.alignment = .leading
    return cell
}

/// One row of a List as found in its content, not yet built: where it is,
/// what builds it, and whether it is a section header.
struct _RowSlot {
    enum Kind {
        case header(any View)
        case emptyHeader
        /// A section's footer, after its rows (`Section { } footer: { }`).
        case footer(any View)
        case tagged(_AnyTaggedView)
        case row(any View, tag: AnyHashable?)
        case composite(any View)
        /// A ForEach row whose view is made only if the row is built.
        case deferred(() -> any View)
    }
    let kind: Kind
    let ctx: BuildContext

    /// A section's header or footer: always built (not a row of the
    /// window), and where a group of rows ends.
    var isHeader: Bool {
        switch kind {
        case .header, .emptyHeader, .footer: return true
        default: return false
        }
    }

    /// What stands in for the row while it is off screen: an empty cell
    /// with the row's identity (hosts give it the row's last height).
    @MainActor
    func placeholder() -> RenderNode {
        let node = RenderNode(kind: .box)
        node.isRowPlaceholder = true
        node.takeRowEnvironment(ctx)
        return node
    }

    /// Builds the row (several, for an app view whose body turns out to be
    /// several rows).
    @MainActor
    func build(into rows: inout [(node: RenderNode, tag: AnyHashable?, isHeader: Bool, path: String)]) {
        var ctx = self.ctx
        switch kind {
        case .header(let header):
            var hsub = ctx.descend("sectionheader")
            // A section's header is secondary unless it says otherwise, as
            // SwiftUI's are on every platform.
            hsub.env.foregroundColor = Color.secondary
            rows.append((buildNode(view: header, ctx: &hsub), nil, true, ctx.path))
        case .emptyHeader:
            rows.append((RenderNode(kind: .box), nil, true, ctx.path))
        case .footer(let footer):
            // Footnote, secondary, as SwiftUI's section footers are.
            var fsub = ctx
            fsub.env.font = .footnote
            fsub.env.foregroundColor = Color.secondary
            rows.append((buildNode(view: footer, ctx: &fsub), nil, true, ctx.path))
        case .tagged(let tagged):
            var sub = ctx.descend("tagged")
            let node = buildNode(view: tagged.content, ctx: &sub)
            node.takeRowEnvironment(sub)
            rows.append((node, tagged.tagValue, false, ctx.path))
        case .row(let view, let tag):
            let node = buildNode(view: view, ctx: &ctx)
            node.takeRowEnvironment(ctx)
            rows.append((node, tag, false, ctx.path))
        case .deferred(let make):
            // The row's view, made now: found and built like any content.
            var inner: [_RowSlot] = []
            collectRowSlots(of: make(), ctx: &ctx, into: &inner)
            for slot in inner { slot.build(into: &rows) }
        case .composite(let view):
            // A view whose body is one row is that row, built (and reused
            // while its inputs are unchanged) like any view.
            if let node = reusedSubtree(for: view, ctx: ctx) {
                node.takeRowEnvironment(ctx)
                rows.append((node, nil, false, ctx.path))
                return
            }
            _frameLogBuilt(view, ctx: ctx)
            let build = beginCompositeBuild(view, ctx: ctx)
            _trackingObservation(at: ctx.path) {
                let body = view.body
                var sub = ctx.descend(typeName(view))
                if contributesRows(body) {
                    // Several rows after all: remembered, so the list finds
                    // them without building next time; these build now.
                    abandonCompositeBuild(build)
                    Runtime.shared.multiRowViewPaths.insert(ctx.path)
                    // Collected after the rows already built, as the next
                    // frame will collect them: a header-less Section in it
                    // starts its own group then (an empty header, which the
                    // first slot stands for here and is not built).
                    var inner: [_RowSlot] = rows.isEmpty ? [] : [_RowSlot(kind: .emptyHeader, ctx: sub)]
                    let marked = inner.count
                    collectRowSlots(of: body, ctx: &sub, into: &inner)
                    for slot in inner.dropFirst(marked) { slot.build(into: &rows) }
                    return
                }
                let node = buildNode(view: body, ctx: &sub)
                if node.buildPath == nil { node.buildPath = sub.path }
                finishCompositeBuild(build, view: view, ctx: ctx, node: node)
                node.takeRowEnvironment(ctx)
                rows.append((node, nil, false, ctx.path))
            }
        }
    }
}

/// Finds a List's rows in its content without building them, pulling each
/// row's `.tag(_:)` value (for selection).
@MainActor
private func collectRowSlots(of view: any View, ctx: inout BuildContext, into slots: inout [_RowSlot]) {
    // A row of the app's own cannot be one of the views below
    // (FieldRecords.swift), and asking scans every conformance.
    let ours = _mayConformInternally(type(of: view))
    if ours, let section = view as? _SectionView {
        if let header = section._sectionHeader {
            slots.append(_RowSlot(kind: .header(header), ctx: ctx))
        } else if !slots.isEmpty {
            // A header-less section after another still starts its own
            // group: an empty header cell is the gap between them.
            slots.append(_RowSlot(kind: .emptyHeader, ctx: ctx))
        }
        var csub = ctx.descend("sectioncontent")
        collectRowSlots(of: section._sectionContent, ctx: &csub, into: &slots)
        if let footer = section._sectionFooter {
            slots.append(_RowSlot(kind: .footer(footer), ctx: ctx.descend(_sectionFooterComponent)))
        }
        return
    }
    // A ForEach: its rows by id, their views made only for the rows built.
    if ours, let indexed = view as? _IndexedRows {
        let rows = indexed.indexedRows()
        slots.reserveCapacity(slots.count + rows.count)
        for index in 0..<rows.count {
            var sub = ctx
            sub.path = ctx.path + "/fe-" + rows.id(index)
            slots.append(_RowSlot(kind: .deferred({ rows.view(index) }), ctx: sub))
        }
        return
    }
    if ours, let multi = view as? _MultiView {
        for entry in multi.childViews() {
            var sub = ctx.descend(entry.suffix)
            collectRowSlots(of: entry.view, ctx: &sub, into: &slots)
        }
        return
    }
    // `.listRowSeparator(.hidden)` and the like on a Group of rows: each
    // row takes the environment and stays its own row.
    if ours, let trait = view as? _ListRowTrait {
        var sub = ctx.descend(trait.descend)
        trait.transform(&sub.env)
        collectRowSlots(of: trait.child, ctx: &sub, into: &slots)
        return
    }
    if ours, let environment = view as? _EnvironmentModifier {
        var sub = ctx.descend(environment.descend)
        environment.transform(&sub.env)
        collectRowSlots(of: environment.child, ctx: &sub, into: &slots)
        return
    }
    if ours, let tagged = view as? _AnyTaggedView {
        slots.append(_RowSlot(kind: .tagged(tagged), ctx: ctx))
        return
    }
    // A tagged row behind modifiers (a context menu, swipe actions, padding).
    if let tag = rowTag(of: view) {
        slots.append(_RowSlot(kind: .row(view, tag: tag), ctx: ctx))
        return
    }
    // A composite view (an app's own `struct: View`) whose body is a
    // Section, a ForEach or several rows contributes those rows, the way
    // SwiftUI evaluates it: its body is what the list sees. One seen to do
    // so is looked into now; any other is taken to be one row until built.
    if _viewKind(view).isComposite, !_viewKind(view).contains(.modified) {
        if Runtime.shared.multiRowViewPaths.contains(ctx.path) {
            connectDynamicProperties(of: view, path: ctx.path, storage: ctx.storage, env: ctx.env)
            let body = _trackingObservation(at: ctx.path) { view.body }
            var sub = ctx.descend(typeName(view))
            collectRowSlots(of: body, ctx: &sub, into: &slots)
            return
        }
        slots.append(_RowSlot(kind: .composite(view), ctx: ctx))
        return
    }
    slots.append(_RowSlot(kind: .row(view, tag: nil), ctx: ctx))
}

/// The `.listRowInsets` / `.listRowBackground` / `.listRowSeparator` applied
/// in a row's content: on the row's node or the ones just inside it, the
/// outermost of each.
private func _rowTraits(of node: RenderNode) -> (
    insets: EdgeInsets??, background: (color: Color?, node: RenderNode?)?, separator: Bool?
) {
    var insets: EdgeInsets?? = nil
    var background: (color: Color?, node: RenderNode?)? = nil
    var separator: Bool? = nil
    var current: RenderNode? = node
    for _ in 0..<8 {
        guard let n = current else { break }
        if insets == nil, let found = n.rowTraitInsets { insets = .some(found) }
        if background == nil, let found = n.rowTraitBackground { background = found }
        if separator == nil, let found = n.rowTraitSeparator { separator = found }
        current = n.children.count == 1 ? n.children[0] : nil
    }
    return (insets, background, separator)
}

/// The `.id` a row carries, on its node or the wrappers just inside it.
private func scrollTargetNear(_ node: RenderNode) -> String? {
    var current: RenderNode? = node
    for _ in 0..<4 {
        guard let n = current else { return nil }
        if let target = n.scrollTarget { return target }
        current = n.children.count == 1 ? n.children[0] : nil
    }
    return nil
}

private func filledSelection(_ color: Color) -> RenderNode {
    RenderNode(kind: .shape(.rectangle, fill: color, stroke: nil))
}

/// Whether a view's body is (or may be) several list rows or carries a row's
/// tag, so the list looks inside it rather than building it as one row.
private func contributesRows(_ view: any View) -> Bool {
    if view is _SectionView || view is _MultiView || view is _EnvironmentModifier || view is _ListRowTrait || view is _AnyTaggedView { return true }
    if rowTag(of: view) != nil { return true }
    // An app's own view: its body decides.
    return _viewKind(view).isComposite
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension ScrollView: View {}
extension LazyVStack: View {}
extension LazyHStack: View {}
extension List: View {}

extension RenderNode {
    /// A list row's chrome from the environment it was built in: its
    /// separator, insets and background (`.listRowSeparator`,
    /// `.listRowInsets`, `.listRowBackground` in it or around its rows).
    @MainActor
    func takeRowEnvironment(_ ctx: BuildContext) {
        let env = ctx.env
        pinRebuildSite()
        // Traits set in the row's own content come first (they were made on
        // top of the environment around it).
        let traits = _rowTraits(of: self)
        hidesRowSeparator = !(traits.separator ?? env.listRowSeparators)
        listRowInsets = traits.insets ?? env.listRowInsets
        if let background = traits.background {
            listRowBackground = background.color
            listRowBackgroundNode = background.node
            return
        }
        listRowBackground = env.listRowBackground
        if let view = env.listRowBackgroundView {
            var sub = ctx.descend("rowbackground")
            sub.env.listRowBackgroundView = nil
            let node = buildNode(view: view, ctx: &sub)
            node.expandsWidth = true
            node.expandsHeight = true
            listRowBackgroundNode = node
        } else {
            listRowBackgroundNode = nil
        }
    }
}
