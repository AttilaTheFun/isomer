// Form and Section: grouped, inset-rounded containers (the iOS grouped-list
// look). Real SwiftUI is used on Apple; this is the reimplementation.

public struct Section<Content: View> {
    let header: AnyView?
    let footer: AnyView?
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.header = nil
        self.footer = nil
        self.content = content()
    }

    public init<S: StringProtocol>(_ titleKey: S, @ViewBuilder content: () -> Content) {
        let titleKey = String(titleKey)
        var title = Text(titleKey).font(.footnote).foregroundColor(.secondary)
        title.containerStyled = true
        self.header = AnyView(title)
        self.footer = nil
        self.content = content()
    }

    /// Apple's older form: the header as a view.
    public init<Header: View>(header: Header, @ViewBuilder content: () -> Content) {
        self.header = AnyView(header)
        self.footer = nil
        self.content = content()
    }

    public init<Header: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header
    ) {
        self.header = AnyView(header())
        self.footer = nil
        self.content = content()
    }

    public init<Footer: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.header = nil
        self.footer = AnyView(footer())
        self.content = content()
    }

    public init<Header: View, Footer: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer
    ) {
        self.header = AnyView(header())
        self.footer = AnyView(footer())
        self.content = content()
    }

    public typealias Body = Never
}

/// Lets `List` recognize a `Section` to emit its header as a non-selectable
/// section-header row followed by the section's rows.
protocol _SectionView {
    var _sectionHeader: (any View)? { get }
    var _sectionContent: any View { get }
    var _sectionFooter: (any View)? { get }
}

extension Section: _SectionView {
    var _sectionHeader: (any View)? { header }
    var _sectionContent: any View { content }
    var _sectionFooter: (any View)? { footer }
}

extension Section: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var sub = ctx.descend("section")
        sub.env.formRow = true
        let rows = buildChildren(of: content, ctx: &sub)

        // Rounded white card of rows separated by inset dividers.
        let group = RenderNode(kind: .stack(.vertical))
        group.stackAlignment = Alignment(horizontal: .leading, vertical: .center)
        group.stackSpacing = 0
        group.expandsWidth = true
        for (index, row) in rows.enumerated() {
            let cell = RenderNode.box(child: row)
            cell.padding = EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)
            cell.minHeight = 44
            cell.expandsWidth = true
            cell.alignment = .leading
            cell.formRole = "row"
            group.children.append(cell)
            if index < rows.count - 1 {
                let separator = RenderNode(kind: .divider)
                separator.color = Color.separator
                // Inset from both edges, as iOS 26's and the Mac's are.
                let inset = RenderNode.box(child: separator)
                inset.padding = EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
                inset.expandsWidth = true
                inset.formRole = "separator"
                group.children.append(inset)
            }
        }
        let card = RenderNode.box(child: group)
        card.background = [formFill(ctx.env.inSheet ? Color.elevatedSecondaryBackground : Color.secondaryBackground)]
        card.cornerRadius = 10
        card.expandsWidth = true
        card.formRole = "card"

        let column = RenderNode(kind: .stack(.vertical))
        column.stackAlignment = Alignment(horizontal: .leading, vertical: .center)
        column.stackSpacing = 6
        column.expandsWidth = true
        if let header {
            var hsub = ctx.descend("header")
            hsub.env.font = .footnote
            hsub.env.foregroundColor = Color.secondary
            let box = RenderNode.box(child: buildNode(view: header, ctx: &hsub))
            box.padding = EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
            box.formRole = "header"
            column.children.append(box)
        }
        column.children.append(card)
        if let footer {
            // Footnote, secondary — applied through the environment so the
            // footer's own Text picks it up (a style on the wrapper would not).
            var fsub = ctx.descend("footer")
            fsub.env.font = .footnote
            fsub.env.foregroundColor = Color.secondary
            let footerNode = buildNode(view: footer, ctx: &fsub)
            footerNode.pinRebuildSite()
            footerNode.font = .footnote
            footerNode.color = Color.secondary
            let box = RenderNode.box(child: footerNode)
            box.padding = EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
            box.formRole = "footer"
            column.children.append(box)
        }
        column.formRole = "section"
        return column
    }
}

public struct Form<Content: View> {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension Form: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var sub = ctx.descend("form")
        let sections = buildChildren(of: content, ctx: &sub)

