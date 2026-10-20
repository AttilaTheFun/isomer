// The modern TabView API (iOS 18 / macOS 15 shape): `Tab` / `TabSection`
// declared through a `TabContentBuilder`, plus `.tabViewStyle(.sidebarAdaptable)`.
// `Tab(_:systemImage:content:)` and `TabSection(_:content:)` (helpers type
// as `some TabContent<Never>`), and with a selection: `Tab(_:systemImage:
// value:content:)` in `TabView(selection:)`, each tab selected by its value
// as a classic tab is by its `.tag`.
//
// Semantics on the wire: the same semantic `tabs` host-view node the classic
// `.tabItem` path emits, extended with `glyph<i>` (the SF-symbol's mapped
// text glyph), `section<i>` (the enclosing TabSection's title, "" when
// ungrouped), and `style` ("sidebarAdaptable"). Hosts that understand the
// style render a sidebar on wide canvases (sections as groups) and a bottom
// bar on narrow ones; hosts that don't fall back to the bottom bar.


// MARK: - TabContent

/// The modern tab-declaration protocol. `TabValue` mirrors Apple's shape so
/// `some TabContent<Never>` spells; only the selectionless `Never` form is
/// supported.
public protocol TabContent<TabValue> {
    associatedtype TabValue: Hashable
}

/// One flattened tab: its bar label, the enclosing section title (empty when
/// ungrouped), and the content to show while selected.
struct _TabEntry {
    var title: String
    var systemImage: String
    var section: String
    var content: any View
    /// `.customizationID` of the tab / its section ("" when none).
    var id: String = ""
    var sectionID: String = ""
    /// `.customizationBehavior(.disabled, for: .sidebar)`: pinned in place.
    var fixed = false
    var sectionFixed = false
    /// `Tab(value:)`: what `TabView(selection:)` selects it by.
    var value: AnyHashable? = nil

    /// Key that groups consecutive entries into one sidebar root item.
    var rootKey: String {
        if !sectionID.isEmpty { return "s:" + sectionID }
        if !section.isEmpty { return "t:" + section }
        return "tab:" + id + "|" + title
    }
}

/// Internal collection hook (mirrors `_AnyTabItem` for the classic path).
protocol _AnyTabContent {
    func _collectTabs(section: String, sectionID: String, into entries: inout [_TabEntry])
}

public struct Tab<Value: Hashable, Content: View>: TabContent, _AnyTabContent {
    public typealias TabValue = Value

    let title: String
    let systemImage: String
    let content: Content
    var cid = ""
    var pinned = false
    var value: AnyHashable? = nil

    /// A tab `TabView(selection:)` selects by `value`.
    public init<S: StringProtocol>(
        _ title: S, systemImage: String, value: Value,
        @ViewBuilder content: () -> Content
    ) {
        self.title = String(title)
        self.systemImage = systemImage
        self.content = content()
        self.value = AnyHashable(value)
    }

    public init<S: StringProtocol>(
        _ title: S, systemImage: String,
        @ViewBuilder content: () -> Content
    ) where Value == Never {
        self.init(tabTitle: String(title), systemImage: systemImage, content: content)
    }

    public init(@ViewBuilder content: () -> Content) where Value == Never {
        self.init(tabTitle: "", systemImage: "", content: content)
    }

    init(tabTitle title: String, systemImage: String, @ViewBuilder content: () -> Content) where Value == Never {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    func _collectTabs(section: String, sectionID: String, into entries: inout [_TabEntry]) {
        entries.append(_TabEntry(
            title: title, systemImage: systemImage,
            section: section, content: content, id: cid, sectionID: sectionID,
            fixed: pinned, sectionFixed: _TabCollectionContext.sectionPinned, value: value))
    }
}

/// Section pin state threaded to the tabs being collected (sections don't
/// nest, so a single slot suffices).
enum _TabCollectionContext {
    static var sectionPinned = false
}

public struct TabCustomizationBehavior: Sendable, Equatable {
    enum Kind: Hashable, Sendable { case automatic, disabled, reorderable }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    public static let automatic = TabCustomizationBehavior(.automatic)
    public static let disabled = TabCustomizationBehavior(.disabled)
    public static let reorderable = TabCustomizationBehavior(.reorderable)
}

public struct AdaptableTabBarPlacement: Sendable, Hashable {
    enum Kind: Hashable, Sendable { case automatic, sidebar, tabBar }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    public static let automatic = AdaptableTabBarPlacement(.automatic)
    public static let sidebar = AdaptableTabBarPlacement(.sidebar)
    public static let tabBar = AdaptableTabBarPlacement(.tabBar)
}

public struct TabSection<Content: TabContent>: TabContent, _AnyTabContent {
    public typealias TabValue = Content.TabValue

