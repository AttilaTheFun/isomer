// DisclosureGroup (an expandable row) and OutlineGroup (a recursive tree built
// from DisclosureGroups) — SwiftUI's hierarchical "outline" surface. Real
// SwiftUI is used on Apple; this is the reimplementation.

public struct DisclosureGroup<Label: View, Content: View> {
    let label: Label
    let content: Content
    let isExpanded: Binding<Bool>?

    public init(
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder label: () -> Label
    ) {
        self.content = content()
        self.label = label()
        self.isExpanded = nil
    }

    public init(
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder label: () -> Label
    ) {
        self.content = content()
        self.label = label()
        self.isExpanded = isExpanded
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension DisclosureGroup where Label == Text {
    public init<S: StringProtocol>(_ titleKey: S, @ViewBuilder content: @escaping () -> Content) {
        let titleKey = String(titleKey)
        self.content = content()
        self.label = Text(titleKey)
        self.isExpanded = nil
    }

    public init<S: StringProtocol>(
        _ titleKey: S,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        let titleKey = String(titleKey)
        self.content = content()
        self.label = Text(titleKey)
        self.isExpanded = isExpanded
    }
}

extension DisclosureGroup: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let path = ctx.path
        let expanded = isExpanded?.wrappedValue ?? Runtime.shared.disclosureExpanded[path] ?? false

        let chevron = RenderNode(kind: .text(expanded ? "\u{25BE}" : "\u{25B8}"))
        chevron.font = .footnote
        // The secondary label colour, legible in either appearance.
        chevron.color = .secondary
        let chevronBox = RenderNode.box(child: chevron)
        chevronBox.fixedWidth = 16

        var lsub = ctx.descend("dglabel")
        let labelNode = buildNode(view: label, ctx: &lsub)

        let header = RenderNode(kind: .stack(.horizontal))
        header.stackSpacing = 4
        header.stackAlignment = .center
        header.children = [chevronBox, labelNode, RenderNode(kind: .spacer(nil))]
        // The row's width, so its spacer puts the label at the leading edge
        // (the box would otherwise center a content-wide stack).
        header.expandsWidth = true
        let headerBox = RenderNode.box(child: header)
        headerBox.expandsWidth = true
        headerBox.padding = EdgeInsets(top: 7, leading: 0, bottom: 7, trailing: 0)
        let binding = isExpanded
        headerBox.tapAction = {
            if let binding {
                binding.wrappedValue.toggle()
            } else {
                Runtime.shared.disclosureExpanded[path] = !expanded
            }
        }
        headerBox.pressFeedback = .highlight

        let column = RenderNode(kind: .stack(.vertical))
        column.stackAlignment = Alignment(horizontal: .leading, vertical: .center)
        column.stackSpacing = 0
        column.expandsWidth = true
        column.children = [headerBox]

        if expanded {
            var csub = ctx.descend("dgcontent")
            let kids = buildChildren(of: content, ctx: &csub)
            let contentStack = RenderNode(kind: .stack(.vertical))
            contentStack.stackAlignment = Alignment(horizontal: .leading, vertical: .center)
            contentStack.stackSpacing = 2
            contentStack.expandsWidth = true
            // Each row fills the group's width, as a list's rows do. Left to
            // itself a leading-aligned child takes its content's width and
            // runs past the group — a long single-line title was cut off at
            // the pane's edge instead of ending in an ellipsis.
            for kid in kids where kid.fixedWidth == nil { kid.expandsWidth = true }
            contentStack.children = kids
            let indented = RenderNode.box(child: contentStack)
            indented.padding = EdgeInsets(top: 0, leading: 20, bottom: 2, trailing: 0)
            indented.expandsWidth = true
            column.children.append(indented)
        }
        return column
    }
}

// MARK: - OutlineGroup (recursive)

public struct OutlineGroup<Data: RandomAccessCollection, ID: Hashable, Leaf: View> {
    let data: Data
    let idKey: KeyPath<Data.Element, ID>
    let childrenKey: KeyPath<Data.Element, Data?>
    let leaf: (Data.Element) -> Leaf

    public init(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        children: KeyPath<Data.Element, Data?>,
        @ViewBuilder content: @escaping (Data.Element) -> Leaf
    ) {
        self.data = data
        self.idKey = id
        self.childrenKey = children
        self.leaf = content
    }

    public var body: some View {
        // VStack so the rows stack vertically in the reimplementation (a bare
        // ForEach body would be laid out as an overlapping ZStack). On Apple
        // the real SwiftUI `OutlineGroup` is used instead.
        VStack(alignment: .leading, spacing: 2) {
            ForEach(data, id: idKey) { element in
                _OutlineRow(
                    element: element,
                    idKey: idKey,
                    childrenKey: childrenKey,
                    leaf: leaf
                )
            }
        }
    }
}

extension OutlineGroup where Data.Element: Identifiable, ID == Data.Element.ID {
    public init(
        _ data: Data,
        children: KeyPath<Data.Element, Data?>,
        @ViewBuilder content: @escaping (Data.Element) -> Leaf
    ) {
        self.init(data, id: \.id, children: children, content: content)
    }
}

struct _OutlineRow<Data: RandomAccessCollection, ID: Hashable, Leaf: View> {
    let element: Data.Element
    let idKey: KeyPath<Data.Element, ID>
    let childrenKey: KeyPath<Data.Element, Data?>
    let leaf: (Data.Element) -> Leaf

    @ViewBuilder
    var body: some View {
        if let children = element[keyPath: childrenKey] {
            DisclosureGroup {
                OutlineGroup(element: children, idKey: idKey, childrenKey: childrenKey, leaf: leaf)
            } label: {
                leaf(element)
            }
        } else {
            leaf(element)
        }
    }
}

extension OutlineGroup {
    /// Internal recursion helper mirroring the public initializer.
    init(element data: Data, idKey: KeyPath<Data.Element, ID>, childrenKey: KeyPath<Data.Element, Data?>, leaf: @escaping (Data.Element) -> Leaf) {
        self.data = data
        self.idKey = idKey
        self.childrenKey = childrenKey
        self.leaf = leaf
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension DisclosureGroup: View {}
extension OutlineGroup: View {}
extension _OutlineRow: View {}
