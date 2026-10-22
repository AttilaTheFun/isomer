// Navigation: a simplified NavigationStack with push/pop, a drawn navigation
// bar, and `.navigationTitle`. The pushed-destination stack persists in
// state storage keyed by the stack's structural identity.

final class NavigationState {
    struct Entry {
        let makeView: () -> any View
        var title: String?
        var subtitle: String?
        /// The value this screen shows (value-based navigation:
        /// `NavigationLink(value:)`, a bound path), nil for a destination's.
        var value: AnyHashable? = nil
    }

    var stack: [Entry] = []
    /// `NavigationStack(path:)`: the bound path, read and written as values.
    /// Set by the stack each build (nil without one).
    var path: (get: () -> [AnyHashable], set: ([AnyHashable]) -> Void)?
    /// `navigationDestination(for:)`: how a value of each type is shown,
    /// registered as the views that declare them build (and kept: the screen
    /// that declared one is not built while a screen above it shows).
    var destinations: [ObjectIdentifier: (AnyHashable) -> any View] = [:]
    var rootTitle: String?
    var rootSubtitle: String?
    /// `ToolbarItem(placement: .bottomBar)` contents declared by the visible
    /// screen; rendered as a bar under the content. Reset every build.
    var bottomBarItems: [any View] = []
    /// A trailing navigation-bar button declared by the visible screen's
    /// `.toolbar { … }`. Recomputed every build (reset before the content runs).
    var trailingTitle: String?
    var trailingAction: (() -> Void)?
    /// Multi-item toolbar (`ToolbarItem(placement:)`): leading (.navigation /
    /// .topBarLeading) and trailing (.primaryAction / .topBarTrailing)
    /// bar buttons, in declaration order. Recomputed every build.
    var leadingItems: [_BarItem] = []
    var trailingItems: [_BarItem] = []
    /// Index into `trailingItems` of the `.principal` item, if any.
    var principalIndex: Int?
    /// A `.principal` item whose label is a view of its own (an avatar, a
    /// pill): hosts draw it in the centre slot instead of its words.
    var principalContent: RenderNode?
    /// `.toolbarTitleDisplayMode` of the visible screen (reset every build).
    var titleDisplayMode: ToolbarTitleDisplayMode = .automatic
    /// Push/pop transition animation state.
    var lastDepth = 0
    var transitionStart: Double = -1
    var lastTransitionWasPush = true

    /// Its storage key ("<stack path>#navigation"): a push or a pop marks it
    /// changed, so the stack is built again (and reused otherwise).
    var key: String?

    func push(_ makeView: @escaping () -> any View) {
        stack.append(Entry(makeView: makeView, title: nil))
        if let key { Runtime.shared.stateDidChange(key: key) }
        Runtime.shared.requestFrame()
    }

    /// `NavigationLink(value:)`: the value onto the bound path, or (no path)
    /// onto the stack's own.
    func push(value: AnyHashable) {
        if let path {
            path.set(path.get() + [value])
        } else {
            stack.append(entry(for: value))
        }
        if let key { Runtime.shared.stateDidChange(key: key) }
        Runtime.shared.requestFrame()
    }

    /// The screen for a value: what the destination for its type makes.
    func entry(for value: AnyHashable) -> Entry {
        Entry(makeView: { [weak self] in self?.destination(for: value) ?? EmptyView() }, title: nil, value: value)
    }

    func destination(for value: AnyHashable) -> (any View)? {
        destinations[ObjectIdentifier(type(of: value.base))]?(value)
    }

    /// The stack as the bound path says it: a screen per value, those still
    /// where they were kept (with their titles); a destination's screens
    /// above them stay while the path under them is the same.
    func followPath() {
        guard let path else { return }
        let values = path.get()
        var entries: [Entry] = []
        for (index, value) in values.enumerated() {
            entries.append(index < stack.count && stack[index].value == value ? stack[index] : entry(for: value))
        }
        let above = stack.dropFirst(values.count)
        if values.count <= stack.count, zip(values, stack).allSatisfy({ $0 == $1.value }), above.allSatisfy({ $0.value == nil }) {
            entries += above
        }
        stack = entries
    }

    func pop() {
        if !stack.isEmpty {
            // A path's screen: the path loses its last value with it.
            if stack.last?.value != nil, let path {
                var values = path.get()
                if !values.isEmpty {
                    values.removeLast()
                    path.set(values)
                }
            }
            stack.removeLast()
            if let key { Runtime.shared.stateDidChange(key: key) }
            Runtime.shared.requestFrame()
        }
    }

    func setTitle(_ title: String, level: Int) {
        if level == 0 {
            rootTitle = title
        } else if level - 1 < stack.count {
            stack[level - 1].title = title
        }
    }

    var currentTitle: String {
        (stack.last?.title ?? (stack.isEmpty ? rootTitle : nil)) ?? ""
    }

    func setSubtitle(_ subtitle: String, level: Int) {
        if level == 0 {
            rootSubtitle = subtitle
        } else if level - 1 < stack.count {
            stack[level - 1].subtitle = subtitle
        }
    }

    var currentSubtitle: String {
        (stack.last?.subtitle ?? (stack.isEmpty ? rootSubtitle : nil)) ?? ""
    }
}

/// Whether a column's built content leads to navigation of its own — a
/// NavigationStack's or a TabView's node — through what only wraps it (the
/// boxes modifiers make); the app's own views, conditionals and groups
/// leave no node of their own. Seen in what was built, so a stack in an
/// app's view's body counts as one written in the column.
func _leadsToOwnNavigation(_ node: RenderNode) -> Bool {
    var current = node
    while true {
        if current.ownsNavigation { return true }
        guard case .box = current.kind, current.children.count == 1 else { return false }
        current = current.children[0]
    }
}

public struct NavigationStack<Content: View> {
    let content: Content
    /// Set for the NavigationSplitView-owned sidebar/content columns: a
    /// scroll-less column still leads with its `.navigationTitle` as a fixed
    /// header (app-owned stacks keep full-bleed roots, e.g. a map detail).
    var staticTitleFallback = false
    /// `init(path:)`: the bound path, as values, read and written.
    var path: (get: () -> [AnyHashable], set: ([AnyHashable]) -> Void)?

    public init(@ViewBuilder root: () -> Content) {
        content = root()
    }

    /// A stack whose screens above the root are a path of values, each shown
    /// by the `navigationDestination(for:)` for its type: a link with a
    /// value adds it, Back takes the last away, and the app can set it.
    public init<Data>(path: Binding<Data>, @ViewBuilder root: () -> Content)
    where Data: MutableCollection, Data: RandomAccessCollection, Data: RangeReplaceableCollection, Data.Element: Hashable {
        content = root()
        self.path = (get: { path.wrappedValue.map { AnyHashable($0) } },
                     // A value of another type than the path's has nowhere to go.
                     set: { values in path.wrappedValue = Data(values.compactMap { $0.base as? Data.Element }) })
    }

    public init(path: Binding<NavigationPath>, @ViewBuilder root: () -> Content) {
        content = root()
        self.path = (get: { path.wrappedValue.elements }, set: { path.wrappedValue = NavigationPath(elements: $0) })
    }