    let title: String
    let content: Content
    var cid = ""
    var pinned = false

    public init<S: StringProtocol>(_ title: S, @TabContentBuilder<Content.TabValue> content: () -> Content) {
        let title = String(title)
        self.title = title
        self.content = content()
    }

    func _collectTabs(section: String, sectionID: String, into entries: inout [_TabEntry]) {
        // Sections don't nest in this subset; the innermost title wins.
        _TabCollectionContext.sectionPinned = pinned
        defer { _TabCollectionContext.sectionPinned = false }
        (content as? _AnyTabContent)?._collectTabs(
            section: title, sectionID: cid, into: &entries)
    }
}

/// A tab or a section with its customization: its `TabViewCustomization`
/// identity (`.customizationID`, the container key for a section's tabs),
/// and whether `.customizationBehavior(.disabled, for: .sidebar)` pins it
/// in place.
protocol _CustomizableTab {
    func _customized(id: String?, pinned: Bool?) -> any TabContent
}

extension Tab: _CustomizableTab {
    func _customized(id: String?, pinned: Bool?) -> any TabContent {
        var copy = self
        if let id { copy.cid = id }
        if let pinned { copy.pinned = pinned }
        return copy
    }
}

extension TabSection: _CustomizableTab {
    func _customized(id: String?, pinned: Bool?) -> any TabContent {
        var copy = self
        if let id { copy.cid = id }
        if let pinned { copy.pinned = pinned }
        return copy
    }
}

/// Tab content with a customization applied.
struct _CustomizedTab<Base: TabContent>: TabContent, _AnyTabContent {
    typealias TabValue = Base.TabValue
    let content: any TabContent

    func _collectTabs(section: String, sectionID: String, into entries: inout [_TabEntry]) {
        (content as? _AnyTabContent)?._collectTabs(section: section, sectionID: sectionID, into: &entries)
    }
}

extension TabContent {
    /// `TabViewCustomization` identity; tabs without one keep their
    /// declared position when the user reorders the sidebar. A section's is
    /// the key its tabs' order is kept under.
    nonisolated public func customizationID(_ id: String) -> some TabContent<TabValue> {
        _CustomizedTab<Self>(content: (self as? _CustomizableTab)?._customized(id: id, pinned: nil) ?? self)
    }

    /// `.disabled` for `.sidebar` (or `.automatic`) pins the tab or the
    /// section: it is not draggable and keeps its declared position while
    /// others reorder.
    nonisolated public func customizationBehavior(
        _ behavior: TabCustomizationBehavior, for placements: AdaptableTabBarPlacement...
    ) -> some TabContent<TabValue> {
        let pinned: Bool? = placements.contains(where: { $0 != .tabBar }) ? behavior == .disabled : nil
        return _CustomizedTab<Self>(content: (self as? _CustomizableTab)?._customized(id: nil, pinned: pinned) ?? self)
    }
}

/// A block's tabs, whatever their types (what Apple's builder makes a
/// tuple of): Isomer collects them in order.
struct TabContentList<TabValue: Hashable>: TabContent, _AnyTabContent {
    let parts: [any TabContent]

    func _collectTabs(section: String, sectionID: String, into entries: inout [_TabEntry]) {
        for part in parts {
            (part as? _AnyTabContent)?._collectTabs(
                section: section, sectionID: sectionID, into: &entries)
        }
    }
}

/// Tab content of any type, behind one (Apple's `AnyTabContent`).
public struct AnyTabContent<SelectionValue: Hashable>: TabContent, _AnyTabContent {
    public typealias TabValue = SelectionValue
    let content: any TabContent

    public init<C: TabContent>(_ content: C) where C.TabValue == SelectionValue {
        self.content = content
    }

