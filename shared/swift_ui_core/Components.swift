// Higher-level views built on the core node kinds: ProgressView,
// GeometryReader, TabView (+ .tabItem), Menu, and the `.searchable` modifier.

// MARK: - ProgressView

/// A determinate bar (when given a value) or an indeterminate spinner.
public struct ProgressView<Label: View> {
    let value: Double?
    let label: Label
    let hasLabel: Bool

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension ProgressView where Label == EmptyView {
    /// Indeterminate spinner.
    public init() {
        self.value = nil
        self.label = EmptyView()
        self.hasLabel = false
    }

    /// Determinate bar filled to `value / total`.
    /// Determinate bar filled to `value / total`; a spinner when `value` is nil.
    public init<V: BinaryFloatingPoint>(value: V?, total: V = 1.0) {
        self.value = value.map { total == 0 ? 0 : Double($0 / total) }
        self.label = EmptyView()
        self.hasLabel = false
    }
}

extension ProgressView where Label == Text {
    public init<S: StringProtocol>(_ title: S) {
        let title = String(title)
        self.value = nil
        self.label = Text(title)
        self.hasLabel = true
    }

    public init<S: StringProtocol, V: BinaryFloatingPoint>(_ title: S, value: V?, total: V = 1.0) {
        self.value = value.map { total == 0 ? 0 : Double($0 / total) }
        self.label = Text(String(title))
        self.hasLabel = true
    }
}

extension ProgressView {
    /// A bar filled to `value / total` (a spinner when `value` is nil) with
    /// the app's label above it.
    public init<V: BinaryFloatingPoint>(value: V?, total: V = 1.0, @ViewBuilder label: () -> Label) {
        self.value = value.map { total == 0 ? 0 : Double($0 / total) }
        self.label = label()
        self.hasLabel = true
    }
}

extension ProgressView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let bar = RenderNode(kind: .progress(value))
        // `.tint` in scope colors the bar's fill (SwiftUI's).
        bar.tint = ctx.env.tint
        // `.opacity` reaches leaves through the environment; a spinner kept
        // in place but hidden (`.opacity(0)`) must arrive hidden.
        bar.opacity = ctx.env.opacity
        if let size = Runtime.shared.controlSizeStack.last, size != .regular {
            bar.controlSize = size.name
        }
        guard hasLabel else { return bar }
        let stack = RenderNode(kind: .stack(.vertical))
        stack.stackSpacing = 6
        var sub = ctx.descend("label")
        let labelNode = buildNode(view: label, ctx: &sub)
        labelNode.pinRebuildSite()
        labelNode.font = .caption
        labelNode.color = Color(white: 0, opacity: 0.5)
        // Spinner above its label; bar below its label (matches SwiftUI).
        stack.children = value == nil ? [bar, labelNode] : [labelNode, bar]
        return stack
    }
}

// MARK: - GeometryReader

public struct GeometryProxy {
    public let size: CGSize
    /// The safe-area insets the reader's view sits inside. Hosts measure the
    /// reader's container already inset from the safe area, so this is
    /// zero here (Apple's shape, for sizing code written against it).
    public let safeAreaInsets: EdgeInsets
    /// Where the reader is in the window, as its host reports it (zero from
    /// a host that reports only a size).
    let origin: CGPoint
    /// Whether the size is the reader's own, measured by its host or laid
    /// out by the core, and not the canvas's stand-in before that.
    let measured: Bool

    init(size: CGSize, origin: CGPoint = .zero, measured: Bool = true, safeAreaInsets: EdgeInsets = EdgeInsets()) {
        self.size = size
        self.origin = origin
        self.measured = measured
        self.safeAreaInsets = safeAreaInsets
    }

    /// Its frame in its own space (at zero) or in the window's (`.global`;
    /// a named space is taken as the window's).
    public func frame(in coordinateSpace: CoordinateSpace) -> CGRect {
        switch coordinateSpace {
        case .local: return CGRect(origin: .zero, size: size)
        case .global, .named: return CGRect(origin: origin, size: size)
        }
    }
}

