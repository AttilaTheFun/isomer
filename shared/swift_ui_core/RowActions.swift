// Row actions: `.contextMenu` (a long press or secondary click opens a menu
// of the given buttons) and `.swipeActions` (buttons revealed by a
// horizontal swipe on a list row). Both ride the wrapped node as items the
// host draws in its own idiom; the actions stay in the guest.

public enum HorizontalEdge: Sendable, Equatable {
    case leading
    case trailing
}

/// One row action: a button's title, its symbol (a `Label`'s), whether it is
/// destructive, its `.tint` (a swipe button's colour), and what it does.
struct RowActionItem {
    var title: String
    var symbol: String?
    var destructive: Bool
    var tint: Color? = nil
    var action: () -> Void
}

extension View {
    /// A menu of actions on a long press (or a secondary click).
    nonisolated public func contextMenu<MenuItems: View>(@ViewBuilder menuItems: () -> MenuItems) -> some View {
        let items = menuItems()
        return _ModifiedView(child: self, descend: "ctxmenu", pure: true) { inner, ctx in
            var collected: [RowActionItem] = []
            collectRowActions(items, ctx: &ctx, into: &collected)
            let box = RenderNode(kind: .box)
            box.children = [inner]
            box.contextMenuItems = collected
            return box
        }
    }

    /// Buttons revealed by swiping a list row from `edge`; a full swipe
    /// performs the first one when `allowsFullSwipe`.
    nonisolated public func swipeActions<Content: View>(edge: HorizontalEdge = .trailing, allowsFullSwipe: Bool = true,
                                            @ViewBuilder content: () -> Content) -> some View {
        let actions = content()
        return _ModifiedView(child: self, descend: "swipe", pure: true) { inner, ctx in
            var collected: [RowActionItem] = []
            collectRowActions(actions, ctx: &ctx, into: &collected)
            let box = RenderNode(kind: .box)
            box.children = [inner]
            box.swipeItems.append(contentsOf: collected.map { item in
                (edge: edge, fullSwipe: allowsFullSwipe, item: item)
            })
            // Swipe actions on an already-wrapped row: keep one box (a new
            // one — the inner may be a reused subtree's, never changed in
            // place).
            if case .box = inner.kind, !inner.swipeItems.isEmpty, inner.children.count == 1 {
                let merged = RenderNode(kind: .box)
                merged.children = inner.children
                merged.swipeItems = inner.swipeItems + box.swipeItems
                return merged
            }
            return box
        }
    }
}

@MainActor
func collectRowActions(_ view: any View, ctx: inout BuildContext, into items: inout [RowActionItem]) {
    if let button = view as? _AnyButton {
        var sub = ctx.descend("lbl")
        let node = buildNode(view: button._labelView, ctx: &sub)
        items.append(RowActionItem(title: firstTextIn(node) ?? "", symbol: firstSymbolIn(node),
                                   destructive: button._role == .destructive, tint: ctx.env.tint, action: button._action))
        return
    }
    // An environment modifier around a button (`.tint(.orange)` is one):
    // the button is inside it, with the environment it sets.
    if let environment = view as? _EnvironmentModifier {
        var sub = ctx
        environment.transform(&sub.env)
        collectRowActions(environment.child, ctx: &sub, into: &items)
        return
    }
    if let multi = view as? _MultiView {
        for entry in multi.childViews() {
            var sub = ctx.descend(entry.suffix)
            collectRowActions(entry.view, ctx: &sub, into: &items)
        }
        return
    }
    if let modified = view as? _ModifiedView {
        collectRowActions(modified.child, ctx: &ctx, into: &items)
    }
}

func firstSymbolIn(_ node: RenderNode) -> String? {
    if let symbol = node.symbolName { return symbol }
    for child in node.children {
        if let found = firstSymbolIn(child) { return found }
    }
    return nil
}

/// The `.tag(_:)` on a row, through the modifiers around it (a tagged row
/// with a context menu or swipe actions is still that row).
func rowTag(of view: any View) -> AnyHashable? {
    // (An app's own view is neither: FieldRecords.swift.)
    guard _mayConformInternally(type(of: view)) else { return nil }
    if let tagged = view as? _AnyTaggedView { return tagged.tagValue }
    if let modified = view as? _ModifiedView { return rowTag(of: modified.child) }
    // A tag under an app's own modifier (`.tag(x).modifier(Row())`) or in
    // an AnyView is the row's too, as SwiftUI's traits rise.
    if let modified = view as? _AnyModifiedContent { return rowTag(of: modified._contentView) }
    if let any = view as? AnyView { return rowTag(of: any.wrapped) }
    return nil
}