        let column = RenderNode(kind: .stack(.vertical))
        column.stackAlignment = Alignment(horizontal: .leading, vertical: .center)
        column.stackSpacing = 22
        column.expandsWidth = true
        column.children = sections
        column.padding = EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16)

        let scroll = RenderNode(kind: .scroll(.vertical))
        scroll.identityPath = ctx.path
        scroll.scrollEdgeTop = ctx.env.scrollEdgeTop
        scroll.scrollEdgeBottom = ctx.env.scrollEdgeBottom
        scroll.scrollDisabled = !ctx.env._isScrollEnabled
        scroll.showsIndicators = !ctx.env.scrollIndicatorsHidden
        scroll.expandsWidth = true
        scroll.children = [column]

        // Full-bleed grouped background behind the scroll.
        let backdrop = RenderNode(kind: .stack(.depth))
        backdrop.expandsWidth = true
        backdrop.expandsHeight = true
        // (`.scrollContentBackground(.hidden)`: none, what is behind shows.)
        let fill = formFill(ctx.env.scrollContentBackgroundHidden ? Color.clear
            : ctx.env.inSheet ? Color.elevatedGroupedBackground : Color.groupedBackground)
        fill.expandsWidth = true
        fill.expandsHeight = true
        backdrop.children = [fill, scroll]
        backdrop.formRole = "form"
        return backdrop
    }
}

private func formFill(_ color: Color) -> RenderNode {
    RenderNode(kind: .shape(.rectangle, fill: color, stroke: nil))
}

/// `.formStyle`: this Form already renders the inset-grouped look (rounded
/// cards per Section with the header above), which is `.grouped`;
/// `.automatic` and `.columns` map to the same layout.
/// A style of Isomer's own, by the name the hosts know it by ("menu",
/// "insetGrouped", …). Apple's style protocols ask nothing of the kind, so
/// it is not theirs to require: a style an app defines has none, and is
/// drawn as the automatic one.
protocol NamedStyle {
    var styleName: String { get }
}

/// `style`'s name on the wire, or `otherwise` for a style an app defines.
func styleName(_ style: Any, otherwise: String) -> String {
    (style as? any NamedStyle)?.styleName ?? otherwise
}

/// How a Form is laid out: Apple's protocol (Forms are grouped here,
/// whatever the style).
@MainActor @preconcurrency
public protocol FormStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = FormStyleConfiguration
}

/// A Form's content, as a style gets it.
public struct FormStyleConfiguration {
    public struct Content: View {
        public typealias Body = Never
    }
    public let content: FormStyleConfiguration.Content
}

extension FormStyleConfiguration.Content: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode { RenderNode(kind: .box) }
}

public struct AutomaticFormStyle: FormStyle, NamedStyle {
    nonisolated public init() {}
    var styleName: String { "automatic" }
    nonisolated public func makeBody(configuration: Configuration) -> some View { configuration.content }
}

public struct GroupedFormStyle: FormStyle, NamedStyle {
    nonisolated public init() {}
    var styleName: String { "grouped" }
    nonisolated public func makeBody(configuration: Configuration) -> some View { configuration.content }
}

public struct ColumnsFormStyle: FormStyle, NamedStyle {
    nonisolated public init() {}
    var styleName: String { "columns" }
    nonisolated public func makeBody(configuration: Configuration) -> some View { configuration.content }
}

extension FormStyle where Self == AutomaticFormStyle {
    nonisolated public static var automatic: AutomaticFormStyle { AutomaticFormStyle() }
}

extension FormStyle where Self == GroupedFormStyle {
    nonisolated public static var grouped: GroupedFormStyle { GroupedFormStyle() }
}

extension FormStyle where Self == ColumnsFormStyle {
    nonisolated public static var columns: ColumnsFormStyle { ColumnsFormStyle() }
}

extension View {
    nonisolated public func formStyle<S: FormStyle>(_ style: S) -> some View { self }
}

/// `LabeledContent`: label leading, content trailing (secondary color for
/// the string form), filling the row — the Form/List row idiom.
public struct LabeledContent<Label: View, Content: View> {
    let label: Label
    let content: Content
    var secondaryValue = false

    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.content = content()
    }

    @ViewBuilder
    public var body: some View {
        HStack {
            label
            Spacer()
            if secondaryValue {
                content.foregroundColor(.secondary)
            } else {
                content
            }
        }
    }
}

extension LabeledContent where Label == Text {
    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        let title = String(title)
        self.init(content: content) { Text(title) }
    }
}

extension LabeledContent where Label == Text, Content == Text {
    public init<S1: StringProtocol, S2: StringProtocol>(_ title: S1, value: S2) {
        self.label = Text(String(title))
        self.content = Text(String(value))
        self.secondaryValue = true
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension Section: View {}
extension Form: View {}
extension LabeledContent: View {}