public enum CoordinateSpace {
    case local
    case global
    case named(AnyHashable)
}

/// Reads the size proposed to it and hands it to its content closure. The
/// content is (re)built once the final frame is known, during layout.
public struct GeometryReader<Content: View> {
    let content: (GeometryProxy) -> Content

    public init(@ViewBuilder content: @escaping (GeometryProxy) -> Content) {
        self.content = content
    }

    public typealias Body = Never
}

extension GeometryReader: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let node = RenderNode(kind: .geometryReader)
        node.identityPath = ctx.path
        let captured = ctx.descend("geo")
        let content = self.content
        node.geometryBuild = { size, place in
            var sub = captured
            Runtime.shared.geometryBuildDepth += 1
            defer { Runtime.shared.geometryBuildDepth -= 1 }
            let view = content(GeometryProxy(size: size, origin: place ?? .zero, measured: place != nil))
            return buildNode(view: view, ctx: &sub)
        }
        return node
    }
}

// MARK: - TabView

/// A protocol exposing a `.tabItem`'s label and content for collection.
protocol _AnyTabItem {
    var _barLabel: any View { get }
    var _contentView: any View { get }
}

struct _TabItemView<Content: View, LabelV: View>: _AnyTabItem {
    let content: Content
    let label: LabelV

    var _barLabel: any View { label }
    var _contentView: any View { content }

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _TabItemView: _PrimitiveView {
    // Rendered outside a TabView (or as the selected tab's content): just the
    // content; the label only matters to the enclosing TabView's tab bar.
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var sub = ctx.descend("tabcontent")
        return buildNode(view: content, ctx: &sub)
    }
}

extension View {
    nonisolated public func tabItem<V: View>(@ViewBuilder _ label: () -> V) -> some View {
        _TabItemView(content: self, label: label())
    }
}

