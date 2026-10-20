// Presentations: sheet / popover / alert. On the reimplementation these are
// drawn overlays (a dimming scrim plus a panel/dialog) rendered on top of the
// whole screen after the root; on Apple the real SwiftUI modifiers are used.

enum PresentationStyle {
    case sheet
    /// `.fullScreenCover`: a sheet that takes the whole screen.
    case cover
    case popover
    case alert(title: String, message: String)
    /// Something the host presents and answers on its own (a file or photo
    /// picker, the camera): `kind` and `params` say what; `onResult` gets
    /// its answer (the picked files' paths, newline-separated; "" when
    /// cancelled). Nothing is drawn for it here.
    case request(kind: String, params: [(String, String)], onResult: (String) -> Void)
}

/// A presentation registered during the build pass and drawn screen-wide after
/// the root in `renderFrame`.
struct PendingPresentation {
    let id: String
    let style: PresentationStyle
    let content: RenderNode
    let dismiss: () -> Void
    /// A popover's attachment ("rect", "point:x,y") and arrow edge
    /// ("top", "leading", "bottom", "trailing"; nil, the system's).
    var popoverAttachment: String? = nil
    var popoverArrowEdge: String? = nil
}

struct _PresentationModifier<PresentedContent: View> {
    let child: any View
    let isPresented: Binding<Bool>
    let style: PresentationStyle
    let makeContent: () -> PresentedContent
    /// `onDismiss:`: called once the presentation has gone, however it went
    /// (a swipe, `dismiss`, the app's own binding).
    var onDismiss: (() -> Void)? = nil
    /// A popover's attachment and arrow edge (PendingPresentation's).
    var popoverAttachment: String? = nil
    var popoverArrowEdge: String? = nil

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _PresentationModifier: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var sub = ctx.descend("presented")
        var childNode = buildNode(view: child, ctx: &sub)
        if case .popover = style {
            // The view the popover hangs from, named by the popover's id
            // whether or not it shows (what wraps the view stays the same).
            let anchor = RenderNode.box(child: childNode)
            anchor.popoverAnchor = ctx.path
            childNode = anchor
        }

        if let onDismiss {
            // Shown last time it was built and not now: it was dismissed.
            if isPresented.wrappedValue { _presentationsShown.insert(ctx.path) }
            else if _presentationsShown.remove(ctx.path) != nil { Runtime.shared.registerFrameEffect { onDismiss() } }
        }
        if isPresented.wrappedValue {
            var contentCtx = ctx.descend("sheet-content")
            let binding = isPresented
            // Make `@Environment(\.dismiss)` inside the presented content close it.
            contentCtx.env.dismiss = DismissAction(action: { binding.wrappedValue = false })
            contentCtx.env.isPresented = true
            if case .sheet = style { contentCtx.env.inSheet = true }
            // What is presented from a row is not in it.
            contentCtx.env.formRow = false
            // This layer's slot comes BEFORE anything the content presents
            // (an alert inside a cover is registered while the content
            // builds, and must draw above the cover, not under it).
            let slot = Runtime.shared.pendingPresentations.count
            let contentNode: RenderNode
            if case .alert = style {
                // Alert actions sit side by side (a bare tuple would stack in depth).
                let actions = makeContent()
                contentNode = buildNode(view: HStack(spacing: 24) { actions }, ctx: &contentCtx)
                // SwiftUI dismisses an alert when any of its actions runs.
                for (button, _) in tapTargets(contentNode) {
                    guard let action = button.tapAction else { continue }
                    button.tapAction = {
                        action()
                        binding.wrappedValue = false
                    }
                }
            } else {
                contentNode = buildNode(view: makeContent(), ctx: &contentCtx)
            }
            Runtime.shared.pendingPresentations.insert(PendingPresentation(
                id: ctx.path,
                style: style,
                content: contentNode,
                dismiss: { binding.wrappedValue = false },
                popoverAttachment: popoverAttachment,
                popoverArrowEdge: popoverArrowEdge
            ), at: slot)
        }
        return childNode
    }
}