    func _collectTabs(section: String, sectionID: String, into entries: inout [_TabEntry]) {
        (content as? _AnyTabContent)?._collectTabs(section: section, sectionID: sectionID, into: &entries)
    }
}

/// An `if`/`else` in a builder: the tabs of the branch taken.
extension _ConditionalContent: TabContent
where TrueContent: TabContent, FalseContent: TabContent, TrueContent.TabValue == FalseContent.TabValue {
    public typealias TabValue = TrueContent.TabValue
}

extension _ConditionalContent: _AnyTabContent
where TrueContent: TabContent, FalseContent: TabContent, TrueContent.TabValue == FalseContent.TabValue {
    func _collectTabs(section: String, sectionID: String, into entries: inout [_TabEntry]) {
        switch storage {
        case .trueContent(let content):
            (content as? _AnyTabContent)?._collectTabs(section: section, sectionID: sectionID, into: &entries)
        case .falseContent(let content):
            (content as? _AnyTabContent)?._collectTabs(section: section, sectionID: sectionID, into: &entries)
        }
    }
}

/// An `if` without an `else` in a builder: its tabs when the condition held.
extension Optional: TabContent where Wrapped: TabContent {
    public typealias TabValue = Wrapped.TabValue
}

extension Optional: _AnyTabContent where Wrapped: TabContent {
    func _collectTabs(section: String, sectionID: String, into entries: inout [_TabEntry]) {
        if case .some(let content) = self {
            (content as? _AnyTabContent)?._collectTabs(section: section, sectionID: sectionID, into: &entries)
        }
    }
}

/// Apple's builder, with Apple's signatures; each block is a `some
/// TabContent<TabValue>`, an `if`/`else` a `_ConditionalContent`.
@resultBuilder
public struct TabContentBuilder<TabValue: Hashable> {
    public static func buildExpression(_ content: some TabContent<TabValue>) -> some TabContent<TabValue> {
        content
    }

    public static func buildBlock(_ content: some TabContent<TabValue>) -> some TabContent<TabValue> {
        content
    }

    public static func buildIf(_ content: (some TabContent<TabValue>)?) -> (some TabContent<TabValue>)? {
        content
    }

    public static func buildEither<TrueContent: TabContent, FalseContent: TabContent>(
        first: TrueContent
    ) -> _ConditionalContent<TrueContent, FalseContent>
    where TrueContent.TabValue == TabValue, FalseContent.TabValue == TabValue {
        _ConditionalContent(storage: .trueContent(first))
    }

    public static func buildEither<TrueContent: TabContent, FalseContent: TabContent>(
        second: FalseContent
    ) -> _ConditionalContent<TrueContent, FalseContent>
    where TrueContent.TabValue == TabValue, FalseContent.TabValue == TabValue {
        _ConditionalContent(storage: .falseContent(second))
    }

    public static func buildLimitedAvailability<T: TabContent>(_ content: T) -> AnyTabContent<T.TabValue> {
        AnyTabContent(content)
    }
}

extension TabContentBuilder {
    public static func buildBlock<C0: TabContent, C1: TabContent>(_ c0: C0, _ c1: C1) -> some TabContent<TabValue>
    where TabValue == C0.TabValue, C0.TabValue == C1.TabValue {
        TabContentList<TabValue>(parts: [c0, c1])
    }

    public static func buildBlock<C0: TabContent, C1: TabContent, C2: TabContent>(_ c0: C0, _ c1: C1, _ c2: C2) -> some TabContent<TabValue>
    where TabValue == C0.TabValue, C0.TabValue == C1.TabValue, C1.TabValue == C2.TabValue {
        TabContentList<TabValue>(parts: [c0, c1, c2])
    }

    public static func buildBlock<C0: TabContent, C1: TabContent, C2: TabContent, C3: TabContent>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3) -> some TabContent<TabValue>
    where TabValue == C0.TabValue, C0.TabValue == C1.TabValue, C1.TabValue == C2.TabValue, C2.TabValue == C3.TabValue {
        TabContentList<TabValue>(parts: [c0, c1, c2, c3])
    }