    init(staticTitleFallback: Bool, @ViewBuilder root: () -> Content) {
        content = root()
        self.staticTitleFallback = staticTitleFallback
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

/// A path of values of any types, for `NavigationStack(path:)`: each shown
/// by the `navigationDestination(for:)` for its type.
public struct NavigationPath: Equatable {
    var elements: [AnyHashable]

    public init() { elements = [] }

    public init<S: Sequence>(_ elements: S) where S.Element: Hashable {
        self.elements = elements.map { AnyHashable($0) }
    }

    init(elements: [AnyHashable]) { self.elements = elements }

    public var count: Int { elements.count }
    public var isEmpty: Bool { elements.isEmpty }

    public mutating func append<V: Hashable>(_ value: V) { elements.append(AnyHashable(value)) }

    public mutating func removeLast(_ k: Int = 1) { elements.removeLast(k) }
}

extension NavigationStack {
    /// A screen of the path whose destination is not registered yet (the app
    /// started on a path, or the path was set before its screens were seen):
    /// the screen under it, which declares it, is built once to register it.
    @MainActor
    func _registerDestinations(nav: NavigationState, ctx: inout BuildContext) {
        for index in nav.stack.indices {
            guard let value = nav.stack[index].value, nav.destination(for: value) == nil else { continue }
            var under = ctx.descend("level\(index)")
            under.navigation = nav
            under.navigationLevel = index
            let screen: any View = index == 0 ? content : nav.stack[index - 1].makeView()
            _ = buildNode(view: screen, ctx: &under)
        }
    }
}

extension NavigationStack: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let key = ctx.path + "#navigation"
        let nav: NavigationState
        if let existing = ctx.storage.locations[key] as? NavigationState {
            nav = existing
        } else {
            nav = NavigationState()
            ctx.storage.locations[key] = nav
        }
        nav.key = key
        // Value-based navigation: the screens the path says, each built by
        // the destination for its value's type.
        nav.path = path
        nav.followPath()
        _registerDestinations(nav: nav, ctx: &ctx)
        // Track for the system back button (innermost visible stack pops first).
        Runtime.shared.registerFrameEffect { Runtime.shared.navigationStates.append(nav) }

        // A host with REAL navigation containers (Apple's tree renderer):
        // serialize a semantic `navstack` node — the host owns the bar, the
        // title, the push/pop animation, everything.
        if Renderer.hostRendersNavigation {
            nav.lastDepth = nav.stack.count
            return makeNativeNode(nav: nav, ctx: &ctx)
        }

        // Push/pop transition: the incoming content fades in and slides in
        // horizontally — from the right on a push, from the left on a pop — so
        // it reads like a native screen change. (The outgoing screen isn't
        // retained, so only the incoming content animates; the fade hides the
        // small uncovered strip.) Driven by the render loop.
        let depth = nav.stack.count
        if depth != nav.lastDepth {
            nav.transitionStart = Runtime.shared.animationTime
            nav.lastTransitionWasPush = depth > nav.lastDepth
            nav.lastDepth = depth
        }
        var transT = 1.0
        let transitionDuration = 0.32
        let elapsed = Runtime.shared.animationTime - nav.transitionStart
        if nav.transitionStart >= 0, elapsed < transitionDuration {
            let u = 1 - elapsed / transitionDuration
            transT = 1 - u * u * u // ease-out cubic
            Runtime.shared.navTransitionActive = true
        }

        // Content: top of the stack, or the root. Reset the toolbar items and
        // title mode first so they only stick if the visible screen declares
        // them.
        nav.trailingTitle = nil
        nav.trailingAction = nil
        nav.leadingItems = []
        nav.trailingItems = []
        nav.principalIndex = nil
        nav.principalContent = nil
        nav.bottomBarItems = []
        nav.titleDisplayMode = .automatic
        var sub = ctx.descend("level\(nav.stack.count)")
        sub.navigation = nav
        sub.navigationLevel = nav.stack.count
        sub.env.opacity *= transT
        var contentNode: RenderNode
        if let top = nav.stack.last {
            contentNode = buildNode(view: top.makeView(), ctx: &sub)
        } else {
            contentNode = buildNode(view: content, ctx: &sub)
        }
        contentNode = _withBottomBar(contentNode, nav: nav, ctx: &sub)

        // Large title (iOS/Android "Settings" style): inject the title as a big
        // header at the top of the content's scroll, so it scrolls away
        // naturally; the bar shows a compact inline title only once the large
        // one collapses (crossfading by the scroll offset).
        var inlineAlpha = 1.0
        var hasLargeTitle = false
        let largeTitleHeight: CGFloat = 48
        let inlineTitle = nav.titleDisplayMode.kind == .inline
        if !inlineTitle, !nav.currentTitle.isEmpty, let scroll = firstVerticalScroll(contentNode) {
            hasLargeTitle = true
            let titleText = RenderNode(kind: .text(nav.currentTitle))
            titleText.font = Font.system(size: 34, weight: .bold)
            titleText.color = Color.primary.opacity(transT)
            let titleBox = RenderNode.box(child: titleText)
            titleBox.padding = EdgeInsets(top: 6, leading: 16, bottom: 8, trailing: 16)
            titleBox.expandsWidth = true
            titleBox.alignment = .leading
            var headerChildren: [RenderNode] = [titleBox]
            // Inject the `.searchable` field as a scrolling header directly
            // below the large title (like iOS): the canonical `search`
            // host-view node — a native field (DOM <input>, Compose
            // TextField) under component systems, the drawn field via chrome
            // expansion on the self-drawing path.
            if let search = Runtime.shared.pendingSearch {
                let searchID = ctx.path + "#searchfield"
                let searchSpec = HostViewSpec(
                    id: searchID,
                    kind: "search",
                    params: ["prompt": search.prompt],
                    value: search.get(),
                    options: [],
                    onChange: { search.set($0) }
                )
                let searchNode = RenderNode(kind: .hostView(searchSpec))
                searchNode.identityPath = searchID
                searchNode.fixedHeight = 36
                searchNode.expandsWidth = true
                // Inset the field from the column edges via layout (not CSS), so
                // the host-view frame the field is positioned at is exactly the
                // visible field rect.
                let searchBox = RenderNode.box(child: searchNode)
                searchBox.padding = EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16)
                searchBox.expandsWidth = true
                headerChildren.append(searchBox)
                Runtime.shared.pendingSearch = nil
            }
            // The scroll may be last frame's (a reused subtree's): the header
            // put in then is taken out first, or every frame would add one.
            let marker = ctx.path + "#largetitle"
            titleBox.identityPath = marker + "/title"
            headerChildren.last?.identityPath = headerChildren.count > 1 ? marker + "/search" : marker + "/title"
            var content = scroll.children
            if content.count == 1, content[0].identityPath == marker {
                content = content[0].children.filter { !($0.identityPath?.hasPrefix(marker + "/") ?? false) }
            }
            let wrapper = RenderNode(kind: .stack(.vertical))
            wrapper.identityPath = marker
            wrapper.stackSpacing = 0
            wrapper.expandsWidth = true
            wrapper.stackAlignment = Alignment(horizontal: .leading, vertical: .center)
            wrapper.children = headerChildren + content
            scroll.children = [wrapper]
            let offset = Runtime.shared.scrollOffsets[scroll.identityPath ?? ""] ?? 0
            inlineAlpha = Double(max(0, min(1, offset / largeTitleHeight)))
        } else if staticTitleFallback, !inlineTitle, !nav.currentTitle.isEmpty, nav.stack.isEmpty {
            // A framework-owned split column with no scroll to inject into
            // (an informational pane): the large title still leads the
            // content, as a fixed header — matching the scroll-injected
            // header of its sibling columns. App-owned stacks are left
            // untouched so full-bleed roots (a map detail) keep the whole
            // pane.
            hasLargeTitle = true
            let titleText = RenderNode(kind: .text(nav.currentTitle))
            titleText.font = Font.system(size: 34, weight: .bold)
            titleText.color = Color.primary.opacity(transT)
            let titleBox = RenderNode.box(child: titleText)
            titleBox.padding = EdgeInsets(top: 6, leading: 16, bottom: 8, trailing: 16)
            titleBox.expandsWidth = true
            titleBox.alignment = .leading
            let contentBox = RenderNode.box(child: contentNode)
            contentBox.expandsWidth = true
            contentBox.expandsHeight = true
            let wrapper = RenderNode(kind: .stack(.vertical))
            wrapper.stackSpacing = 0
            wrapper.expandsWidth = true
            wrapper.expandsHeight = true
            wrapper.stackAlignment = Alignment(horizontal: .leading, vertical: .center)
            wrapper.children = [titleBox, contentBox]
            contentNode = wrapper
        }

        // Navigation bar: a native host component (HTML bar on web, a Toolbar
        // on Android) positioned at the top of this stack's frame, so it works
        // per-column inside a NavigationSplitView. The back button reports
        // through the host-view event channel.
        // Fold the legacy single-trailing `.toolbar { Button }` form into the
        // item lists so every consumer sees ONE model.
        if let title = nav.trailingTitle, let action = nav.trailingAction {
            nav.trailingItems.append(_BarItem(title: title, action: action))
        }
        let leadingItems = nav.leadingItems
        let trailingItems = nav.trailingItems

        let barID = ctx.path + "#navbar"
        // A compact split view's column root goes back to the previous column.
        let splitBack = nav.stack.isEmpty ? Runtime.shared.compactSplitBack : nil
        let barSpec = HostViewSpec(
            id: barID,
            kind: "navbar",
            params: [
                "title": nav.currentTitle,
                "subtitle": nav.currentSubtitle,
                "back": nav.stack.isEmpty ? (splitBack == nil ? "0" : "1") : "1",
                "dark": Runtime.shared.colorScheme == .dark ? "1" : "0",
                "scheme": _schemeParam(),
                "large": hasLargeTitle ? "1" : "0",
                "inlineAlpha": "\(inlineAlpha)",
                // Legacy single-trailing param (older hosts render only this).
                "trailing": trailingItems.first?.title ?? "",
                // Multi-item toolbar (`ToolbarItem(placement:)`): titles in
                // declaration order, newline-joined; events come back as
                // "leading:<i>" / "trailingItem:<i>".
                "leading": leadingItems.map(\.title).joined(separator: "\n"),
                "trailingItems": trailingItems.map(\.title).joined(separator: "\n"),
                // Accessibility labels per item (empty when none), same order.
                "leadingLabels": leadingItems.map { $0.accessibilityLabel ?? "" }.joined(separator: "\n"),
                "trailingLabels": trailingItems.map { $0.accessibilityLabel ?? "" }.joined(separator: "\n"),
                "leadingSymbols": leadingItems.map { $0.symbolName ?? "" }.joined(separator: "\n"),
                "trailingSymbols": trailingItems.map { $0.symbolName ?? "" }.joined(separator: "\n"),
                // Segmented toolbar items (a `.segmented` Picker in a
                // ToolbarItem): per trailing item, its segment labels joined
                // by U+001F (empty for plain buttons) + the selected index;
                // hosts report "segment:<item>:<index>".
                "segments": _segmentsParam(trailingItems),
                "segmentSelected": trailingItems.map { String($0.selected) }.joined(separator: "\n"),
                "prominent": trailingItems.map { $0.prominent ? "1" : "0" }.joined(separator: "\n"),
                // Disabled items, per item ("1"/"0"); empty when none is.
                "leadingDisabled": _disabledParam(leadingItems),
                "trailingDisabled": _disabledParam(trailingItems),
                // `.principal`: which trailing item a host with a center slot
                // should promote there (others leave it trailing).
                "principal": nav.principalIndex.map(String.init) ?? "",
                "principalContent": nav.principalContent == nil ? "" : "1",
            ],
            value: nav.currentTitle,
            options: [],
            onChange: { [weak nav] value in
                guard let nav else { return }
                if value == "back" {
                    if nav.stack.isEmpty, let splitBack { splitBack() } else { nav.pop() }
                } else if value == "trailing" {
                    nav.trailingItems.first?.action()
                } else if value.hasPrefix("leading:"), let i = Int(value.dropFirst(8)),
                          nav.leadingItems.indices.contains(i) {
                    nav.leadingItems[i].action()
                } else if value.hasPrefix("segment:") {
                    let parts = value.dropFirst(8).split(separator: ":")
                    if parts.count == 2, let i = Int(parts[0]), let j = Int(parts[1]),
                       nav.trailingItems.indices.contains(i) {
                        nav.trailingItems[i].onSelect(j)
                    }
                } else if value.hasPrefix("trailingItem:"), let i = Int(value.dropFirst(13)),
                          nav.trailingItems.indices.contains(i) {
                    nav.trailingItems[i].action()
                }
            }
        )
        // At a root view the large title leads the content, so a reserved bar
        // is just an empty strip; collapse it until something is pushed — or
        // until the screen puts something IN the bar (toolbar items, or an
        // `.inline` title), which shows it at the root too (SwiftUI shows
        // root toolbar items in the navigation bar). A compact split
        // column's root has its back to the previous column there, and a
        // title with no scroll to lead (so no large title) shows inline.
        // Otherwise the canonical `navbar` host-view node: a native bar under
        // component systems, DrawnNavBar via chrome expansion on the
        // self-drawing path — the same bar on every GPU backend.
        let barHasContent = !leadingItems.isEmpty || !trailingItems.isEmpty
            || (inlineTitle && !nav.currentTitle.isEmpty)
            || (!hasLargeTitle && !nav.currentTitle.isEmpty)
            || splitBack != nil
        let bar: RenderNode
        if nav.stack.isEmpty, !barHasContent {
            bar = RenderNode(kind: .box)
            bar.fixedHeight = 0
            _ = barSpec
        } else {
            bar = RenderNode(kind: .hostView(barSpec))
            bar.identityPath = barID
            bar.fixedHeight = 44
            if let content = nav.principalContent { bar.children = [content] }
        }
        bar.expandsWidth = true