/// The presentations with an `onDismiss` that were showing when last built,
/// by where they are in the tree.
@MainActor var _presentationsShown = Set<String>()

/// An optional item's presentation as a Bool one: presented while there is
/// an item, cleared when dismissed.
func _presenting<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
    Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
}

/// What an item's presentation shows: the content for the item there is
/// (nothing once it is cleared, while the presentation leaves).
struct _ItemPresented<Item, Content: View>: View {
    let item: Binding<Item?>
    let content: (Item) -> Content

    var body: some View {
        if let value = item.wrappedValue { content(value) }
    }
}

extension View {
    nonisolated public func sheet<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        _PresentationModifier(
            child: self, isPresented: isPresented, style: .sheet, makeContent: content, onDismiss: onDismiss
        )
    }

    /// `.sheet(item:onDismiss:content:)`: presented while `item` is not
    /// nil, with the content for it; dismissing clears it.
    nonisolated public func sheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        _PresentationModifier(
            child: self, isPresented: _presenting(item), style: .sheet,
            makeContent: { _ItemPresented(item: item, content: content) }, onDismiss: onDismiss
        )
    }

    /// `.fullScreenCover(isPresented:content:)`: the content covers the
    /// whole screen (no scrim edge, no swipe-down affordance); it leaves
    /// through `@Environment(\.dismiss)` or the binding.
    nonisolated public func fullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        _PresentationModifier(
            child: self, isPresented: isPresented, style: .cover, makeContent: content, onDismiss: onDismiss
        )
    }

    /// `.fullScreenCover(item:onDismiss:content:)`.
    nonisolated public func fullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        _PresentationModifier(
            child: self, isPresented: _presenting(item), style: .cover,
            makeContent: { _ItemPresented(item: item, content: content) }, onDismiss: onDismiss
        )
    }

    /// `.alert(_:isPresented:presenting:actions:message:)`: an alert about
    /// `data` (its actions and message made from it), shown while
    /// presented and there is data.
    nonisolated public func alert<Actions: View, Message: View, T, S: StringProtocol>(
        _ title: S,
        isPresented: Binding<Bool>,
        presenting data: T?,
        @ViewBuilder actions: @escaping (T) -> Actions,
        @ViewBuilder message: (T) -> Message
    ) -> some View {
        let title = String(title)
        let messageText = data.map { _extractText(message($0)) } ?? ""
        let shown = Binding(get: { isPresented.wrappedValue && data != nil }, set: { isPresented.wrappedValue = $0 })
        return _PresentationModifier(
            child: self, isPresented: shown, style: .alert(title: title, message: messageText),
            makeContent: { _ItemPresented(item: .constant(data), content: actions) }
        )
    }

    nonisolated public func alert<Actions: View, T, S: StringProtocol>(
        _ title: S,
        isPresented: Binding<Bool>,
        presenting data: T?,
        @ViewBuilder actions: @escaping (T) -> Actions
    ) -> some View {
        let title = String(title)
        let shown = Binding(get: { isPresented.wrappedValue && data != nil }, set: { isPresented.wrappedValue = $0 })
        return _PresentationModifier(
            child: self, isPresented: shown, style: .alert(title: title, message: ""),
            makeContent: { _ItemPresented(item: .constant(data), content: actions) }
        )
    }

    /// `.confirmationDialog(_:isPresented:titleVisibility:presenting:actions:)`.
    nonisolated public func confirmationDialog<Actions: View, T, S: StringProtocol>(
        _ title: S,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        presenting data: T?,
        @ViewBuilder actions: @escaping (T) -> Actions
    ) -> some View {
        let title = String(title)
        let shown = Binding(get: { isPresented.wrappedValue && data != nil }, set: { isPresented.wrappedValue = $0 })
        return _PresentationModifier(
            child: self, isPresented: shown,
            style: .alert(title: titleVisibility == .hidden ? "" : title, message: ""),
            makeContent: { _ItemPresented(item: .constant(data), content: actions) }
        )
    }

    /// `.confirmationDialog`: an alert-shaped panel (title, optional
    /// message, the action buttons) — the reimplementation has one modal
    /// dialog shape; `titleVisibility` is accepted for parity.
    nonisolated public func confirmationDialog<Actions: View, S: StringProtocol>(
        _ title: S,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        let title = String(title)
        return _PresentationModifier(
            child: self,
            isPresented: isPresented,
            style: .alert(title: titleVisibility == .hidden ? "" : title, message: ""),
            makeContent: actions
        )
    }

    nonisolated public func confirmationDialog<Actions: View, Message: View, S: StringProtocol>(
        _ title: S,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: @escaping () -> Actions,
        @ViewBuilder message: () -> Message
    ) -> some View {
        let title = String(title)
        let messageText = _extractText(message())
        return _PresentationModifier(
            child: self,
            isPresented: isPresented,
            style: .alert(title: titleVisibility == .hidden ? "" : title, message: messageText),
            makeContent: actions
        )
    }

    /// Sheet behaviour, carried on the presented content for the host's
    /// sheet: no swipe-down dismissal, the detents it may rest at, the
    /// grabber's visibility.
    nonisolated public func interactiveDismissDisabled(_ isDisabled: Bool = true) -> some View {
        _ModifiedView(child: self, descend: "nodismiss", pure: true) { inner, _ in
            inner.presentationDismissDisabled = isDisabled
            return inner
        }
    }
    nonisolated public func presentationDetents(_ detents: Set<PresentationDetent>) -> some View {
        _ModifiedView(child: self, descend: "detents", pure: true) { inner, _ in
            inner.presentationDetents = [detents.contains(.medium) ? "medium" : nil, detents.contains(.large) ? "large" : nil]
                .compactMap { $0 }.joined(separator: ",")
            return inner
        }
    }
    nonisolated public func presentationDragIndicator(_ visibility: Visibility) -> some View {
        _ModifiedView(child: self, descend: "grabber", pure: true) { inner, _ in
            inner.presentationDragIndicator = visibility == .hidden ? "hidden" : "visible"
            return inner
        }
    }
    /// How a popover shows at a compact size, carried on its content for
    /// hosts that present popovers natively (Apple's); the others draw a
    /// popover as a popover at every size.
    nonisolated public func presentationCompactAdaptation(_ adaptation: PresentationAdaptation) -> some View {
        presentationCompactAdaptation(horizontal: adaptation, vertical: adaptation)
    }
    nonisolated public func presentationCompactAdaptation(
        horizontal horizontalAdaptation: PresentationAdaptation,
        vertical verticalAdaptation: PresentationAdaptation
    ) -> some View {
        _ModifiedView(child: self, descend: "compactAdaptation", pure: true) { inner, _ in
            inner.presentationCompactAdaptation = "\(horizontalAdaptation.kind),\(verticalAdaptation.kind)"
            return inner
        }
    }
    /// `.textSelection(.enabled)`: the text in this view can be selected and
    /// copied (`.disabled`: it can't), an inner one overriding an outer one.
    /// Hosts select ranges where that is their platform's way (Compose's
    /// SelectionContainer, the web's own selection).
    nonisolated public func textSelection<S: TextSelectability>(_ selectability: S) -> some View {
        _ModifiedView(child: self, descend: "textselection", pure: true) { inner, _ in
            inner.textSelection = S.allowsSelection
            return inner
        }
    }

    nonisolated public func popover<Content: View>(
        isPresented: Binding<Bool>,
        attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
        arrowEdge: Edge? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let attachment: String
        switch attachmentAnchor {
        case .rect: attachment = "rect"
        case .point(let point): attachment = "point:\(point.x),\(point.y)"
        }
        let edge: String? = arrowEdge.map {
            switch $0 {
            case .top: "top"
            case .leading: "leading"
            case .bottom: "bottom"
            case .trailing: "trailing"
            }
        }
        return _PresentationModifier(
            child: self, isPresented: isPresented, style: .popover, makeContent: content,
            popoverAttachment: attachment, popoverArrowEdge: edge
        )
    }

    nonisolated public func alert<Actions: View, Message: View, S: StringProtocol>(
        _ title: S,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: @escaping () -> Actions,
        @ViewBuilder message: () -> Message
    ) -> some View {
        let title = String(title)
        // Capture the message text now; actions are rebuilt as the panel body.
        let messageText = _extractText(message())
        return _PresentationModifier(
            child: self,
            isPresented: isPresented,
            style: .alert(title: title, message: messageText),
            makeContent: actions
        )
    }

    nonisolated public func alert<Actions: View, S: StringProtocol>(
        _ title: S,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        let title = String(title)
        return _PresentationModifier(
            child: self,
            isPresented: isPresented,
            style: .alert(title: title, message: ""),
            makeContent: actions
        )
    }
}