public struct TabView<Content: View> {
    let content: Content
    /// Erased selection binding: the selected tab's `.tag` value (any
    /// Hashable, like SwiftUI), falling back to the tab index when a tab
    /// carries no tag.
    let selection: (get: () -> AnyHashable, set: (AnyHashable) -> Void)?
    /// Set by the modern `TabView(content:)` Tab/TabSection form
    /// (TabContent.swift); nil for the classic `.tabItem` form.
    let modernEntries: [_TabEntry]?

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
        self.selection = nil
        self.modernEntries = nil
    }

    public init<SelectionValue: Hashable>(selection: Binding<SelectionValue>?, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.selection = selection.map { selection in (
            get: { AnyHashable(selection.wrappedValue) },
            set: { value in
                if let typed = value.base as? SelectionValue { selection.wrappedValue = typed }
            }) }
        self.modernEntries = nil
    }

    init(modernEntries: [_TabEntry], selection: (get: () -> AnyHashable, set: (AnyHashable) -> Void)? = nil) where Content == EmptyView {
        self.content = EmptyView()
        self.selection = selection
        self.modernEntries = modernEntries
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension TabView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var entries: [(label: any View, content: any View, tag: AnyHashable?)] = []
        var modernParams: [String: String] = [:]
        // `.tabViewCustomization`: the user's sidebar arrangement reorders
        // the declared entries; ids + the raw arrangement ride along so the
        // host can offer drag-to-reorder and report "reorder:<raw>".
        let customization = Runtime.shared.tabCustomizationStack.last ?? nil
        var arranged: [_TabEntry]? = nil
        if let declared = modernEntries {
            arranged = customization.map { _arrangeTabs(declared, $0.wrappedValue) } ?? declared
        }
        if let modern = arranged {
            if let customization {
                modernParams["custom"] = "1"
                modernParams["arrangement"] = customization.wrappedValue.wire
                if let key = customization._storageKey { modernParams["storageKey"] = key }
            }
            // The modern Tab/TabSection form: labels are (title, SF glyph)
            // pairs and each tab carries its section title; the enclosing
            // .tabViewStyle rides along so hosts can render the
            // sidebar-adaptable shape.
            for (i, entry) in modern.enumerated() {
                entries.append((label: EmptyView(), content: entry.content, tag: entry.value))
                modernParams["label\(i)"] = entry.title
                // The SF Symbol by name, for hosts that draw symbols
                // themselves (Android's bar draws it from the symbol table).
                if !entry.systemImage.isEmpty { modernParams["symbol\(i)"] = entry.systemImage }
                modernParams["section\(i)"] = entry.section
                if customization != nil {
                    modernParams["cid\(i)"] = entry.id
                    modernParams["sid\(i)"] = entry.sectionID
                    if entry.fixed { modernParams["fixed\(i)"] = "1" }
                    if entry.sectionFixed { modernParams["sfixed\(i)"] = "1" }
                }
                if !entry.systemImage.isEmpty {
                    modernParams["glyph\(i)"] =
                        Image.glyph(forSystemName: entry.systemImage)
                }
            }
        } else {
            collectTabEntries(content, into: &entries)
        }
        // The enclosing .tabViewStyle rides along for both forms (modern
        // sidebarAdaptable, classic tabBarOnly).
        if let style = Runtime.shared.tabViewStyleStack.last, !style.isEmpty {
            modernParams["style"] = style
        }

        let path = ctx.path
        // Selection: by the tab's `.tag` when it has one (any Hashable),
        // else by index (an Int selection over untagged tabs).
        let tags = entries.map(\.tag)
        @MainActor
        func indexOf(_ value: AnyHashable) -> Int? {
            if let i = tags.firstIndex(where: { $0 == value }) { return i }
            if let raw = value.base as? Int, !entries.indices.contains(where: { tags[$0] != nil }) { return raw }
            return nil
        }
        let stored: Int
        if let selection {
            stored = indexOf(selection.get()) ?? 0
        } else {
            stored = Runtime.shared.tabSelection[path] ?? 0
        }
        let index = entries.isEmpty ? 0 : min(max(0, stored), entries.count - 1)

        // Selected tab content, expanded to fill the area above the bar.
        let selectedView: any View = entries.isEmpty ? EmptyView() : entries[index].content
        var contentCtx = ctx.descend("tab\(index)")
        let contentNode = buildNode(view: selectedView, ctx: &contentCtx)
        let contentHolder = RenderNode.box(child: contentNode)
        contentHolder.expandsWidth = true
        contentHolder.expandsHeight = true
        contentHolder.alignment = .topLeading

        // Bottom tab bar: a native host component (an HTML bar on web, a
        // bottom navigation bar on Android). Each tab's icon (a bundled asset)
        // and label are extracted from its `.tabItem` and passed to the host;
        // taps report the selected index back through the host-view channel.
        var params: [String: String] = [
            "count": String(entries.count), "selected": String(index),
            "dark": Runtime.shared.colorScheme == .dark ? "1" : "0",
        ]
        params.merge(modernParams) { _, new in new }
        if modernEntries == nil {
            for (i, entry) in entries.enumerated() {
                var itemCtx = ctx.descend("tabitem\(i)")
                let labelNode = buildNode(view: entry.label, ctx: &itemCtx)
                params["label\(i)"] = firstTextIn(labelNode) ?? ""
                params["icon\(i)"] = firstImageSourceIn(labelNode) ?? ""
                if let symbol = firstSymbolIn(labelNode) { params["symbol\(i)"] = symbol }
            }
        }
        let binding = selection
        let select: (Int) -> Void = { newIndex in
            if let binding {
                binding.set(tags.indices.contains(newIndex) ? (tags[newIndex] ?? AnyHashable(newIndex)) : AnyHashable(newIndex))
            } else {
                Runtime.shared.tabSelection[path] = newIndex
            }
        }
        let declaredEntries = modernEntries
        let currentEntries = arranged
        let handle: (String) -> Void = { value in
            if value.hasPrefix("reorder:") {
                guard let customization, let declaredEntries,
                      let next = TabViewCustomization(wire: String(value.dropFirst(8)))
                else { return }
                // Keep the same tab selected across the reorder.
                if let current = currentEntries, index < current.count {
                    let selected = current[index]
                    let reordered = _arrangeTabs(declaredEntries, next)
                    if let newIndex = reordered.firstIndex(where: {
                        $0.id == selected.id && $0.title == selected.title && $0.section == selected.section
                    }) {
                        select(newIndex)
                    }
                }
                customization.wrappedValue = next
                return
            }
            guard let newIndex = Int(value) else { return }
            select(newIndex)
        }
        // Hosts with native tab containers get the SEMANTIC form: a `tabs`
        // node carrying the items as params and the selected tab's content
        // as its only child — the host mounts its real tab component (a real
        // TabView on Apple) and reports selection through the same channel.
        if Renderer.hostRendersNavigation {
            let spec = HostViewSpec(
                id: path + "#tabs",
                kind: "tabs",
                params: params,
                value: String(index),
                options: [],
                onChange: handle
            )
            let node = RenderNode(kind: .hostView(spec))
            node.identityPath = path + "#tabs"
            node.children = [contentHolder]
            node.expandsWidth = true
            node.expandsHeight = true
            node.ownsNavigation = true
            return node
        }

        // Canonical semantic node: component systems build the native tab
        // bar; the self-drawing path swaps in DrawnTabBar via chrome
        // expansion (the params round-trip the items).
        let barSpec = HostViewSpec(
            id: path + "#tabbar",
            kind: "tabbar",
            params: params,
            value: String(index),
            options: [],
            onChange: handle
        )
        let barBox = RenderNode(kind: .hostView(barSpec))
        barBox.identityPath = path + "#tabbar"
        barBox.fixedHeight = 56
        barBox.expandsWidth = true

        let root = RenderNode(kind: .stack(.vertical))
        root.stackSpacing = 0
        root.children = [contentHolder, barBox]
        root.identityPath = path
        root.ownsNavigation = true
        return root
    }
}