        let contentBox = RenderNode.box(child: contentNode)
        contentBox.expandsWidth = true
        contentBox.expandsHeight = true
        // Slide in from the leading edge for a push, trailing edge for a pop.
        contentBox.offsetX = (1 - transT) * (nav.lastTransitionWasPush ? 40 : -40)

        let column = RenderNode(kind: .stack(.vertical))
        column.stackSpacing = 0
        column.expandsWidth = true
        column.expandsHeight = true
        column.children = [bar, contentBox]
        column.ownsNavigation = true
        column.navigationContent = contentNode
        return column
    }
}

extension NavigationStack {
    /// The native-navigation serialization: a `navstack` host-view node
    /// carrying the screen's chrome as params (title, depth, toolbar items,
    /// search, title display mode) with the CONTENT as its only child. The
    /// host mounts a real `NavigationStack` around it — its path length
    /// mirrors `depth`, native pops come back as "back" events, toolbar
    /// items as "leading:<i>"/"trailingItem:<i>", search edits as
    /// "search:<text>".
    @MainActor
    func makeNativeNode(nav: NavigationState, ctx: inout BuildContext) -> RenderNode {
        // What the content registers (its title, toolbar, search) starts
        // afresh, here and when a view around the stack is reused.
        Runtime.shared.registerFrameEffect {
            nav.trailingTitle = nil
            nav.trailingAction = nil
            nav.leadingItems = []
            nav.trailingItems = []
            nav.principalIndex = nil
            nav.principalContent = nil
            nav.bottomBarItems = []
            nav.titleDisplayMode = .automatic
        }
        var sub = ctx.descend("level\(nav.stack.count)")
        sub.navigation = nav
        sub.navigationLevel = nav.stack.count
        var contentNode: RenderNode
        if let top = nav.stack.last {
            contentNode = buildNode(view: top.makeView(), ctx: &sub)
        } else {
            contentNode = buildNode(view: content, ctx: &sub)
        }
        contentNode = _withBottomBar(contentNode, nav: nav, ctx: &sub)

        if let title = nav.trailingTitle, let action = nav.trailingAction {
            nav.trailingItems.append(_BarItem(title: title, action: action))
        }
        var params: [String: String] = [
            "title": nav.currentTitle,
                "subtitle": nav.currentSubtitle,
            "depth": "\(nav.stack.count)",
            // `.preferredColorScheme` ("light"/"dark", "" = system): hosts
            // apply it to the native chrome around this level.
            "scheme": _schemeParam(),
            "leading": nav.leadingItems.map(\.title).joined(separator: "\n"),
            "trailingItems": nav.trailingItems.map(\.title).joined(separator: "\n"),
            "leadingLabels": nav.leadingItems.map { $0.accessibilityLabel ?? "" }.joined(separator: "\n"),
            "trailingLabels": nav.trailingItems.map { $0.accessibilityLabel ?? "" }.joined(separator: "\n"),
            "leadingSymbols": nav.leadingItems.map { $0.symbolName ?? "" }.joined(separator: "\n"),
            "trailingSymbols": nav.trailingItems.map { $0.symbolName ?? "" }.joined(separator: "\n"),
            "segments": _segmentsParam(nav.trailingItems),
            "segmentSelected": nav.trailingItems.map { String($0.selected) }.joined(separator: "\n"),
            "prominent": nav.trailingItems.map { $0.prominent ? "1" : "0" }.joined(separator: "\n"),
            "leadingDisabled": _disabledParam(nav.leadingItems),
            "trailingDisabled": _disabledParam(nav.trailingItems),
            "leadingPlacements": nav.leadingItems.map(\.placement).joined(separator: "\n"),
            "trailingPlacements": nav.trailingItems.map(\.placement).joined(separator: "\n"),
            "principal": nav.principalIndex.map(String.init) ?? "",
            "principalContent": nav.principalContent == nil ? "" : "1",
            // For hosts that draw their own chrome around the columns (web,
            // Compose); the Apple tree renderer ignores it — real containers
            // follow the trait environment.
            "dark": Runtime.shared.colorScheme == .dark ? "1" : "0",
        ]
        switch nav.titleDisplayMode.kind {
        case .inline: params["displayMode"] = "inline"
        case .large, .inlineLarge: params["displayMode"] = "large"
        case .automatic: break
        }
        // `.searchable`: the host renders its native search field.
        let search = Runtime.shared.pendingSearch
        if let search {
            params["searchPrompt"] = search.prompt
            params["searchValue"] = search.get()
        }
        // The search field is this stack's (taken again on reuse).
        Runtime.shared.registerFrameEffect { Runtime.shared.pendingSearch = nil }

        let spec = HostViewSpec(
            id: ctx.path + "#navstack",
            kind: "navstack",
            params: params,
            value: nav.currentTitle,
            options: [],
            onChange: { [weak nav] value in
                guard let nav else { return }
                if value == "back" {
                    nav.pop()
                } else if value.hasPrefix("leading:"), let i = Int(value.dropFirst(8)),
                          nav.leadingItems.indices.contains(i) {
                    nav.leadingItems[i].action()
                } else if value.hasPrefix("segment:") {
                    let parts = value.dropFirst(8).split(separator: ":")
                    if parts.count == 2, let i = Int(parts[0]), let j = Int(parts[1]),
                       nav.trailingItems.indices.contains(i) {
                        nav.trailingItems[i].onSelect(j)
                    }
                } else if value.hasPrefix("trailingItem:"), let i = Int(value.dropFirst(13)),
                          nav.trailingItems.indices.contains(i) {
                    nav.trailingItems[i].action()
                } else if value.hasPrefix("search:") {
                    search?.set(String(value.dropFirst(7)))
                }
            }
        )
        let node = RenderNode(kind: .hostView(spec))
        node.identityPath = spec.id
        // The content, then a `.principal` item's own view when it has one.
        node.children = [contentNode] + (nav.principalContent.map { [$0] } ?? [])
        node.expandsWidth = true
        node.expandsHeight = true
        node.ownsNavigation = true
        node.navigationContent = contentNode
        return node
    }
}

/// Compatibility container mirroring SwiftUI's deprecated `NavigationView`:
/// behaves as a `NavigationStack` (real SwiftUI still ships the type, so the
/// same shared source compiles everywhere).
public struct NavigationView<Content: View> {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public typealias Body = Never
}

extension NavigationView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        NavigationStack(root: { content }).makeNode(&ctx)
    }
}

/// A three-column split layout (sidebar | content | detail). The sidebar and
/// content columns are given their own navigation-bar context so their
/// `.navigationTitle` renders; the detail column is used as provided (apps wrap
/// it in a `NavigationStack` to push, e.g. to a web view). Real SwiftUI is used
/// on Apple; this is the reimplementation for wasm/Android.
extension View {
    /// Apple's column-width hints. The fixed form and `ideal` set the column's
    /// width on hosts that size columns themselves (the drawn path, web,
    /// Android); `min`/`max` are accepted for source compatibility.
    nonisolated public func navigationSplitViewColumnWidth(_ width: CGFloat) -> some View {
        _ColumnWidthView(child: self, width: Double(width), min: nil, max: nil)
    }

    nonisolated public func navigationSplitViewColumnWidth(
        min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil
    ) -> some View {
        _ColumnWidthView(child: self, width: Double(ideal), min: min.map { Double($0) }, max: max.map { Double($0) })
    }
}

struct _ColumnWidthView<Child: View> {
    let child: Child
    let width: Double
    /// The bounds a resizable column keeps to (hosts with resizable
    /// columns: params `<column>WidthMin` / `<column>WidthMax`).
    let min: Double?
    let max: Double?
    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _ColumnWidthView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let width = width, bounds = (min, max)
        Runtime.shared.registerFrameEffect {
            Runtime.shared.columnWidthHint = width
            Runtime.shared.columnWidthBounds = bounds
        }
        var sub = ctx.descend("colwidth")
        // Also where the app put it (params colWidth, colWidthMin,
        // colWidthMax), for hosts whose split view reads it from there.
        let inner = buildNode(view: child, ctx: &sub)
        let box = RenderNode.box(child: inner)
        box.expandsWidth = inner.expandsWidth
        box.expandsHeight = inner.expandsHeight
        box.columnWidth = (width, min, max)
        return box
    }
}

/// Which column a collapsed (compact-width) split view shows — Apple's shape.
public struct NavigationSplitViewColumn: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case sidebar, content, detail }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    public static var sidebar: NavigationSplitViewColumn { NavigationSplitViewColumn(.sidebar) }
    public static var content: NavigationSplitViewColumn { NavigationSplitViewColumn(.content) }
    public static var detail: NavigationSplitViewColumn { NavigationSplitViewColumn(.detail) }

    var wireName: String {
        switch kind {
        case .sidebar: return "sidebar"
        case .content: return "content"
        case .detail: return "detail"
        }
    }
}

/// `columnVisibility` — Apple's shape. Regular width: `.all` shows every
/// column (and pins the sidebar open on hosts with a collapse control),
/// `.doubleColumn` hides the sidebar of a three-column split,
/// `.detailOnly` shows the detail alone; compact width still collapses.
public struct NavigationSplitViewVisibility: Equatable, Codable, Sendable {
    enum Kind: String, Hashable, Sendable { case automatic, all, doubleColumn, detailOnly }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    public static var automatic: NavigationSplitViewVisibility { NavigationSplitViewVisibility(.automatic) }
    public static var all: NavigationSplitViewVisibility { NavigationSplitViewVisibility(.all) }
    public static var doubleColumn: NavigationSplitViewVisibility { NavigationSplitViewVisibility(.doubleColumn) }
    public static var detailOnly: NavigationSplitViewVisibility { NavigationSplitViewVisibility(.detailOnly) }

    public init(from decoder: any Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        kind = Kind(rawValue: name) ?? .automatic
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(kind.rawValue)
    }

    var wireName: String {
        switch kind {
        case .automatic: return "automatic"
        case .all: return "all"
        case .doubleColumn: return "doubleColumn"
        case .detailOnly: return "detailOnly"
        }
    }
}