    public static func buildBlock<C0: TabContent, C1: TabContent, C2: TabContent, C3: TabContent, C4: TabContent>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4) -> some TabContent<TabValue>
    where TabValue == C0.TabValue, C0.TabValue == C1.TabValue, C1.TabValue == C2.TabValue, C2.TabValue == C3.TabValue, C3.TabValue == C4.TabValue {
        TabContentList<TabValue>(parts: [c0, c1, c2, c3, c4])
    }

    public static func buildBlock<C0: TabContent, C1: TabContent, C2: TabContent, C3: TabContent, C4: TabContent, C5: TabContent>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5) -> some TabContent<TabValue>
    where TabValue == C0.TabValue, C0.TabValue == C1.TabValue, C1.TabValue == C2.TabValue, C2.TabValue == C3.TabValue, C3.TabValue == C4.TabValue, C4.TabValue == C5.TabValue {
        TabContentList<TabValue>(parts: [c0, c1, c2, c3, c4, c5])
    }

    public static func buildBlock<C0: TabContent, C1: TabContent, C2: TabContent, C3: TabContent, C4: TabContent, C5: TabContent, C6: TabContent>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6) -> some TabContent<TabValue>
    where TabValue == C0.TabValue, C0.TabValue == C1.TabValue, C1.TabValue == C2.TabValue, C2.TabValue == C3.TabValue, C3.TabValue == C4.TabValue, C4.TabValue == C5.TabValue, C5.TabValue == C6.TabValue {
        TabContentList<TabValue>(parts: [c0, c1, c2, c3, c4, c5, c6])
    }

    public static func buildBlock<C0: TabContent, C1: TabContent, C2: TabContent, C3: TabContent, C4: TabContent, C5: TabContent, C6: TabContent, C7: TabContent>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7) -> some TabContent<TabValue>
    where TabValue == C0.TabValue, C0.TabValue == C1.TabValue, C1.TabValue == C2.TabValue, C2.TabValue == C3.TabValue, C3.TabValue == C4.TabValue, C4.TabValue == C5.TabValue, C5.TabValue == C6.TabValue, C6.TabValue == C7.TabValue {
        TabContentList<TabValue>(parts: [c0, c1, c2, c3, c4, c5, c6, c7])
    }

    public static func buildBlock<C0: TabContent, C1: TabContent, C2: TabContent, C3: TabContent, C4: TabContent, C5: TabContent, C6: TabContent, C7: TabContent, C8: TabContent>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7, _ c8: C8) -> some TabContent<TabValue>
    where TabValue == C0.TabValue, C0.TabValue == C1.TabValue, C1.TabValue == C2.TabValue, C2.TabValue == C3.TabValue, C3.TabValue == C4.TabValue, C4.TabValue == C5.TabValue, C5.TabValue == C6.TabValue, C6.TabValue == C7.TabValue, C7.TabValue == C8.TabValue {
        TabContentList<TabValue>(parts: [c0, c1, c2, c3, c4, c5, c6, c7, c8])
    }

    public static func buildBlock<C0: TabContent, C1: TabContent, C2: TabContent, C3: TabContent, C4: TabContent, C5: TabContent, C6: TabContent, C7: TabContent, C8: TabContent, C9: TabContent>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7, _ c8: C8, _ c9: C9) -> some TabContent<TabValue>
    where TabValue == C0.TabValue, C0.TabValue == C1.TabValue, C1.TabValue == C2.TabValue, C2.TabValue == C3.TabValue, C3.TabValue == C4.TabValue, C4.TabValue == C5.TabValue, C5.TabValue == C6.TabValue, C6.TabValue == C7.TabValue, C7.TabValue == C8.TabValue, C8.TabValue == C9.TabValue {
        TabContentList<TabValue>(parts: [c0, c1, c2, c3, c4, c5, c6, c7, c8, c9])
    }
}

// MARK: - TabView(tabs:) + style

extension TabView where Content == EmptyView {
    /// The modern declaration: `TabView { Tab(...); TabSection("…") { … } }`.
    public init<C: TabContent>(@TabContentBuilder<Never> content: () -> C) where C.TabValue == Never {
        var entries: [_TabEntry] = []
        (content() as? _AnyTabContent)?._collectTabs(section: "", sectionID: "", into: &entries)
        self.init(modernEntries: entries)
    }

    /// The modern declaration with a selection: each `Tab(value:)` is
    /// selected by its value.
    public init<SelectionValue: Hashable, C: TabContent>(
        selection: Binding<SelectionValue>, @TabContentBuilder<SelectionValue> content: () -> C
    ) where C.TabValue == SelectionValue {
        var entries: [_TabEntry] = []
        (content() as? _AnyTabContent)?._collectTabs(section: "", sectionID: "", into: &entries)
        self.init(modernEntries: entries, selection: (
            get: { AnyHashable(selection.wrappedValue) },
            set: { value in if let typed = value.base as? SelectionValue { selection.wrappedValue = typed } }))
    }
}

/// A TabView's style. `.tabBarOnly` (the iPad/macOS-15 shape) renders the
/// tabs as a centered segmented pill at the TOP of the TabView (web
/// react); other hosts keep the bottom bar.
public protocol TabViewStyle {
}

public struct DefaultTabViewStyle: TabViewStyle, NamedStyle {
    nonisolated public init() {}
    var styleName: String { "" }
}

public struct SidebarAdaptableTabViewStyle: TabViewStyle, NamedStyle {
    nonisolated public init() {}
    var styleName: String { "sidebarAdaptable" }
}

public struct TabBarOnlyTabViewStyle: TabViewStyle, NamedStyle {
    nonisolated public init() {}
    var styleName: String { "tabBarOnly" }
}

public struct GroupedTabViewStyle: TabViewStyle, NamedStyle {
    nonisolated public init() {}
    var styleName: String { "grouped" }
}