private func collectTabEntries(
    _ view: any View,
    into entries: inout [(label: any View, content: any View, tag: AnyHashable?)],
    tag: AnyHashable? = nil
) {
    // `.tabItem { … }.tag(v)` (either order): the tag wraps or is wrapped by
    // the tab item; unwrap and carry it.
    if let tagged = view as? _AnyTaggedView {
        collectTabEntries(tagged.content, into: &entries, tag: tagged.tagValue)
        return
    }
    if let item = view as? _AnyTabItem {
        var inner: [(label: any View, content: any View, tag: AnyHashable?)] = []
        collectTabEntries(item._contentView, into: &inner, tag: tag)
        entries.append((label: item._barLabel, content: item._contentView, tag: inner.first?.tag ?? tag))
        return
    }
    if let multi = view as? _MultiView {
        for entry in multi.childViews() {
            collectTabEntries(entry.view, into: &entries, tag: tag)
        }
        return
    }
    entries.append((label: EmptyView(), content: view, tag: tag))
}

private func filledBar(_ color: Color) -> RenderNode {
    RenderNode(kind: .shape(.rectangle, fill: color, stroke: nil))
}

/// One tab's drawn-bar info (label + bundled icon asset), collected from each
/// `.tabItem` for `DrawnTabBar`.
struct WindowsTabItem {
    let label: String
    let icon: String
}