/// `.navigationSplitViewStyle`: rides the split to hosts with native split
/// views (param "style"); the others keep their column layout.
@MainActor @preconcurrency
public protocol NavigationSplitViewStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = NavigationSplitViewStyleConfiguration
}

/// A split view, as a style sees it (the hosts lay its columns out).
public struct NavigationSplitViewStyleConfiguration {}

public struct AutomaticNavigationSplitViewStyle: NavigationSplitViewStyle, NamedStyle {
    nonisolated public init() {}
    var styleName: String { "automatic" }
    nonisolated public func makeBody(configuration: Configuration) -> some View { EmptyView() }
}

public struct BalancedNavigationSplitViewStyle: NavigationSplitViewStyle, NamedStyle {
    nonisolated public init() {}
    var styleName: String { "balanced" }
    nonisolated public func makeBody(configuration: Configuration) -> some View { EmptyView() }
}

public struct ProminentDetailNavigationSplitViewStyle: NavigationSplitViewStyle, NamedStyle {
    nonisolated public init() {}
    var styleName: String { "prominentDetail" }
    nonisolated public func makeBody(configuration: Configuration) -> some View { EmptyView() }
}

extension NavigationSplitViewStyle where Self == AutomaticNavigationSplitViewStyle {
    nonisolated public static var automatic: AutomaticNavigationSplitViewStyle { AutomaticNavigationSplitViewStyle() }
}

extension NavigationSplitViewStyle where Self == BalancedNavigationSplitViewStyle {
    nonisolated public static var balanced: BalancedNavigationSplitViewStyle { BalancedNavigationSplitViewStyle() }
}

extension NavigationSplitViewStyle where Self == ProminentDetailNavigationSplitViewStyle {
    nonisolated public static var prominentDetail: ProminentDetailNavigationSplitViewStyle { ProminentDetailNavigationSplitViewStyle() }
}

/// `.toolbar(removing:)`'s default items.
public struct ToolbarDefaultItemKind: Sendable {
    enum Kind: Hashable, Sendable { case sidebarToggle, title, search }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    public static let sidebarToggle = ToolbarDefaultItemKind(.sidebarToggle)
    public static let title = ToolbarDefaultItemKind(.title)
    public static let search = ToolbarDefaultItemKind(.search)
}

public struct NavigationSplitView<Sidebar: View, Content: View, Detail: View> {
    let sidebar: Sidebar
    let content: Content
    let detail: Detail
    /// Which column a compact presentation starts on (and, on hosts that
    /// report it, tracks). Regular-width rendering ignores it.
    let preferredCompactColumn: Binding<NavigationSplitViewColumn>?
    /// `columnVisibility`, when the app drives it.
    var columnVisibility: Binding<NavigationSplitViewVisibility>?
    /// 3 (sidebar/content/detail) or 2 (sidebar/detail — the Messages shape).
    let columnCount: Int

    public init(
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder content: () -> Content,
        @ViewBuilder detail: () -> Detail
    ) {
        self.sidebar = sidebar()
        self.content = content()
        self.detail = detail()
        self.preferredCompactColumn = nil
        self.columnCount = 3
    }

    // Apple shipped this in iOS 17 / macOS 14, so it is spelled that way
    // here too: on Apple the rules must be Apple's, whichever renderer is
    // drawing. The attribute names only Apple's platforms, so the `*` case
    // covers the ones we implement ourselves and it costs them nothing.
    #if !ISOMER_COMPILED_FEATURE
    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
    #endif
    public init(
        preferredCompactColumn: Binding<NavigationSplitViewColumn>,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder content: () -> Content,
        @ViewBuilder detail: () -> Detail
    ) {
        self.sidebar = sidebar()
        self.content = content()
        self.detail = detail()
        self.preferredCompactColumn = preferredCompactColumn
        self.columnCount = 3
    }

    public init(
        columnVisibility: Binding<NavigationSplitViewVisibility>,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder content: () -> Content,
        @ViewBuilder detail: () -> Detail
    ) {
        self.init(sidebar: sidebar, content: content, detail: detail)
        self.columnVisibility = columnVisibility
    }

    // Apple shipped this in iOS 17 / macOS 14, so it is spelled that way
    // here too: on Apple the rules must be Apple's, whichever renderer is
    // drawing. The attribute names only Apple's platforms, so the `*` case
    // covers the ones we implement ourselves and it costs them nothing.
    #if !ISOMER_COMPILED_FEATURE
    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
    #endif
    public init(
        columnVisibility: Binding<NavigationSplitViewVisibility>,
        preferredCompactColumn: Binding<NavigationSplitViewColumn>,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder content: () -> Content,
        @ViewBuilder detail: () -> Detail
    ) {
        self.init(preferredCompactColumn: preferredCompactColumn, sidebar: sidebar, content: content, detail: detail)
        self.columnVisibility = columnVisibility
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension NavigationSplitView where Content == EmptyView {
    public init(
        columnVisibility: Binding<NavigationSplitViewVisibility>,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail
    ) {
        self.init(sidebar: sidebar, detail: detail)
        self.columnVisibility = columnVisibility
    }

    // Apple shipped this in iOS 17 / macOS 14, so it is spelled that way
    // here too: on Apple the rules must be Apple's, whichever renderer is
    // drawing. The attribute names only Apple's platforms, so the `*` case
    // covers the ones we implement ourselves and it costs them nothing.
    #if !ISOMER_COMPILED_FEATURE
    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
    #endif
    public init(
        columnVisibility: Binding<NavigationSplitViewVisibility>,
        preferredCompactColumn: Binding<NavigationSplitViewColumn>,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail
    ) {
        self.init(preferredCompactColumn: preferredCompactColumn, sidebar: sidebar, detail: detail)
        self.columnVisibility = columnVisibility
    }

    /// The two-column form (sidebar + detail, no content column): regular
    /// width shows both, compact collapses to the sidebar with selection
    /// pushing the detail and back retreating.
    public init(
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail
    ) {
        self.sidebar = sidebar()
        self.content = EmptyView()
        self.detail = detail()
        self.preferredCompactColumn = nil
        self.columnCount = 2
    }

    // Apple shipped this in iOS 17 / macOS 14, so it is spelled that way
    // here too: on Apple the rules must be Apple's, whichever renderer is
    // drawing. The attribute names only Apple's platforms, so the `*` case
    // covers the ones we implement ourselves and it costs them nothing.
    #if !ISOMER_COMPILED_FEATURE
    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
    #endif
    public init(
        preferredCompactColumn: Binding<NavigationSplitViewColumn>,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail
    ) {
        self.sidebar = sidebar()
        self.content = EmptyView()
        self.detail = detail()
        self.preferredCompactColumn = preferredCompactColumn
        self.columnCount = 2
    }
}

/// Display-list navigation bar for the self-drawing renderers: back
/// affordance, inline title, and the screen's toolbar items — identical on
/// every GPU backend.
struct DrawnNavBar {
    let title: String
    var showsBack: Bool = true
    var leading: [String] = []
    var trailing: [String] = []
    /// The items drawn disabled, by index.
    var leadingDisabled: Set<Int> = []
    var trailingDisabled: Set<Int> = []
    let onBack: () -> Void
    var onLeading: (Int) -> Void = { _ in }
    var onTrailing: (Int) -> Void = { _ in }

    /// A bar item: a tinted pill with a 44-point hit target, so glyph-only
    /// items (✎ ▶︎ ⚙︎) read as tappable and are easy to hit on a phone.
    /// A disabled item is greyed, its pill too, and takes no press.
    private func item(_ label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Font.system(size: 17, weight: .medium))
                .foregroundColor(disabled ? Color.primary.opacity(0.3) : .accentColor)
                .padding(.horizontal, 12)
                .frame(minWidth: 44, minHeight: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(disabled ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.14)))
        }
        .disabled(disabled)
    }

    var body: some View {
        HStack(spacing: 6) {
            if showsBack {
                Button(action: onBack) {
                    Text("\u{2039}").font(Font.system(size: 30, weight: .regular))
                        .foregroundColor(.accentColor)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            ForEach(0 ..< leading.count, id: \.self) { i in
                item(leading[i], disabled: leadingDisabled.contains(i)) { onLeading(i) }
            }
            Text(title).font(Font.system(size: 17, weight: .semibold))
            Spacer()
            ForEach(0 ..< trailing.count, id: \.self) { i in
                item(trailing[i], disabled: trailingDisabled.contains(i)) { onTrailing(i) }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.barBackground)
    }
}

/// The `.searchable` field for the self-drawing renderers, drawn into the
/// display list and injected directly below the large title so it scrolls
/// with the content (iOS-style). Bound to the query from `.searchable`.
struct DrawnSearchField {
    let spec: SearchSpec
    var body: some View {
        HStack(spacing: 6) {
            // Draw the magnifier from shapes (identical on every backend;
            // Linux's DejaVu Sans has no emoji anyway).
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.75), lineWidth: 1.6)
                    .frame(width: 10, height: 10)
                    .offset(x: -1.5, y: -1.5)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.75))
                    .frame(width: 6, height: 1.8)
                    .rotationEffect(.degrees(45))
                    .offset(x: 4, y: 4)
            }
            .frame(width: 16, height: 16)
            TextField(spec.prompt, text: Binding(get: spec.get, set: spec.set))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0, opacity: 0.06))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