extension TabViewStyle where Self == DefaultTabViewStyle {
    nonisolated public static var automatic: DefaultTabViewStyle { DefaultTabViewStyle() }
}

extension TabViewStyle where Self == SidebarAdaptableTabViewStyle {
    nonisolated public static var sidebarAdaptable: SidebarAdaptableTabViewStyle { SidebarAdaptableTabViewStyle() }
}

extension TabViewStyle where Self == TabBarOnlyTabViewStyle {
    nonisolated public static var tabBarOnly: TabBarOnlyTabViewStyle { TabBarOnlyTabViewStyle() }
}

extension TabViewStyle where Self == GroupedTabViewStyle {
    nonisolated public static var grouped: GroupedTabViewStyle { GroupedTabViewStyle() }
}

/// Pages swiped sideways.
public struct PageTabViewStyle: TabViewStyle, NamedStyle {
    /// Whether the page dots show.
    public struct IndexDisplayMode: Sendable {
        let name: String
        public static let automatic = IndexDisplayMode(name: "automatic")
        public static let always = IndexDisplayMode(name: "always")
        public static let never = IndexDisplayMode(name: "never")
    }

    nonisolated public init(indexDisplayMode: PageTabViewStyle.IndexDisplayMode = .automatic) {}
    var styleName: String { "page" }
}

extension TabViewStyle where Self == PageTabViewStyle {
    nonisolated public static var page: PageTabViewStyle { PageTabViewStyle() }
    nonisolated public static func page(indexDisplayMode: PageTabViewStyle.IndexDisplayMode) -> PageTabViewStyle {
        PageTabViewStyle(indexDisplayMode: indexDisplayMode)
    }
}

extension View {
    /// Style for the ENCLOSED TabView. `sidebarAdaptable` renders a sidebar
    /// (sections as groups) on wide canvases and a bottom bar on narrow ones
    /// under hosts that support it; others keep the bottom bar.
    nonisolated public func tabViewStyle<S: TabViewStyle>(_ style: S) -> some View {
        _TabViewStyleView(content: self, style: styleName(style, otherwise: ""))
    }
}

struct _TabViewStyleView<Content: View> {
    let content: Content
    let style: String

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _TabViewStyleView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        Runtime.shared.tabViewStyleStack.append(style)
        defer { Runtime.shared.tabViewStyleStack.removeLast() }
        var sub = ctx.descend("tabstyle")
        return buildNode(view: content, ctx: &sub)
    }
}

// MARK: - TabViewCustomization

/// The user's sidebar arrangement for a `.sidebarAdaptable` TabView: the
/// order of root items (ungrouped tabs and sections) and the order of tabs
/// inside each section, keyed by `.customizationID`. Codable, so
/// `@AppStorage` persists it; on the wire (to hosts, and coded) it is
/// `":root,ids;sectionID:tab,ids;…"` (root container first, then sections
/// by id). Items without a customization ID keep their declared position.
public struct TabViewCustomization: Equatable, Codable, Sendable {
    /// Ordered IDs per container: "" is the sidebar root.
    var orders: [String: [String]] = [:]

    public init() {}

    public init(from decoder: any Decoder) throws {
        self = TabViewCustomization(wire: try decoder.singleValueContainer().decode(String.self)) ?? TabViewCustomization()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wire)
    }

    init?(wire rawValue: String) {
        for container in rawValue.split(separator: ";", omittingEmptySubsequences: true) {
            guard let colon = container.firstIndex(of: ":") else { return nil }
            let key = String(container[container.startIndex..<colon])
            let ids = container[container.index(after: colon)...]
                .split(separator: ",", omittingEmptySubsequences: true).map(String.init)
            if !ids.isEmpty { orders[key] = ids }
        }
    }

    var wire: String {
        var parts: [String] = []
        if let root = orders[""], !root.isEmpty {
            parts.append(":" + root.joined(separator: ","))
        }
        for key in orders.keys.filter({ !$0.isEmpty }).sorted() {
            if let ids = orders[key], !ids.isEmpty {
                parts.append(key + ":" + ids.joined(separator: ","))
            }
        }
        return parts.joined(separator: ";")
    }

    /// Ordered customization IDs the user arranged in `container` ("" for
    /// the sidebar root, a section's ID for its tabs); nil = declared order.
    package func sidebarOrder(in container: String = "") -> [String]? {
        orders[container]
    }

    /// Every section back in its declared order (and the root).
    public mutating func resetSectionOrder() {
        orders = [:]
    }

    /// The tabs of section `sectionID` back in their declared order.
    public mutating func resetSectionOrder(for sectionID: String) {
        orders[sectionID] = nil
    }

    /// Every tab visible again (tabs are not hidden here: nothing to undo).
    public mutating func resetVisibility() {}
}

