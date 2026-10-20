// `ViewModifier` and `.modifier(_:)`: a reusable modification with a body of
// its own. The modifier's `@State` and environment are the modified view's
// (see connectDynamicProperties), as in SwiftUI.

@MainActor @preconcurrency
public protocol ViewModifier {
    associatedtype Body: View
    typealias Content = _ViewModifier_Content<Self>
    @ViewBuilder func body(content: Content) -> Body
}

/// The view a `ViewModifier` modifies, as its `body(content:)` sees it.
public struct _ViewModifier_Content<Modifier: ViewModifier> {
    let view: AnyView

    public var body: some View { view }
}

/// A view with a modifier applied.
public struct ModifiedContent<Content: View, Modifier: ViewModifier> {
    public let content: Content
    public let modifier: Modifier

    public init(content: Content, modifier: Modifier) {
        self.content = content
        self.modifier = modifier
    }

    @MainActor
    public var body: some View {
        modifier.body(content: _ViewModifier_Content(view: AnyView(content)))
    }
}

extension View {
    nonisolated public func modifier<Modifier: ViewModifier>(_ modifier: Modifier) -> ModifiedContent<Self, Modifier> {
        ModifiedContent(content: self, modifier: modifier)
    }
}


/// A `ModifiedContent` seen through its content, whatever its types (a
/// list finds a row's tag under the app's own modifier).
protocol _AnyModifiedContent {
    var _contentView: any View { get }
}

extension ModifiedContent: _AnyModifiedContent {
    var _contentView: any View { content }
}

// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension _ViewModifier_Content: View {}
extension ModifiedContent: View {}