extension NavigationSplitView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        // Native-navigation hosts mount a REAL NavigationSplitView: serialize
        // the three columns raw (each wrapped in the reimplementation's
        // NavigationStack, which itself serializes a semantic `navstack`
        // node) and let the host own column sizing, materials, and the
        // sidebar toggle.
        if Renderer.hostRendersNavigation {
            Runtime.shared.splitViewPaths.insert(ctx.path)
            var widthHints: [String: Double] = [:]
            var widthBounds: [String: (min: Double?, max: Double?)] = [:]
            let splitID = ctx.path + "#navsplit"
            // A column whose List selection changed to a value this build:
            // compact hosts advance past it (sidebar → content, or → detail
            // on a two-column split; content → detail).
            var advanceTo: String?
            var clearers: [String: () -> Void] = [:]
            @MainActor
            func rawColumn(_ view: any View, _ suffix: String, wrapInBar: Bool) -> RenderNode {
                var sub = ctx.descend(suffix)
                Runtime.shared.columnWidthHint = nil
                Runtime.shared.columnWidthBounds = nil
                Runtime.shared.splitColumnBuilding = suffix == "detail" ? nil : suffix
                Runtime.shared.splitSelectionSnapshot = nil
                Runtime.shared.splitSelectionClearer = nil
                defer { Runtime.shared.splitSelectionClearer = nil }
                var node = wrapInBar
                    ? buildNode(view: NavigationStack { AnyView(view) }, ctx: &sub)
                    : buildNode(view: view, ctx: &sub)
                // A column that brings its own NavigationStack (or a TabView
                // of them), however deep in the app's own views: that one
                // is the column's, as in SwiftUI, and the split's goes. The
                // column is built inside the split's stack either way, so
                // its state keeps its place whichever it turns out to be.
                if wrapInBar, let content = node.navigationContent, _leadsToOwnNavigation(content) {
                    node = content
                }
                if let hint = Runtime.shared.columnWidthHint { widthHints[suffix] = hint }
                if let bounds = Runtime.shared.columnWidthBounds { widthBounds[suffix] = bounds }
                Runtime.shared.columnWidthHint = nil
                Runtime.shared.columnWidthBounds = nil
                Runtime.shared.splitColumnBuilding = nil
                if let clear = Runtime.shared.splitSelectionClearer { clearers[suffix] = clear }
                if suffix != "detail" {
                    let key = splitID + "/" + suffix
                    let current = Runtime.shared.splitSelectionSnapshot
                    // The first build only records the selection (a preselected
                    // sidebar still opens on the sidebar, as on a phone);
                    // later builds advance when it changes to a value.
                    let seenBefore = Runtime.shared.splitSelections.index(forKey: key) != nil
                    let previous = Runtime.shared.splitSelections[key] ?? nil
                    Runtime.shared.splitSelections[key] = current
                    if seenBefore, let current, current != previous || Runtime.shared.splitReselectRequested {
                        advanceTo = (suffix == "sidebar" && columnCount == 3) ? "content" : "detail"
                    } else if seenBefore, current == nil, previous != nil {
                        // The selection was cleared (an unpair, a dismissed
                        // draft): the compact presentation retreats to this
                        // column, as SwiftUI pops back when a split's
                        // selection becomes nil.
                        advanceTo = suffix
                    }
                }
                return node
            }
            let children = columnCount == 2
                ? [
                    rawColumn(sidebar, "sidebar", wrapInBar: true),
                    rawColumn(detail, "detail", wrapInBar: true),
                ]
                : [
                    rawColumn(sidebar, "sidebar", wrapInBar: true),
                    rawColumn(content, "content", wrapInBar: true),
                    rawColumn(detail, "detail", wrapInBar: true),
                ]
            Runtime.shared.splitReselectRequested = false
            var params = ["dark": Runtime.shared.colorScheme == .dark ? "1" : "0"]
            for (column, width) in widthHints {
                params[column + "Width"] = String(Int(width))
            }
            for (column, bounds) in widthBounds {
                if let min = bounds.min { params[column + "WidthMin"] = String(Int(min)) }
                if let max = bounds.max { params[column + "WidthMax"] = String(Int(max)) }
            }
            // Two-column splits carry no content child; hosts key off `columns`.
            if columnCount == 2 { params["columns"] = "2" }
            // `columnVisibility` (regular width): hosts show/hide columns and
            // pin the sidebar open for `.all`.
            if let visibility = columnVisibility {
                params["visibility"] = visibility.wrappedValue.wireName
            }
            // `.toolbar(removing: .sidebarToggle)` seen in the sidebar column.
            if Runtime.shared.sidebarToggleRemoved {
                params["sidebarToggle"] = "0"
                Runtime.shared.sidebarToggleRemoved = false
            }
            // Compact presentations start on (and report back) this column.
            if let preferred = preferredCompactColumn {
                params["compact"] = preferred.wrappedValue.wireName
            }
            // A selection change asks the compact presentation to advance
            // (the tick makes each request distinct).
            if let advanceTo {
                let tick = (Runtime.shared.splitAdvanceTicks[splitID] ?? 0) + 1
                Runtime.shared.splitAdvanceTicks[splitID] = tick
                Runtime.shared.splitAdvanceTargets[splitID] = advanceTo
            }
            // The last request stays on the wire (later builds keep it) so
            // the host sees the target with its tick, whichever build lands.
            if let tick = Runtime.shared.splitAdvanceTicks[splitID], let target = Runtime.shared.splitAdvanceTargets[splitID] {
                params["compactTick"] = String(tick)
                params["compact"] = target
            }
            let preferredBinding = preferredCompactColumn
            let visibilityBinding = columnVisibility
            let sidebarClear = clearers["sidebar"]
            let contentClear = clearers["content"]
            let spec = HostViewSpec(
                id: ctx.path + "#navsplit",
                kind: "navsplit",
                params: params,
                value: "",
                options: [],
                onChange: { value in
                    // The compact presentation moved to a column
                    // ("compact:<column>", ":back" when it went back). Back
                    // to a column clears the selections after it, as
                    // SwiftUI's compact split does when it pops back.
                    let back = value.hasSuffix(":back")
                    switch back ? String(value.dropLast(5)) : value {
                    case "compact:sidebar":
                        preferredBinding?.wrappedValue = .sidebar
                        if back { contentClear?(); sidebarClear?() }
                    case "compact:content":
                        preferredBinding?.wrappedValue = .content
                        if back { contentClear?() }
                    case "compact:detail": preferredBinding?.wrappedValue = .detail
                    // The host's own sidebar toggle (the Mac's, the desktop
                    // web's) at regular width: the app's binding follows it.
                    case "visibility:all": visibilityBinding?.wrappedValue = .all
                    case "visibility:detailOnly": visibilityBinding?.wrappedValue = .detailOnly
                    case "visibility:doubleColumn": visibilityBinding?.wrappedValue = .doubleColumn
                    default: break
                    }
                }
            )
            let node = RenderNode(kind: .hostView(spec))
            node.identityPath = spec.id
            node.children = children
            node.expandsWidth = true
            node.expandsHeight = true
            return node
        }

        var widthHints: [String: Double] = [:]
        let splitID = ctx.path + "#navsplit"
        var advanceTo: String?
        @MainActor
        func column(_ view: any View, _ suffix: String, wrapInBar: Bool, backTo: String? = nil) -> RenderNode {
            var sub = ctx.descend(suffix)
            Runtime.shared.columnWidthHint = nil
            Runtime.shared.splitColumnBuilding = suffix == "detail" ? nil : suffix
            Runtime.shared.splitSelectionSnapshot = nil
            Runtime.shared.compactSplitBack = backTo.map { previous in
                { Runtime.shared.drawnSplitColumn[splitID] = previous; Runtime.shared.setNeedsRender() }
            }
            // Give the sidebar/content their own nav-bar chrome; the detail is
            // already a NavigationStack from the app.
            let node = wrapInBar
                ? buildNode(view: NavigationStack(staticTitleFallback: true) { AnyView(view) }, ctx: &sub)
                : buildNode(view: view, ctx: &sub)
            Runtime.shared.compactSplitBack = nil
            if let hint = Runtime.shared.columnWidthHint { widthHints[suffix] = hint }
            Runtime.shared.columnWidthHint = nil
            Runtime.shared.splitColumnBuilding = nil
            if suffix != "detail" {
                // Same rule as the semantic path: a selection CHANGE to a
                // value (or a re-tap) advances a compact presentation.
                let key = splitID + "/" + suffix
                let current = Runtime.shared.splitSelectionSnapshot
                let seenBefore = Runtime.shared.splitSelections.index(forKey: key) != nil
                let previous = Runtime.shared.splitSelections[key] ?? nil
                Runtime.shared.splitSelections[key] = current
                if seenBefore, let current, current != previous || Runtime.shared.splitReselectRequested {
                    advanceTo = (suffix == "sidebar" && columnCount == 3) ? "content" : "detail"
                }
            }
            let box = RenderNode.box(child: node)
            box.expandsHeight = true
            return box
        }

        // Compact width (a phone): one column at a time — the sidebar until a
        // selection advances to the content/detail, whose bar goes back.
        if Runtime.shared.compactWidth {
            let initial = preferredCompactColumn?.wrappedValue.wireName ?? "sidebar"
            var shown = Runtime.shared.drawnSplitColumn[splitID] ?? initial
            if columnCount == 2, shown == "content" { shown = "detail" }
            @MainActor
            func build(_ name: String) -> RenderNode {
                switch name {
                case "detail":
                    return column(detail, "detail", wrapInBar: false, backTo: columnCount == 3 ? "content" : "sidebar")
                case "content":
                    return column(content, "content", wrapInBar: true, backTo: "sidebar")
                default:
                    return column(sidebar, "sidebar", wrapInBar: true)
                }
            }
            var box = build(shown)
            Runtime.shared.splitReselectRequested = false
            // A selection change in the shown column advances IN THIS build
            // (the column just built is discarded for the next one).
            if let advanceTo, advanceTo != shown {
                Runtime.shared.drawnSplitColumn[splitID] = advanceTo
                shown = advanceTo
                box = build(shown)
            }
            box.expandsWidth = true
            return box
        }

        let sidebarBox = column(sidebar, "sidebar", wrapInBar: true)
        sidebarBox.fixedWidth = widthHints["sidebar"] ?? 240
        sidebarBox.background = [splitFill(Color.barBackground)]

        let detailBox = column(detail, "detail", wrapInBar: false)
        detailBox.expandsWidth = true
        Runtime.shared.splitReselectRequested = false

        let row = RenderNode(kind: .stack(.horizontal))
        row.stackSpacing = 0
        row.expandsWidth = true
        row.expandsHeight = true
        if columnCount == 2 {
            row.children = [sidebarBox, splitDivider(), detailBox]
            return row
        }
        let contentBox = column(content, "content", wrapInBar: true)
        contentBox.fixedWidth = widthHints["content"] ?? 340
        row.children = [sidebarBox, splitDivider(), contentBox, splitDivider(), detailBox]
        return row
    }
}

private func splitFill(_ color: Color) -> RenderNode {
    RenderNode(kind: .shape(.rectangle, fill: color, stroke: nil))
}

private func splitDivider() -> RenderNode {
    let d = RenderNode(kind: .shape(.rectangle, fill: Color.separator, stroke: nil))
    d.fixedWidth = 1
    d.expandsHeight = true
    return d
}