/// Whether text can be selected (`.textSelection(.enabled)`): Apple's
/// protocol, with its two kinds.
/// Where a popover points: a rect of the view (`.rect(.bounds)`) or a point
/// in it. Hosts place popovers by the view's frame.
public enum PopoverAttachmentAnchor {
    case rect(Anchor<CGRect>.Source)
    case point(UnitPoint)
}

/// A value (a rect, a point) of a view's geometry, as SwiftUI's anchors
/// carry it.
public struct Anchor<Value> {
    /// Where an anchor's value comes from.
    public struct Source {
        let rect: CGRect?
        let point: UnitPoint?
    }
}

extension Anchor.Source where Value == CGRect {
    public static var bounds: Anchor<CGRect>.Source { Anchor<CGRect>.Source(rect: nil, point: nil) }
    public static func rect(_ r: CGRect) -> Anchor<Value>.Source { Anchor<Value>.Source(rect: r, point: nil) }
}

public protocol TextSelectability {
    static var allowsSelection: Bool { get }
}

public struct EnabledTextSelectability: TextSelectability {
    public static let allowsSelection = true
}

public struct DisabledTextSelectability: TextSelectability {
    public static let allowsSelection = false
}

extension TextSelectability where Self == EnabledTextSelectability {
    public static var enabled: EnabledTextSelectability { EnabledTextSelectability() }
}

