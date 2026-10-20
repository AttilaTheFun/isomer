/// Apple's: what `.toolbar { … }` holds when it holds items rather than
/// views. `ToolbarItem`, `ToolbarItemGroup`, `DefaultToolbarItem` and
/// `ToolbarSpacer` are the primitive ones (`Body` is `Never`); an app's own
/// is its `body`, built by `@ToolbarContentBuilder` (blocks, `if`,
/// `switch`). Isomer's runtime builds each item as a view of its own, which
/// places itself in the bar: toolbar content comes down to those.
@MainActor @preconcurrency
public protocol ToolbarContent {
    associatedtype Body: ToolbarContent

    @ToolbarContentBuilder var body: Body { get }
}

extension Never: ToolbarContent {}

/// Toolbar content the runtime places itself: the item views it holds, in
/// order.
@MainActor
protocol PrimitiveToolbarContent {
    var toolbarViews: [AnyView] { get }
}

/// The item views toolbar content comes down to: a primitive's own, an
/// app's content's body's.
@MainActor
func placedToolbarViews<Content: ToolbarContent>(_ content: Content) -> [AnyView] {
    if Content.Body.self == Never.self {
        // An absent `if` is no content (a cast looks through an Optional).
        return (content as? any PrimitiveToolbarContent)?.toolbarViews ?? []
    }
    return placedToolbarViews(content.body)
}

@resultBuilder
public struct ToolbarContentBuilder {
    public static func buildExpression<Content: ToolbarContent>(_ content: Content) -> Content {
        content
    }

    public static func buildBlock<Content: ToolbarContent>(_ content: Content) -> some ToolbarContent {
        content
    }

    @_disfavoredOverload
    public static func buildBlock<each Content: ToolbarContent>(_ content: repeat each Content) -> some ToolbarContent {
        var elements: [any ToolbarContent] = []
        for element in repeat each content {
            elements.append(element)
        }
        return TupleToolbarContent(elements: elements)
    }

    public static func buildIf<Content: ToolbarContent>(_ content: Content?) -> Content? {
        content
    }

    public static func buildEither<TrueContent: ToolbarContent, FalseContent: ToolbarContent>(
        first: TrueContent
    ) -> _ConditionalContent<TrueContent, FalseContent> {
        _ConditionalContent(storage: .trueContent(first))
    }

    public static func buildEither<TrueContent: ToolbarContent, FalseContent: ToolbarContent>(
        second: FalseContent
    ) -> _ConditionalContent<TrueContent, FalseContent> {
        _ConditionalContent(storage: .falseContent(second))
    }
}

/// A block of toolbar content (Apple's is internal too).
struct TupleToolbarContent {
    let elements: [any ToolbarContent]
}

extension TupleToolbarContent: ToolbarContent, PrimitiveToolbarContent {
    typealias Body = Never
    var body: Never { return fatalError("primitive toolbar content") }

    var toolbarViews: [AnyView] {
        elements.flatMap { placedToolbarViews($0) }
    }
}

extension _ConditionalContent: ToolbarContent where TrueContent: ToolbarContent, FalseContent: ToolbarContent {}

extension _ConditionalContent: PrimitiveToolbarContent where TrueContent: ToolbarContent, FalseContent: ToolbarContent {
    var toolbarViews: [AnyView] {
        switch storage {
        case .trueContent(let content): return placedToolbarViews(content)
        case .falseContent(let content): return placedToolbarViews(content)
        }
    }
}

extension Optional: ToolbarContent where Wrapped: ToolbarContent {
    public var body: Never { return fatalError("primitive toolbar content") }
}

extension Optional: PrimitiveToolbarContent where Wrapped: ToolbarContent {
    var toolbarViews: [AnyView] {
        switch self {
        case .some(let content): return placedToolbarViews(content)
        case .none: return []
        }
    }
}

// The items: toolbar content the runtime builds as views of its own, which
// place themselves in the bar. Apple's items are not views, so neither are
// Isomer's: each is built through `_ToolbarItemView`.
extension ToolbarItem: ToolbarContent, PrimitiveToolbarContent {
    var toolbarViews: [AnyView] { [AnyView(_ToolbarItemView(item: self))] }
}

extension ToolbarItemGroup: ToolbarContent, PrimitiveToolbarContent {
    var toolbarViews: [AnyView] { [AnyView(_ToolbarItemView(item: self))] }
}

extension DefaultToolbarItem: ToolbarContent, PrimitiveToolbarContent {
    var toolbarViews: [AnyView] { [AnyView(_ToolbarItemView(item: self))] }
}

extension ToolbarSpacer: ToolbarContent, PrimitiveToolbarContent {
    var toolbarViews: [AnyView] { [AnyView(_ToolbarItemView(item: self))] }
}

/// A toolbar item as the view the runtime builds: the item's own node, and
/// its reuse answers.
struct _ToolbarItemView<Item: _PrimitiveView>: _PrimitiveView {
    let item: Item

    static var _isReusableBuild: Bool { Item._isReusableBuild }

    func _buildIsPure(_ ctx: BuildContext) -> Bool { item._buildIsPure(ctx) }

    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode { item.makeNode(&ctx) }
}

extension _ToolbarItemView: View {}

extension _ToolbarItemView: _ReusableBuild where Item: _ReusableBuild {
    func _buildsPurely(_ ctx: BuildContext) -> Bool { item._buildsPurely(ctx) }
}

extension View {
    nonisolated public func toolbar<Content: ToolbarContent>(
        @ToolbarContentBuilder content: () -> Content
    ) -> some View {
        _ToolbarView(child: self, content: _ToolbarItems(content: content()))
    }
}

/// Toolbar content as the toolbar modifier's content view: its items, each
/// built in turn (registering itself with the bar).
struct _ToolbarItems<Content: ToolbarContent> {
    let content: Content

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _ToolbarItems: _MultiView {
    func childViews() -> [(suffix: String, view: any View)] {
        MainActor.assumeIsolated {
            placedToolbarViews(content).enumerated().map { (String($0.offset), $0.element) }
        }
    }
}

extension _ToolbarItems: View {}