/// Applies `customization` to the declared entries: root items (ungrouped
/// tabs, contiguous sections) follow the root order, tabs inside a section
/// follow that section's order. Known IDs come first in arranged order;
/// unknown or ID-less items keep their declared relative order after them.
func _arrangeTabs(_ entries: [_TabEntry], _ customization: TabViewCustomization) -> [_TabEntry] {
    func reorder<T>(
        _ items: [T], by order: [String]?, id: (T) -> String, pinned: (T) -> Bool
    ) -> [T] {
        guard let order, !order.isEmpty else { return items }
        var known: [(Int, T)] = []
        var rest: [T] = []
        var fixed: [(Int, T)] = []
        for (declared, item) in items.enumerated() {
            let key = id(item)
            if pinned(item) {
                fixed.append((declared, item))
            } else if !key.isEmpty, let pos = order.firstIndex(of: key) {
                known.append((pos, item))
            } else {
                rest.append(item)
            }
        }
        var result = known.sorted { $0.0 < $1.0 }.map { $0.1 } + rest
        for (declared, item) in fixed {
            result.insert(item, at: min(declared, result.count))
        }
        return result
    }
    // Group into root items (a section's entries are contiguous).
    var roots: [(id: String, key: String, entries: [_TabEntry])] = []
    for entry in entries {
        if let last = roots.last, last.key == entry.rootKey, !entry.sectionID.isEmpty || !entry.section.isEmpty {
            roots[roots.count - 1].entries.append(entry)
        } else {
            let rootID = entry.section.isEmpty && entry.sectionID.isEmpty ? entry.id : entry.sectionID
            roots.append((id: rootID, key: entry.rootKey, entries: [entry]))
        }
    }
    let ordered = reorder(roots, by: customization.orders[""], id: { $0.id }, pinned: {
        $0.entries[0].sectionID.isEmpty && $0.entries[0].section.isEmpty
            ? $0.entries[0].fixed : $0.entries[0].sectionFixed
    })
    return ordered.flatMap { root -> [_TabEntry] in
        guard !root.id.isEmpty, root.entries.count > 1 || !root.entries[0].sectionID.isEmpty else {
            return root.entries
        }
        return reorder(root.entries, by: customization.orders[root.id], id: { $0.id }, pinned: { $0.fixed })
    }
}

extension View {
    /// Lets the user reorder the ENCLOSED sidebar-adaptable TabView's sidebar
    /// (sections and the tabs within them, by `.customizationID`), storing
    /// the arrangement in `customization`. Hosts that support it (web react)
    /// offer drag-to-reorder; when the binding comes from `@AppStorage`, the
    /// web host also persists the arrangement in `localStorage` under the
    /// storage key so it survives reloads.
    nonisolated public func tabViewCustomization(_ customization: Binding<TabViewCustomization>?) -> some View {
        _TabCustomizationView(content: self, customization: customization)
    }
}

struct _TabCustomizationView<Content: View> {
    let content: Content
    let customization: Binding<TabViewCustomization>?

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _TabCustomizationView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        Runtime.shared.tabCustomizationStack.append(customization)
        defer { Runtime.shared.tabCustomizationStack.removeLast() }
        var sub = ctx.descend("tabcustom")
        return buildNode(view: content, ctx: &sub)
    }
}

// MARK: - Style stubs

/// `.textFieldStyle`: `.plain` strips the host's bezel (no border, no
/// background — the text alone, for a field inside its own bubble);
/// `.roundedBorder` / `.automatic` keep the host's bordered field.
public protocol TextFieldStyle {
}

public struct DefaultTextFieldStyle: TextFieldStyle, NamedStyle {
    public init() {}
    var styleName: String { "automatic" }
}

public struct PlainTextFieldStyle: TextFieldStyle, NamedStyle {
    public init() {}
    var styleName: String { "plain" }
}

public struct RoundedBorderTextFieldStyle: TextFieldStyle, NamedStyle {
    public init() {}
    var styleName: String { "roundedBorder" }
}

extension TextFieldStyle where Self == DefaultTextFieldStyle {
    public static var automatic: DefaultTextFieldStyle { DefaultTextFieldStyle() }
}

extension TextFieldStyle where Self == PlainTextFieldStyle {
    public static var plain: PlainTextFieldStyle { PlainTextFieldStyle() }
}