/// Display-list bottom tab bar for the self-drawing renderers. Each tab shows
/// its icon above its label and switches the selection on tap; the selected
/// tab is tinted with the accent color — identical on every GPU backend.
struct DrawnTabBar {
    let items: [WindowsTabItem]
    let selected: Int
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(white: 0, opacity: 0.1))
                .frame(height: 1)
            HStack(spacing: 0) {
                ForEach(0 ..< items.count, id: \.self) { i in
                    Button(action: { onSelect(i) }) {
                        VStack(spacing: 3) {
                            if !items[i].icon.isEmpty {
                                Image(items[i].icon)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 24, height: 24)
                            }
                            Text(items[i].label)
                                .font(.system(size: 11))
                        }
                        .foregroundColor(i == selected ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.barBackground)
    }
}

// MARK: - Menu

/// A pop-up menu of actions. Shells out to the platform's native menu widget
/// (an HTML `<select>` on web, a Spinner-backed pop-up on Android); on Apple
/// the real SwiftUI `Menu` is used.
public struct Menu<Label: View, Content: View> {
    let label: Label
    let content: Content

    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content()
        self.label = label()
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension Menu where Label == Text {
    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        let title = String(title)
        self.label = Text(title)
        self.content = content()
    }
}

extension Menu: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var items: [(title: String, symbol: String?, role: ButtonRole?, action: () -> Void)] = []
        collectMenuButtons(content, ctx: &ctx, into: &items)

        // The label, built once: its words name the menu; a label that is
        // more than its words (an icon beside them, a chevron, a symbol in
        // a circle) is drawn as the app made it.
        var labelCtx = ctx.descend("menulabel")
        let labelNode = buildNode(view: label, ctx: &labelCtx)
        let words = firstTextIn(labelNode) ?? ""
        let labelText = words.isEmpty ? "Menu" : words
        let plainWords: Bool = {
            guard case .text = labelNode.kind else { return false }
            return labelNode.symbolName == nil && labelNode.children.isEmpty
        }()
        let actions = items
        var params = ["label": labelText]
        // The items' icons (`Button("Camera", systemImage: "camera")`),
        // newline-separated, "" for none.
        if items.contains(where: { $0.symbol != nil }) {
            params["symbols"] = items.map { $0.symbol ?? "" }.joined(separator: "\n")
        }
        // Their roles ("destructive" drawn red, as SwiftUI's), "" for none.
        if items.contains(where: { $0.role != nil }) {
            params["roles"] = items.map { $0.role?.wireName ?? "" }.joined(separator: "\n")
        }
        // `.menuIndicator(.hidden)`: no chevron beside the label.
        if ctx.env.menuIndicatorHidden { params["indicator"] = "hidden" }
        // Canonical semantic node; the self-drawing path swaps in
        // DrawnPopUpList via chrome expansion.
        let spec = HostViewSpec(
            id: ctx.path,
            kind: "menu",
            params: params,
            value: "0",
            // Index 0 is the label/placeholder; 1... are the actions.
            options: [labelText] + items.map { $0.title },
            onChange: { raw in
                if let idx = Int(raw), idx >= 1, idx - 1 < actions.count {
                    actions[idx - 1].action()
                }
            }
        )
        let node = RenderNode(kind: .hostView(spec))
        node.identityPath = ctx.path
        // A label of the app's own (a gauge, an avatar, an icon beside the
        // words) is drawn as such; words alone travel in the params (Visor's
        // queued pill showed only "2 queued", in the menu's tint, without its
        // clock and chevrons).
        if !plainWords {
            node.children = [labelNode]
        }
        node.identityPath = ctx.path
        return node
    }
}

/// Exposes a Button's action and label for collection inside a Menu.
protocol _AnyButton {
    var _action: () -> Void { get }
    var _labelView: any View { get }
    var _role: ButtonRole? { get }
}

@MainActor
private func collectMenuButtons(
    _ view: any View,
    ctx: inout BuildContext,
    into items: inout [(title: String, symbol: String?, role: ButtonRole?, action: () -> Void)]
) {
    if let button = view as? _AnyButton {
        var sub = ctx.descend("lbl")
        let node = buildNode(view: button._labelView, ctx: &sub)
        items.append((title: firstTextIn(node) ?? "", symbol: firstSymbolName(node), role: button._role, action: button._action))
        return
    }
    if let multi = view as? _MultiView {
        for entry in multi.childViews() {
            var sub = ctx.descend(entry.suffix)
            collectMenuButtons(entry.view, ctx: &sub, into: &items)
        }
        return
    }
}

