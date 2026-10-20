/// Main-actor isolated, as SwiftUI's is: a type that says it is a `View`
/// where it is declared lives on the main actor, `body` and all. (Isomer's
/// own views take the conformance in an extension instead, which leaves
/// their initializers free to be called from anywhere — Apple's are
/// `nonisolated` to the same end — and the modifiers in `extension View`
/// are `nonisolated` for it too.) `@preconcurrency`, as SwiftUI's also is:
/// code in the Swift 5 language mode that makes a view of its own outside
/// the main actor is not refused for it; Swift 6 code is held to it.
@MainActor @preconcurrency
public protocol View {
    associatedtype Body: View

    @ViewBuilder var body: Body { get }
}

extension Never: View {
    public typealias Body = Never
}

extension View where Body == Never {
    /// A primitive view has no body: the runtime builds its node itself.
    /// (Apple's primitive views keep theirs out of their interface; this
    /// one declaration stands for all of Isomer's.)
    public var body: Never { fatalError("primitive view") }
}

public struct EmptyView {
    public init() {}
    public typealias Body = Never
}

/// A type-erased view.
public struct AnyView {
    let wrapped: any View

    public init<V: View>(_ view: V) {
        wrapped = view
    }

    public typealias Body = Never
}

// MARK: - Internal build protocols

/// Views that translate directly into render nodes rather than via `body`.
protocol _PrimitiveView {
    /// Called while the tree is built, on the main actor.
    @MainActor func makeNode(_ ctx: inout BuildContext) -> RenderNode
    /// Whether the view is a `_ReusableBuild`, and whether this build of it
    /// is pure (`_buildsPurely`): answered through this conformance (the
    /// defaults below), not asked as a cast, whose first answer for each
    /// type, yes or no, scanned every conformance in the program.
    static var _isReusableBuild: Bool { get }
    func _buildIsPure(_ ctx: BuildContext) -> Bool
}

extension _PrimitiveView {
    static var _isReusableBuild: Bool { false }
    func _buildIsPure(_ ctx: BuildContext) -> Bool { false }
}

extension _PrimitiveView where Self: _ReusableBuild {
    static var _isReusableBuild: Bool { true }
    func _buildIsPure(_ ctx: BuildContext) -> Bool { _buildsPurely(ctx) }
}

/// Views that represent zero or more child views (TupleView, ForEach, if/else
/// content, ...). Containers flatten these when collecting children.
protocol _MultiView {
    func childViews() -> [(suffix: String, view: any View)]
}

extension EmptyView: _MultiView {
    func childViews() -> [(suffix: String, view: any View)] { [] }
}

extension AnyView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var sub = ctx.descend("any")
        return buildNode(view: wrapped, ctx: &sub)
    }
}

public struct TupleView<T> {
    let elements: [any View]

    init(_ elements: [any View]) {
        self.elements = elements
    }

    public typealias Body = Never
}

extension TupleView: _MultiView {
    func childViews() -> [(suffix: String, view: any View)] {
        elements.enumerated().map { (String($0.offset), $0.element) }
    }
}

/// An `if`/`else` or `switch` of views (or of toolbar content: Apple's
/// is unconstrained, its conformances conditional, and so is this one).
public struct _ConditionalContent<TrueContent, FalseContent> {
    enum Storage {
        case trueContent(TrueContent)
        case falseContent(FalseContent)
    }

    let storage: Storage

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension _ConditionalContent: _MultiView where TrueContent: View, FalseContent: View {
    func childViews() -> [(suffix: String, view: any View)] {
        switch storage {
        case .trueContent(let view): return [("then", view)]
        case .falseContent(let view): return [("else", view)]
        }
    }
}

extension Optional: View where Wrapped: View {
    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension Optional: _MultiView where Wrapped: View {
    func childViews() -> [(suffix: String, view: any View)] {
        switch self {
        case .some(let view): return [("some", view)]
        case .none: return []
        }
    }
}

public struct Group<Content: View> {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension Group: _MultiView {
    func childViews() -> [(suffix: String, view: any View)] {
        [("group", content)]
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension EmptyView: View {}
extension AnyView: View {}
extension TupleView: View {}
extension _ConditionalContent: View where TrueContent: View, FalseContent: View {}
extension Group: View {}