extension TextFieldStyle where Self == RoundedBorderTextFieldStyle {
    public static var roundedBorder: RoundedBorderTextFieldStyle { RoundedBorderTextFieldStyle() }
}

extension View {
    nonisolated public func textFieldStyle<S: TextFieldStyle>(_ style: S) -> some View {
        let name = styleName(style, otherwise: "automatic")
        return _EnvironmentModifier(child: self, descend: "fieldstyle") { env in env.textFieldStyle = name }
    }
}

/// `.listStyle`: `.plain` puts rows straight on the page with hairlines
/// between them (Messages' inbox); `.insetGrouped` / `.grouped` / `.inset`
/// keep the grouped card; `.sidebar` is the split view's column style;
/// `.automatic` lets the host choose.
public protocol ListStyle {
}

public struct DefaultListStyle: ListStyle, NamedStyle {
    public init() {}
    var styleName: String { "automatic" }
}

public struct PlainListStyle: ListStyle, NamedStyle {
    public init() {}
    var styleName: String { "plain" }
}

public struct InsetListStyle: ListStyle, NamedStyle {
    public init() {}
    var styleName: String { "inset" }
}

public struct GroupedListStyle: ListStyle, NamedStyle {
    public init() {}
    var styleName: String { "grouped" }
}

public struct InsetGroupedListStyle: ListStyle, NamedStyle {
    public init() {}
    var styleName: String { "insetGrouped" }
}

public struct SidebarListStyle: ListStyle, NamedStyle {
    public init() {}
    var styleName: String { "sidebar" }
}

extension ListStyle where Self == DefaultListStyle {
    public static var automatic: DefaultListStyle { DefaultListStyle() }
}

extension ListStyle where Self == PlainListStyle {
    public static var plain: PlainListStyle { PlainListStyle() }
}

extension ListStyle where Self == InsetListStyle {
    public static var inset: InsetListStyle { InsetListStyle() }
}

extension ListStyle where Self == GroupedListStyle {
    public static var grouped: GroupedListStyle { GroupedListStyle() }
}

extension ListStyle where Self == InsetGroupedListStyle {
    public static var insetGrouped: InsetGroupedListStyle { InsetGroupedListStyle() }
}

extension ListStyle where Self == SidebarListStyle {
    public static var sidebar: SidebarListStyle { SidebarListStyle() }
}

extension View {
    nonisolated public func listStyle<S: ListStyle>(_ style: S) -> some View {
        let name = styleName(style, otherwise: "automatic")
        return _EnvironmentModifier(child: self, descend: "liststyle") { env in env.listStyle = name }
    }

    /// `.listRowSeparator(.hidden)`: no line under this row (or, around the
    /// rows, between them), however deep in the row's content it is applied.
    nonisolated public func listRowSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View {
        _ListRowTrait(child: self, descend: "rowseparator", trait: .separator) { env in env.listRowSeparators = visibility != .hidden }
    }

    /// `.listRowInsets`: a list row's content inset from the cell's edges by
    /// these (`EdgeInsets()`: the content fills the cell); nil, the list's
    /// own insets.
    nonisolated public func listRowInsets(_ insets: EdgeInsets?) -> some View {
        _ListRowTrait(child: self, descend: "rowinsets", trait: .insets) { env in env.listRowInsets = insets }
    }

    /// iOS 26's form: these sides of the row inset by `length` (nil: the
    /// list's own), the others as they were. A side nobody set is the
    /// host's own metric (`EdgeInsets.listDefault`, on the wire "-").
    nonisolated public func listRowInsets(_ edges: Edge.Set = .all, _ length: CGFloat?) -> some View {
        _ListRowTrait(child: self, descend: "rowinsets", trait: .insets) { env in
            let unset = EdgeInsets.listDefault
            var insets = env.listRowInsets ?? EdgeInsets(top: unset, leading: unset, bottom: unset, trailing: unset)
            let value = length ?? unset
            if edges.contains(.top) { insets.top = value }
            if edges.contains(.leading) { insets.leading = value }
            if edges.contains(.bottom) { insets.bottom = value }
            if edges.contains(.trailing) { insets.trailing = value }
            env.listRowInsets = insets
        }
    }

    /// `.listRowBackground`: what a list row's cell is filled with — a
    /// colour (`Color.clear` lets the list's own background through), or a
    /// view, drawn behind the row's content in place of the cell's own fill
    /// and the list's selection look.
    nonisolated public func listRowBackground<V: View>(_ view: V?) -> some View {
        let color = view.flatMap { $0 as? Color }
        let other: AnyView? = color == nil ? view.map { AnyView($0) } : nil
        return _ListRowTrait(child: self, descend: "rowbg", trait: .background) { env in
            env.listRowBackground = color
            env.listRowBackgroundView = other
        }
    }