/// Builds a view and returns the first text run it contains (for labels).
@MainActor
func firstTextOf(_ view: any View, ctx: inout BuildContext) -> String {
    var sub = ctx.descend("lbl")
    let node = buildNode(view: view, ctx: &sub)
    return firstTextIn(node) ?? ""
}

/// The first text in a node tree, skipping symbol glyphs (a Label's icon
/// is a text node too; its title is the text wanted).
func firstTextIn(_ node: RenderNode) -> String? {
    if case .text(let string) = node.kind, node.symbolName == nil { return string }
    for child in node.children {
        if let found = firstTextIn(child) { return found }
    }
    return nil
}

/// The first image source (bundled asset name) in a node tree, for tab icons.
func firstImageSourceIn(_ node: RenderNode) -> String? {
    if case .image(let source, _, _, _) = node.kind { return source }
    for child in node.children {
        if let found = firstImageSourceIn(child) { return found }
    }
    return nil
}

// MARK: - searchable

public struct SearchFieldPlacement: Sendable {
    enum Kind: Hashable, Sendable { case automatic, navigationBarDrawer, toolbar, sidebar, toolbarPrincipal }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    public static let automatic = SearchFieldPlacement(.automatic)
    public static let navigationBarDrawer = SearchFieldPlacement(.navigationBarDrawer)
    public static let toolbar = SearchFieldPlacement(.toolbar)
    public static let sidebar = SearchFieldPlacement(.sidebar)
    public static let toolbarPrincipal = SearchFieldPlacement(.toolbarPrincipal)
}

struct _SearchableView<Content: View> {
    let content: Content
    let text: Binding<String>
    let prompt: String

    var body: some View {
        // Register the search with the enclosing navigation header (below the
        // large title, like iOS); the header emits the canonical `search`
        // host-view node — a native field under component systems, the drawn
        // field via chrome expansion on the self-drawing path.
        _RegisterSearch(content: content, text: text, prompt: prompt)
    }
}

/// Records the search spec for the enclosing native list while building content.
struct _RegisterSearch<Content: View>: _PrimitiveView {
    let content: Content
    let text: Binding<String>
    let prompt: String

    typealias Body = Never
    var body: Never { fatalError("primitive view") }

    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let binding = text, prompt = prompt
        Runtime.shared.registerFrameEffect {
            Runtime.shared.pendingSearch = SearchSpec(
                prompt: prompt, get: { binding.wrappedValue },
                set: { binding.wrappedValue = $0 })
        }
        // `\.isSearching` (a query in the field) and `\.dismissSearch` (clears
        // it) for the content; at the same place in the tree as before.
        var sub = ctx
        sub.env.isSearching = !binding.wrappedValue.isEmpty
        sub.env.dismissSearch = DismissSearchAction(action: { binding.wrappedValue = "" })
        return buildNode(view: content, ctx: &sub)
    }
}

extension View {
    nonisolated public func searchable(
        text: Binding<String>,
        placement: SearchFieldPlacement = .automatic,
        prompt: Text? = nil
    ) -> some View {
        _SearchableView(content: self, text: text, prompt: prompt.map { _extractText($0) } ?? "Search")
    }

    nonisolated public func searchable<S: StringProtocol>(
        text: Binding<String>,
        placement: SearchFieldPlacement = .automatic,
        prompt: S
    ) -> some View {
        _SearchableView(content: self, text: text, prompt: String(prompt))
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension ProgressView: View {}
extension GeometryReader: View {}
extension _TabItemView: View {}
extension TabView: View {}
extension DrawnTabBar: View {}
extension Menu: View {}
extension _SearchableView: View {}
extension _RegisterSearch: View {}