public struct NavigationLink<Label: View> {
    let label: Label
    let makeDestination: () -> any View
    /// The value form (`init(value:)`): pushed onto the stack's path, shown
    /// by the destination for its type. `.some(nil)`: a link to nothing,
    /// which does nothing.
    var value: AnyHashable?? = nil

    /// A link that pushes `value`, shown by the stack's
    /// `navigationDestination(for:)` for its type; nil does nothing.
    public init<P: Hashable>(value: P?, @ViewBuilder label: () -> Label) {
        self.label = label()
        makeDestination = { EmptyView() }
        self.value = .some(value.map { AnyHashable($0) })
    }

    public init<Destination: View>(
        @ViewBuilder destination: @escaping () -> Destination,
        @ViewBuilder label: () -> Label
    ) {
        self.label = label()
        makeDestination = { destination() }
    }

    /// The value form real SwiftUI code writes most:
    /// `NavigationLink(destination: DetailView()) { Label }`. The autoclosure
    /// defers construction to navigation time, matching Apple's signature.
    public init<Destination: View>(
        destination: @autoclosure @escaping () -> Destination,
        @ViewBuilder label: () -> Label
    ) {
        self.label = label()
        makeDestination = { destination() }
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension NavigationLink where Label == Text {
    public init<S: StringProtocol, P: Hashable>(_ title: S, value: P?) {
        label = Text(String(title))
        makeDestination = { EmptyView() }
        self.value = .some(value.map { AnyHashable($0) })
    }

    public init<P: Hashable>(_ titleKey: LocalizedStringKey, value: P?) {
        label = Text(titleKey)
        makeDestination = { EmptyView() }
        self.value = .some(value.map { AnyHashable($0) })
    }

    public init<Destination: View, S: StringProtocol>(
        _ title: S,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        let title = String(title)
        label = Text(title)
        makeDestination = { destination() }
    }
}

extension NavigationLink: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var sub = ctx.descend("navlink")
        // A link on its own is the accent's, as a button is; in a List's or
        // a Form's row its label keeps its own colours, as SwiftUI's does
        // (the row is the link, with a chevron).
        if !ctx.env.formRow {
            sub.env.foregroundColor = Color.accentColor
            sub.env.foregroundColorSet = true
        }
        let labelNode = buildNode(view: label, ctx: &sub)

        let chevron = RenderNode(kind: .text("›"))
        chevron.font = .body
        chevron.color = Color(white: 0, opacity: 0.3)

        let row = RenderNode(kind: .stack(.horizontal))
        row.stackSpacing = 6
        row.children = [labelNode, chevron]

        let box = RenderNode.box(child: row)
        if ctx.env.isEnabled, let nav = ctx.navigation {
            switch value {
            case .some(.some(let value)):
                box.tapAction = { [weak nav] in nav?.push(value: value) }
                box.pressFeedback = .ripple
            case .some(.none):
                break
            case .none:
                let destination = makeDestination
                box.tapAction = { [weak nav] in nav?.push(destination) }
                box.pressFeedback = .ripple
            }
        }
        return box
    }
}

/// `navigationDestination(for:)`: how the enclosing stack shows a value of
/// the type, registered as the view that declares it builds.
struct _NavigationDestinationView {
    let child: any View
    let type: ObjectIdentifier
    let make: (AnyHashable) -> any View

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _NavigationDestinationView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        ctx.navigation?.destinations[type] = make
        var sub = ctx.descend("navdestination")
        return buildNode(view: child, ctx: &sub)
    }
}

extension _NavigationDestinationView: View {}

struct _NavigationTitleView {
    let child: any View
    let title: String

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _NavigationTitleView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let nav = ctx.navigation, title = title, level = ctx.navigationLevel
        Runtime.shared.registerFrameEffect { nav?.setTitle(title, level: level) }
        var sub = ctx.descend("navtitle")
        return buildNode(view: child, ctx: &sub)
    }
}

struct _NavigationSubtitleView {
    let child: any View
    let subtitle: String

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _NavigationSubtitleView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let nav = ctx.navigation, subtitle = subtitle, level = ctx.navigationLevel
        Runtime.shared.registerFrameEffect { nav?.setSubtitle(subtitle, level: level) }
        var sub = ctx.descend("navsubtitle")
        return buildNode(view: child, ctx: &sub)
    }
}

/// The screen's `.bottomBar` toolbar as iOS 26 draws it: floating over the
/// content (a bottom `.safeAreaInset`, so the content scrolls on under it),
/// its items in Liquid Glass — a button with a symbol as a round glass
/// button, the `.searchable` field (`DefaultToolbarItem(kind: .search,
/// placement: .bottomBar)`) as a glass capsule — with `ToolbarSpacer`s
/// between. Built from views, so every renderer draws it.
@MainActor
func _withBottomBar(_ content: RenderNode, nav: NavigationState, ctx: inout BuildContext) -> RenderNode {
    guard !nav.bottomBarItems.isEmpty else { return content }
    var sub = ctx.descend("bottombar")
    let row = RenderNode(kind: .stack(.horizontal))
    row.stackAlignment = .center
    row.stackSpacing = 10
    row.expandsWidth = true
    // What each item is, in order, for hosts that put the items in their
    // own bottom toolbar instead of drawing this row (param "bottomBar"):
    // "search", "fixed" / "flex" (a ToolbarSpacer; a fixed one has no view
    // in the row), "button" (an icon button) or "view".
    var kinds: [String] = []
    for (i, item) in nav.bottomBarItems.enumerated() {
        var itemCtx = sub.descend("item\(i)")
        if item is _BottomBarSearch {
            // The field leaves the navigation bar for this one.
            guard let search = Runtime.shared.pendingSearch else { continue }
            Runtime.shared.pendingSearch = nil
            let field = buildNode(view: _BottomSearchField(search: search), ctx: &itemCtx)
            field.pinRebuildSite()
            field.expandsWidth = true
            row.children.append(field)
            kinds.append("search")
        } else if let spacer = item as? _BottomBarSpacer {
            if !spacer.fixed { row.children.append(buildNode(view: Spacer(), ctx: &itemCtx)) }
            kinds.append(spacer.fixed ? "fixed" : "flex")
        } else {
            let node = buildNode(view: AnyView(item).labelStyle(.iconOnly).foregroundColor(.primary), ctx: &itemCtx)
            if firstTapAction(node) != nil, firstSymbolName(node) != nil, firstText(node) == nil {
                // A bar button: a glass circle.
                let circle = RenderNode.box(child: node)
                circle.fixedWidth = 44
                circle.fixedHeight = 44
                circle.alignment = .center
                circle.background = [RenderNode(kind: .gradient(.circle, Material.thin.resolvePaint()))]
                row.children.append(circle)
                kinds.append("button")
            } else {
                node.pinRebuildSite()
                node.expandsWidth = true
                row.children.append(node)
                kinds.append("view")
            }
        }
    }
    // A button alone in the bar (its search field gone under the navigation
    // bar at regular width) sits in the middle, as an iPad's does.
    if kinds.filter({ $0 != "fixed" }) == ["button"] {
        row.children = [buildNode(view: Spacer(), ctx: &sub)] + row.children + [buildNode(view: Spacer(), ctx: &sub)]
        kinds = ["flex", "button", "flex"]
    }
    let bar = RenderNode.box(child: row)
    bar.padding = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
    bar.expandsWidth = true
    let contentBox = RenderNode.box(child: content)
    contentBox.expandsWidth = true
    contentBox.expandsHeight = true
    let column = RenderNode(kind: .stack(.vertical))
    column.stackSpacing = 0
    column.expandsWidth = true
    column.expandsHeight = true
    column.children = [contentBox, bar]
    column.safeAreaEdge = "bottom"
    column.bottomBarItems = kinds.joined(separator: "\n")
    return column
}

/// The `.searchable` field in a bottom bar: a 44pt glass capsule.
struct _BottomSearchField {
    let search: SearchSpec

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField(search.prompt, text: Binding(get: search.get, set: search.set))
                .textFieldStyle(.plain)
            if !search.get().isEmpty {
                Button { search.set("") } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: Capsule())
    }
}

/// `DefaultToolbarItem(kind:placement:)`: a system item placed in the
/// toolbar — the `.searchable` field in the bottom bar (`.search`). The
/// other kinds are where the system puts them already.
public struct DefaultToolbarItem {
    let kind: ToolbarDefaultItemKind
    let placement: ToolbarItemPlacement

    public init(kind: ToolbarDefaultItemKind, placement: ToolbarItemPlacement = .automatic) {
        self.kind = kind
        self.placement = placement
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension DefaultToolbarItem: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        // At the top (`_bottomBarAtTop`) the field is left to the navigation
        // bar, as a plain `.searchable`'s is.
        if kind.kind == .search, placement.slot == .bottom, !_bottomBarAtTop(ctx) {
            let nav = ctx.navigation
            Runtime.shared.registerFrameEffect { nav?.bottomBarItems.append(_BottomBarSearch()) }
        }
        return RenderNode(kind: .box)
    }
}

/// `ToolbarSpacer(_:placement:)`: room between toolbar items — a small gap
/// between glass groups (`.fixed`) or all that is left (`.flexible`).
/// A toolbar spacer's width: Apple's top-level `SpacerSizing`.
public struct SpacerSizing: Sendable {
    let isFixed: Bool
    public static let fixed = SpacerSizing(isFixed: true)
    public static let flexible = SpacerSizing(isFixed: false)
}

public struct ToolbarSpacer {
    let sizing: SpacerSizing
    let placement: ToolbarItemPlacement

    public init(_ sizing: SpacerSizing = .flexible, placement: ToolbarItemPlacement = .automatic) {
        self.sizing = sizing
        self.placement = placement
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive toolbar content") }
}

extension ToolbarSpacer: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        if placement.slot == .bottom {
            let nav = ctx.navigation, fixed = sizing.isFixed
            Runtime.shared.registerFrameEffect { nav?.bottomBarItems.append(_BottomBarSpacer(fixed: fixed)) }
        }
        return RenderNode(kind: .box)
    }
}

struct _BottomBarSearch {
    var body: some View { EmptyView() }
}