extension TextSelectability where Self == DisabledTextSelectability {
    public static var disabled: DisabledTextSelectability { DisabledTextSelectability() }
}

/// `.presentationDetents` sizes.
public struct PresentationDetent: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case medium, large }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    public static let medium = PresentationDetent(.medium)
    public static let large = PresentationDetent(.large)
}

/// `.presentationCompactAdaptation` kinds.
public struct PresentationAdaptation: Sendable {
    enum Kind: Sendable { case automatic, none, popover, sheet, fullScreenCover }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    public static var automatic: PresentationAdaptation { PresentationAdaptation(.automatic) }
    public static var none: PresentationAdaptation { PresentationAdaptation(.none) }
    public static var popover: PresentationAdaptation { PresentationAdaptation(.popover) }
    public static var sheet: PresentationAdaptation { PresentationAdaptation(.sheet) }
    public static var fullScreenCover: PresentationAdaptation { PresentationAdaptation(.fullScreenCover) }
}

/// Best-effort extraction of a Text view's string (for the alert message).
func _extractText(_ view: any View) -> String {
    if let text = view as? Text {
        return text.content
    }
    return ""
}

// MARK: - Building the overlay node tree

func buildPresentationNode(
    _ presentation: PendingPresentation, screen: CGSize, progress: Double
) -> RenderNode {
    let overlay = RenderNode(kind: .stack(.depth))
    overlay.stackAlignment = .center
    overlay.expandsWidth = true
    overlay.expandsHeight = true

    // Dimming scrim that dismisses on tap (fades in with progress).
    let scrim = RenderNode(kind: .shape(.rectangle, fill: Color(white: 0, opacity: 0.35 * progress), stroke: nil))
    scrim.expandsWidth = true
    scrim.expandsHeight = true
    let scrimBox = RenderNode.box(child: scrim)
    scrimBox.expandsWidth = true
    scrimBox.expandsHeight = true
    scrimBox.tapAction = presentation.dismiss
    overlay.children.append(scrimBox)

    switch presentation.style {
    case .cover:
        // The whole screen: the content over an opaque panel, no scrim.
        let panel = RenderNode.box(child: presentation.content)
        panel.background = [filledRect(Color.windowBackground)]
        panel.expandsWidth = true
        panel.expandsHeight = true
        panel.offsetY = (1 - progress) * screen.height
        overlay.children.append(panel)

    case .sheet:
        // A bottom sheet: a panel rounded on top that slides up from below. It
        // grows with its content between a minimum and a cap (most of the
        // screen); past the cap the content scrolls inside the panel rather than
        // running off-screen.
        let maxPanel = screen.height * 0.9
        let corner: CGFloat = 20
        let panel = RenderNode.box(child: presentation.content)
        panel.padding = EdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20)
        panel.background = [filledRect(Color.secondaryBackground)]
        panel.cornerRadius = corner
        panel.expandsWidth = true
        panel.minHeight = screen.height * 0.45
        panel.maxHeight = maxPanel
        // Anchor the panel to the bottom (the flexible spacer above pushes it
        // down) and slide it up from below with `offsetY`: at rest it's pushed
        // down by `corner` so its bottom rounded corners sit just off-screen,
        // leaving only the top corners rounded (iOS-style); at progress 0 it's a
        // full `maxPanel` lower, i.e. entirely below the screen.
        panel.offsetY = corner + (1 - progress) * maxPanel
        let bottomAlign = RenderNode(kind: .stack(.vertical))
        bottomAlign.stackSpacing = 0
        bottomAlign.expandsWidth = true
        bottomAlign.expandsHeight = true
        let spacer = RenderNode(kind: .spacer(nil))
        spacer.spacerAxis = .vertical
        bottomAlign.children = [spacer, panel]
        overlay.children.append(bottomAlign)

    case .popover:
        let panel = RenderNode.box(child: presentation.content)
        panel.padding = EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        panel.background = [filledRect(Color.secondaryBackground)]
        panel.cornerRadius = 14
        panel.shadow = ShadowSpec(color: Color(white: 0, opacity: 0.3), radius: 16, x: 0, y: 4)
        panel.maxWidth = 360
        panel.opacity = progress
        overlay.children.append(panel)

    case .request:
        // The host's own picker; the self-drawing path has none yet.
        break

    case .alert(let title, let message):
        let column = RenderNode(kind: .stack(.vertical))
        column.stackSpacing = 10
        column.stackAlignment = .center

        let titleNode = RenderNode(kind: .text(title))
        titleNode.font = .headline
        titleNode.color = .primary
        column.children.append(titleNode)

        if !message.isEmpty {
            let messageNode = RenderNode(kind: .text(message))
            messageNode.font = .subheadline
            messageNode.color = .secondary
            column.children.append(messageNode)
        }
        // The action buttons (already a node) sit below the message.
        column.children.append(presentation.content)

        let panel = RenderNode.box(child: column)
        panel.padding = EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24)
        panel.background = [filledRect(Color.secondaryBackground)]
        panel.cornerRadius = 14
        panel.shadow = ShadowSpec(color: Color(white: 0, opacity: 0.3), radius: 24, x: 0, y: 6)
        panel.fixedWidth = min(320, screen.width - 48)
        panel.opacity = progress
        overlay.children.append(panel)
    }
    return overlay
}

private func filledRect(_ color: Color) -> RenderNode {
    RenderNode(kind: .shape(.rectangle, fill: color, stroke: nil))
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension _PresentationModifier: View {}