    /// `.listSectionSeparator(.hidden)`: no lines around a section either.
    nonisolated public func listSectionSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View {
        _EnvironmentModifier(child: self, descend: "sectionseparator") { env in env.listRowSeparators = visibility != .hidden }
    }
}

/// `.listRowInsets` / `.listRowBackground` / `.listRowSeparator`: in the
/// environment for the rows inside (each row of a ForEach takes them), and on
/// the node built for the row it is in, however deep in the row's content it
/// was applied.
struct _ListRowTrait {
    enum Trait {
        case insets, background, separator
    }

    let child: any View
    let descend: String
    let trait: Trait
    let transform: (inout EnvironmentValues) -> Void

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _ListRowTrait: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var sub = ctx.descend(descend)
        transform(&sub.env)
        let node = buildNode(view: child, ctx: &sub)
        node.pinRebuildSite()
        // This trait only (another, applied inside, has marked its own).
        switch trait {
        case .insets:
            node.rowTraitInsets = .some(sub.env.listRowInsets)
        case .separator:
            node.rowTraitSeparator = sub.env.listRowSeparators
        case .background:
            let built = sub.env.listRowBackgroundView.map { view -> RenderNode in
                var background = sub.descend("rowbackground")
                background.env.listRowBackgroundView = nil
                let built = buildNode(view: view, ctx: &background)
                built.expandsWidth = true
                built.expandsHeight = true
                return built
            }
            node.rowTraitBackground = (sub.env.listRowBackground, built)
        }
        return node
    }
}

extension _ListRowTrait: View {}

extension EdgeInsets {
    /// A list row's side left to the host's own metric (by the edge form
    /// of `.listRowInsets`): infinite, which no real inset is, and equal to
    /// itself, so a row's insets still compare.
    static let listDefault: CGFloat = .infinity

    /// These insets with the sides left to the host as `top`… given.
    func resolvingListDefaults(_ base: EdgeInsets) -> EdgeInsets {
        EdgeInsets(top: top.isInfinite ? base.top : top, leading: leading.isInfinite ? base.leading : leading,
                   bottom: bottom.isInfinite ? base.bottom : bottom, trailing: trailing.isInfinite ? base.trailing : trailing)
    }
}

// MARK: - Toolbar / scroll-edge appearance stubs (API compatibility)

public enum Visibility: Sendable, Equatable {
    case automatic
    case visible
    case hidden
}

public struct ToolbarPlacement: Sendable, Equatable {
    let name: String
    public static let automatic = ToolbarPlacement(name: "automatic")
    public static let navigationBar = ToolbarPlacement(name: "navigationBar")
    public static let tabBar = ToolbarPlacement(name: "tabBar")
    public static let bottomBar = ToolbarPlacement(name: "bottomBar")
    public static let windowToolbar = ToolbarPlacement(name: "windowToolbar")
}

/// How a scroll's content is drawn where it passes under a bar (iOS 26):
/// `.soft` fades and blurs it, `.hard` is an opaque band with a line.
public struct ScrollEdgeEffectStyle: Sendable, Hashable {
    enum Kind: Hashable, Sendable { case automatic, soft, hard }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    public static let automatic = ScrollEdgeEffectStyle(.automatic)
    public static let soft = ScrollEdgeEffectStyle(.soft)
    public static let hard = ScrollEdgeEffectStyle(.hard)
}

extension View {
    /// Advisory no-op: bar backgrounds are the host's.
    nonisolated public func toolbarBackgroundVisibility(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View { self }
    nonisolated public func toolbarBackground(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View { self }
    /// How content scrolled under a bar at these edges is drawn: `.soft`
    /// (the default here, as on iOS 26: it fades and blurs and stays
    /// visible), or `.hard` (an opaque band with a line where it ends).
    /// As SwiftUI's, it reaches every scroll view inside this view (a
    /// split view's column, a whole screen), not only one it wraps; the
    /// bars over a scroll read its style. nil goes back to automatic.
    nonisolated public func scrollEdgeEffectStyle(_ style: ScrollEdgeEffectStyle?, for edges: Edge.Set) -> some View {
        _EnvironmentModifier(child: self, descend: "scrolledge") { env in
            if edges.contains(.top) { env.scrollEdgeTop = style }
            if edges.contains(.bottom) { env.scrollEdgeBottom = style }
        }
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension _TabViewStyleView: View {}
extension _TabCustomizationView: View {}