/// Whether a `.bottomBar` search field goes to the top here, as an iPad has
/// it in a split view's column: at regular width, in a column of a split
/// view (its columns side by side), the field sits under the navigation bar;
/// the bar's buttons stay at the bottom (an iPad's), and a host drawing the
/// Mac's toolbar takes them into it. A phone's width keeps iOS 26's floating
/// bar. (agent_ui's list chrome asks for the bottom bar everywhere but the
/// Mac and says so: the system moves it.)
@MainActor
func _bottomBarAtTop(_ ctx: BuildContext) -> Bool {
    ctx.env.horizontalSizeClass == .regular && Runtime.shared.splitColumnBuilding != nil
}


struct _BottomBarSpacer {
    let fixed: Bool
    var body: some View { EmptyView() }
}

public enum VerticalEdge: Int8, CaseIterable, Hashable, Sendable {
    case top
    case bottom

    /// A set of vertical edges.
    public struct Set: OptionSet, Sendable {
        public typealias Element = VerticalEdge.Set
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public init(_ e: VerticalEdge) { self.rawValue = 1 << e.rawValue }
        public static let top = Set(.top)
        public static let bottom = Set(.bottom)
        public static let all: Set = [.top, .bottom]
    }
}

/// `.safeAreaInset(edge:)` / `.safeAreaBar(edge:)`: pins `inset` at the
/// given edge and shrinks the content to the remaining height (the
/// reimplementation has no OS safe area to extend into, so the inset is a
/// plain edge slot).
struct _SafeAreaInsetView<Content: View, Inset: View> {
    let content: Content
    let edge: VerticalEdge
    let spacing: CGFloat?
    let inset: Inset
    var bar = false

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _SafeAreaInsetView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var sub = ctx.descend("safearea")
        let contentNode = buildNode(view: content, ctx: &sub)
        var insetCtx = ctx.descend("inset")
        let insetNode = buildNode(view: inset, ctx: &insetCtx)
        insetNode.pinRebuildSite()
        insetNode.expandsWidth = true
        let contentBox = RenderNode.box(child: contentNode)
        contentBox.expandsWidth = true
        contentBox.expandsHeight = true
        let column = RenderNode(kind: .stack(.vertical))
        column.stackSpacing = spacing ?? 0
        column.expandsWidth = true
        column.expandsHeight = true
        column.children = edge == .top ? [insetNode, contentBox] : [contentBox, insetNode]
        column.safeAreaEdge = edge == .top ? "top" : "bottom"
        column.safeAreaBar = bar
        column.safeAreaSpacing = spacing
        return column
    }
}

extension View {
    /// How a value of `data`'s type is shown when it is pushed onto the
    /// enclosing stack (by `NavigationLink(value:)` or its bound path).
    nonisolated public func navigationDestination<D: Hashable, C: View>(
        for data: D.Type, @ViewBuilder destination: @escaping (D) -> C
    ) -> some View {
        _NavigationDestinationView(child: self, type: ObjectIdentifier(D.self), make: { value in
            if let value = value.base as? D { return destination(value) }
            return EmptyView()
        })
    }

    nonisolated public func navigationTitle<S: StringProtocol>(_ title: S) -> some View {
        let title = String(title)
        return _NavigationTitleView(child: self, title: title)
    }

    /// Secondary line under the navigation title (macOS 11 / iOS 26 shape).
    nonisolated public func navigationSubtitle<S: StringProtocol>(_ subtitle: S) -> some View {
        let subtitle = String(subtitle)
        return _NavigationSubtitleView(child: self, subtitle: subtitle)
    }

    nonisolated public func safeAreaInset<V: View>(
        edge: VerticalEdge, alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil, @ViewBuilder content: () -> V
    ) -> some View {
        _SafeAreaInsetView(content: self, edge: edge, spacing: spacing, inset: content())
    }

    /// iOS 26 `safeAreaBar`: the same slot as `safeAreaInset`, marked as a
    /// bar for hosts that draw the bar's edge effect.
    nonisolated public func safeAreaBar<V: View>(
        edge: VerticalEdge, alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil, @ViewBuilder content: () -> V
    ) -> some View {
        _SafeAreaInsetView(content: self, edge: edge, spacing: spacing, inset: content(), bar: true)
    }
}

/// `.toolbar { Button("Open") { … } }` — a trailing navigation-bar item. Mirrors
/// SwiftUI's ViewBuilder `toolbar(content:)` overload (the same source compiles
/// against real SwiftUI on Apple). We pull the first button's label text and
/// tap action out of the toolbar content and hand them to the navigation bar,
/// which renders a native trailing button.
struct _ToolbarView<Content: View> {
    let child: any View
    let content: Content

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _ToolbarView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var probe = ctx.descend("toolbaritem")
        // Building the toolbar content registers any `ToolbarItem`s into the
        // navigation state as a side effect (their nodes are placeholders).
        let itemNode = buildNode(view: content, ctx: &probe)
        // Legacy bare-button form (`.toolbar { Button }`): pull the first
        // button's label + action as the single trailing item. ToolbarItems
        // return tap-free placeholders, so the probe can't double-register.
        if let action = firstTapAction(itemNode) {
            let nav = ctx.navigation, title = firstText(itemNode) ?? "Open"
            Runtime.shared.registerFrameEffect {
                nav?.trailingTitle = title
                nav?.trailingAction = action
            }
        }
        var sub = ctx.descend("toolbarchild")
        return buildNode(view: child, ctx: &sub)
    }
}

extension View {
    /// Disfavored, as Apple's is: items (`ToolbarItem`, …) are toolbar
    /// content, and take the `ToolbarContent` form (ToolbarContent.swift).
    @_disfavoredOverload
    nonisolated public func toolbar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        _ToolbarView(child: self, content: content())
    }
}

/// Where a `ToolbarItem` goes in the navigation bar. Mirrors SwiftUI's
/// placements, collapsed to the two slots the reimplementation's bar has:
/// leading (`.navigation` / `.topBarLeading` / `.cancellationAction`) and
/// trailing (everything else, matching SwiftUI's defaults).
public struct ToolbarItemPlacement: Sendable {
    enum Slot { case leading, trailing, principal, bottom }
    let slot: Slot
    /// Its own name ("confirmationAction", …), for hosts with every
    /// placement (params "leadingPlacements" / "trailingPlacements"): a
    /// confirmation is bold there, a cancellation where the system puts it.
    var name = "automatic"

    public static let automatic = ToolbarItemPlacement(slot: .trailing)
    public static let primaryAction = ToolbarItemPlacement(slot: .trailing, name: "primaryAction")
    public static let confirmationAction = ToolbarItemPlacement(slot: .trailing, name: "confirmationAction")
    public static let topBarTrailing = ToolbarItemPlacement(slot: .trailing, name: "topBarTrailing")
    public static let navigation = ToolbarItemPlacement(slot: .leading, name: "navigation")
    public static let cancellationAction = ToolbarItemPlacement(slot: .leading, name: "cancellationAction")
    public static let topBarLeading = ToolbarItemPlacement(slot: .leading, name: "topBarLeading")
    /// A centered bar item. Hosts that render a center slot (web) show it
    /// there; others fall back to the trailing cluster — it rides the
    /// trailing list on the wire with its index in the `principal` param.
    public static let principal = ToolbarItemPlacement(slot: .principal)
    /// A bar under the content holding the item's VIEW (a composer's
    /// TextField + button row, not just a title) — see `_withBottomBar`.
    public static let bottomBar = ToolbarItemPlacement(slot: .bottom)
    public static let keyboard = ToolbarItemPlacement(slot: .bottom)
}

/// One navigation-bar item inside `.toolbar { … }`. The content's first
/// button label (text or an `Image(systemName:)` glyph) and tap action become
/// a native bar button in the placement's slot; items keep declaration order.
public struct ToolbarItem<Content: View> {
    let placement: ToolbarItemPlacement
    let content: Content

    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {
        self.placement = placement
        self.content = content()
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive toolbar content") }
}

extension ToolbarItem: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        if placement.slot == .bottom {
            let nav = ctx.navigation, content = content
            Runtime.shared.registerFrameEffect { nav?.bottomBarItems.append(content) }
            return RenderNode(kind: .box)
        }
        var probe = ctx.descend("item")
        let node = buildToolbarContent(content, ctx: &probe)
        var item: _BarItem?
        if let picker = firstHostView(node, kind: "picker") {
            // A Picker in the bar becomes a segmented control (hosts with a
            // bar segment slot; others show its title as an inert item).
            item = _BarItem(
                title: picker.params["title"] ?? "", action: {},
                segments: picker.options, selected: Int(picker.value) ?? 0,
                onSelect: { picker.onChange?(String($0)) })
        } else if let action = firstTapAction(node) {
            // An icon item's accessible name is its title (`Button("Settings",
            // systemImage:)`) unless `.accessibilityLabel` says otherwise.
            let symbol = firstSymbolName(node)
            let words = firstText(node)
            // A worded label (a title, a name pill) shows its words; the
            // symbol stands in only for an icon-only label, and then the
            // words of a `Button("Settings", systemImage:)` name it.
            item = _BarItem(title: words ?? symbolGlyphIn(node) ?? "•", action: action,
                            accessibilityLabel: firstAccessibilityLabel(node) ?? (words == nil ? nil : (symbol != nil ? words : nil)),
                            symbolName: words == nil ? symbol : nil,
                            prominent: firstButtonRole(node) == .confirm,
                            disabled: firstButtonDisabled(node))
        }
        if let nav = ctx.navigation, var item {
            item.placement = placement.name
            let slot = placement.slot, registered = item
            let principal = isPlainBarLabel(node) ? nil : node
            Runtime.shared.registerFrameEffect {
                switch slot {
                case .leading: nav.leadingItems.append(registered)
                case .trailing: nav.trailingItems.append(registered)
                case .principal:
                    nav.principalIndex = nav.trailingItems.count
                    if let principal { nav.principalContent = principal }
                    nav.trailingItems.append(registered)
                case .bottom:
                    break
                }
            }
        }
        // A tap-free placeholder: the item renders in the BAR, not inline
        // (and the enclosing toolbar's legacy probe must not re-extract it).
        return RenderNode(kind: .box)
    }
}

/// `ToolbarItemGroup(placement:) { Button; Button; … }`: every button in the
/// group becomes its own bar item in the placement's slot, in declaration
/// order (the iOS Playground's pencil / play cluster).
public struct ToolbarItemGroup<Content: View> {
    let placement: ToolbarItemPlacement
    let content: Content

    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {
        self.placement = placement
        self.content = content()
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive toolbar content") }
}

extension ToolbarItemGroup: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        if placement.slot == .bottom {
            let nav = ctx.navigation, content = content
            Runtime.shared.registerFrameEffect { nav?.bottomBarItems.append(content) }
            return RenderNode(kind: .box)
        }
        var probe = ctx.descend("group")
        let node = buildToolbarContent(content, ctx: &probe)
        for (button, label) in tapTargets(node) {
            guard let action = button.tapAction else { continue }
            let symbol = firstSymbolName(button)
            let words = firstText(button)
            let item = _BarItem(title: words ?? symbolGlyphIn(button) ?? "•", action: action,
                                accessibilityLabel: label ?? firstAccessibilityLabel(button) ?? (symbol != nil ? words : nil),
                                symbolName: words == nil ? symbol : nil,
                                prominent: firstButtonRole(button) == .confirm,
                                disabled: button.buttonDisabled)
            let nav = ctx.navigation, slot = placement.slot
            Runtime.shared.registerFrameEffect {
                switch slot {
                case .leading: nav?.leadingItems.append(item)
                case .principal:
                    nav?.principalIndex = nav?.trailingItems.count ?? 0
                    nav?.trailingItems.append(item)
                default: nav?.trailingItems.append(item)
                }
            }
        }
        return RenderNode(kind: .box)
    }
}

/// The outermost tappable nodes of a subtree, in order (each button once —
/// nested taps inside a button are its label, not more buttons), each with
/// the accessibility label of its nearest wrapping modifier (`.accessibilityLabel`
/// on a Button wraps the button's node, so it sits ABOVE the tap).
func tapTargets(_ node: RenderNode, inheritedLabel: String? = nil) -> [(node: RenderNode, label: String?)] {
    let label = node.accessibilityLabel ?? inheritedLabel
    if node.tapAction != nil { return [(node, label)] }
    return node.children.flatMap { tapTargets($0, inheritedLabel: label) }
}

/// `NavigationBarItem.TitleDisplayMode` (iOS's `.navigationBarTitleDisplayMode`).
public struct NavigationBarItem {
    public enum TitleDisplayMode: Sendable {
        case automatic
        case inline
        case large
    }
}

extension View {
    /// iOS's `.navigationBarTitleDisplayMode(_:)`, the same knob as
    /// `.toolbarTitleDisplayMode`.
    nonisolated public func navigationBarTitleDisplayMode(_ mode: NavigationBarItem.TitleDisplayMode) -> some View {
        let mapped: ToolbarTitleDisplayMode
        switch mode {
        case .automatic: mapped = .automatic
        case .inline: mapped = .inline
        case .large: mapped = .large
        }
        return _ToolbarTitleDisplayModeView(child: self, mode: mapped)
    }
}

/// How the navigation title renders. `.inline` keeps the compact bar title
/// only (no injected large-title header) — the cross-platform
/// `.toolbarTitleDisplayMode` API (iOS 17 / macOS 14).
public struct ToolbarTitleDisplayMode: Sendable {
    enum Kind: Hashable, Sendable { case automatic, inline, inlineLarge, large }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    public static let automatic = ToolbarTitleDisplayMode(.automatic)
    public static let inline = ToolbarTitleDisplayMode(.inline)
    public static let inlineLarge = ToolbarTitleDisplayMode(.inlineLarge)
    public static let large = ToolbarTitleDisplayMode(.large)
}

struct _ToolbarTitleDisplayModeView {
    let child: any View
    let mode: ToolbarTitleDisplayMode

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _ToolbarTitleDisplayModeView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let nav = ctx.navigation, mode = mode
        Runtime.shared.registerFrameEffect { nav?.titleDisplayMode = mode }
        var sub = ctx.descend("titlemode")
        return buildNode(view: child, ctx: &sub)
    }
}

extension View {
    // Apple shipped this in iOS 17 / macOS 14, so it is spelled that way
    // here too: on Apple the rules must be Apple's, whichever renderer is
    // drawing. The attribute names only Apple's platforms, so the `*` case
    // covers the ones we implement ourselves and it costs them nothing.
    #if !ISOMER_COMPILED_FEATURE
    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
    #endif
    nonisolated public func toolbarTitleDisplayMode(_ mode: ToolbarTitleDisplayMode) -> some View {
        _ToolbarTitleDisplayModeView(child: self, mode: mode)
    }
}

/// First text string in a subtree (e.g. a toolbar button's label).
/// One navigation-bar item: a titled button, or (with `segments`) a
/// segmented control whose selection reports through `onSelect`.
struct _BarItem {
    var title: String
    var action: () -> Void
    /// `.accessibilityLabel` on the item's button (icon-only items).
    var accessibilityLabel: String? = nil
    /// The SF Symbol name when the item's label is an `Image(systemName:)`
    /// (its `title` is the stand-in glyph).
    var symbolName: String? = nil
    var segments: [String]? = nil
    var selected = 0
    var onSelect: (Int) -> Void = { _ in }
    /// A `.confirm`-role button: hosts render it bold/prominent.
    var prominent = false
    /// Its button is disabled (`.disabled(true)`): hosts draw it greyed and
    /// take no press (the action is already a no-op).
    var disabled = false
    /// The placement it was given, by name.
    var placement = "automatic"
}

/// Whether the first button in a subtree (the node `firstTapAction` finds)
/// is disabled.
func firstButtonDisabled(_ node: RenderNode) -> Bool {
    if node.tapAction != nil { return node.buttonDisabled }
    for child in node.children {
        if firstTapAction(child) != nil { return firstButtonDisabled(child) }
    }
    return false
}

/// First Button role in a subtree.
func firstButtonRole(_ node: RenderNode) -> ButtonRole? {
    if let role = node.buttonRole { return role }
    for child in node.children {
        if let role = firstButtonRole(child) { return role }
    }
    return nil
}

/// Per item, "1" when disabled, "0" when not, newline-joined; "" when no
/// item is (the common case adds nothing to the tree).
func _disabledParam(_ items: [_BarItem]) -> String {
    items.contains(where: \.disabled) ? items.map { $0.disabled ? "1" : "0" }.joined(separator: "\n") : ""
}

func _segmentsParam(_ items: [_BarItem]) -> String {
    items.map { ($0.segments ?? []).joined(separator: "\u{1F}") }.joined(separator: "\n")
}

/// First host-view spec of `kind` in a subtree.
func firstHostView(_ node: RenderNode, kind: String) -> HostViewSpec? {
    if case .hostView(let spec) = node.kind, spec.kind == kind { return spec }
    for child in node.children {
        if let spec = firstHostView(child, kind: kind) { return spec }
    }
    return nil
}

func _schemeParam() -> String {
    switch Runtime.shared.preferredColorScheme {
    case .light?: return "light"
    case .dark?: return "dark"
    default: return ""
    }
}

/// First `Image(systemName:)` in a subtree (a bar item's icon).
func firstSymbolName(_ node: RenderNode) -> String? {
    if let symbol = node.symbolName { return symbol }
    for child in node.children {
        if let symbol = firstSymbolName(child) { return symbol }
    }
    return nil
}

/// First `.accessibilityLabel` in a subtree (a bar item's icon-only button).
func firstAccessibilityLabel(_ node: RenderNode) -> String? {
    if let label = node.accessibilityLabel { return label }
    for child in node.children {
        if let label = firstAccessibilityLabel(child) { return label }
    }
    return nil
}

/// The first text in a subtree, skipping symbol glyphs (a Label's icon is
/// Whether a bar item's label is only words and symbols (what a bar can
/// draw as an item); anything else (a shape, an image, a background) is
/// the app's own view and is drawn as such.
func isPlainBarLabel(_ node: RenderNode) -> Bool {
    switch node.kind {
    case .text, .spacer, .stack: break
    case .box: if !node.background.isEmpty || !node.overlay.isEmpty { return false }
    case .image: if node.symbolName == nil { return false }
    default: return false
    }
    return node.children.allSatisfy(isPlainBarLabel)
}

/// A toolbar item's content: Labels in a toolbar are icon-only unless the
/// app set a label style (Apple's default on every platform).
@MainActor
func buildToolbarContent<V: View>(_ content: V, ctx: inout BuildContext) -> RenderNode {
    let pushed = Runtime.shared.labelStyleStack.isEmpty
    if pushed { Runtime.shared.labelStyleStack.append(.iconOnly) }
    defer { if pushed { Runtime.shared.labelStyleStack.removeLast() } }
    return buildNode(view: content, ctx: &ctx)
}

/// a text node too): a bar item's title is its words.
func firstText(_ node: RenderNode) -> String? {
    if case .text(let s) = node.kind, node.symbolName == nil { return s }
    for child in node.children {
        if let s = firstText(child) { return s }
    }
    return nil
}

/// The stand-in glyph of the first symbol in a subtree (an icon-only item's
/// title on hosts that show glyphs).
func symbolGlyphIn(_ node: RenderNode) -> String? {
    if case .text(let s) = node.kind, node.symbolName != nil { return s }
    for child in node.children {
        if let s = symbolGlyphIn(child) { return s }
    }
    return nil
}

/// First tap action in a subtree (a list cell's row action, e.g. a
/// NavigationLink), so a native list cell can fire it on tap.
func firstTapAction(_ node: RenderNode) -> (() -> Void)? {
    if let action = node.tapAction { return action }
    for child in node.children {
        if let action = firstTapAction(child) { return action }
    }
    return nil
}

/// First vertical scroll node in a subtree (where a large title is injected).
func firstVerticalScroll(_ node: RenderNode) -> RenderNode? {
    if case .scroll(let axis) = node.kind, axis == .vertical {
        return node
    }
    for child in node.children {
        if let found = firstVerticalScroll(child) {
            return found
        }
    }
    return nil
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension NavigationStack: View {}
extension NavigationView: View {}
extension _ColumnWidthView: View {}
extension NavigationSplitView: View {}
extension DrawnNavBar: View {}
extension DrawnSearchField: View {}
extension NavigationLink: View {}
extension _NavigationTitleView: View {}
extension _NavigationSubtitleView: View {}
extension _BottomSearchField: View {}
extension _BottomBarSearch: View {}
extension _BottomBarSpacer: View {}
extension _SafeAreaInsetView: View {}
extension _ToolbarView: View {}
extension _ToolbarTitleDisplayModeView: View {}
