// `.progressViewStyle`: how the ProgressViews inside are drawn. Isomer's
// built-in styles pick the host's indicator (param "pstyle": a linear bar,
// a circular one, each determinate or not); an app's own style makes the
// whole view from the progress's fraction and labels.

/// How a progress view is drawn: Apple's protocol.
@MainActor @preconcurrency
public protocol ProgressViewStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = ProgressViewStyleConfiguration
}

/// A progress view's parts, as a `ProgressViewStyle` gets them.
public struct ProgressViewStyleConfiguration {
    @MainActor @preconcurrency
    public struct Label: View {
        let content: AnyView
        public typealias Body = Never
    }

    @MainActor @preconcurrency
    public struct CurrentValueLabel: View {
        let content: AnyView
        public typealias Body = Never
    }

    /// The fraction done (0...1), or nil when indeterminate.
    public let fractionCompleted: Double?
    public var label: ProgressViewStyleConfiguration.Label?
    public var currentValueLabel: ProgressViewStyleConfiguration.CurrentValueLabel?
}

extension ProgressViewStyleConfiguration.Label: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode { content.makeNode(&ctx) }
}

extension ProgressViewStyleConfiguration.CurrentValueLabel: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode { content.makeNode(&ctx) }
}

/// The styles Isomer draws itself: the host's indicator of that kind.
protocol _BuiltInProgressViewStyle {
    var _kind: String { get }
}

public struct DefaultProgressViewStyle: ProgressViewStyle, _BuiltInProgressViewStyle {
    nonisolated public init() {}
    public func makeBody(configuration: Configuration) -> some View { ProgressView(configuration) }
    nonisolated var _kind: String { "" }
}

public struct LinearProgressViewStyle: ProgressViewStyle, _BuiltInProgressViewStyle {
    nonisolated public init() {}
    public func makeBody(configuration: Configuration) -> some View { ProgressView(configuration) }
    nonisolated var _kind: String { "linear" }
}

public struct CircularProgressViewStyle: ProgressViewStyle, _BuiltInProgressViewStyle {
    nonisolated public init() {}
    public func makeBody(configuration: Configuration) -> some View { ProgressView(configuration) }
    nonisolated var _kind: String { "circular" }
}

extension ProgressViewStyle where Self == DefaultProgressViewStyle {
    public static var automatic: DefaultProgressViewStyle { DefaultProgressViewStyle() }
}

extension ProgressViewStyle where Self == LinearProgressViewStyle {
    nonisolated public static var linear: LinearProgressViewStyle { LinearProgressViewStyle() }
}

extension ProgressViewStyle where Self == CircularProgressViewStyle {
    nonisolated public static var circular: CircularProgressViewStyle { CircularProgressViewStyle() }
}

/// The style in scope: a built-in kind, or an app's style's body. Equal by
/// kind and the style's type (for reuse; its closure isn't compared).
struct _ProgressViewStyleChoice: Equatable {
    var kind: String
    var custom: (@MainActor (ProgressViewStyleConfiguration) -> AnyView)?
    var customType: ObjectIdentifier?

    static func == (a: _ProgressViewStyleChoice, b: _ProgressViewStyleChoice) -> Bool {
        a.kind == b.kind && a.customType == b.customType
    }
}

struct _ProgressViewStyleKey: EnvironmentKey {
    static let defaultValue: _ProgressViewStyleChoice? = nil
}

extension View {
    /// The style of the ProgressViews inside.
    nonisolated public func progressViewStyle<S>(_ style: S) -> some View where S: ProgressViewStyle {
        let choice: _ProgressViewStyleChoice
        if let builtIn = style as? _BuiltInProgressViewStyle {
            choice = _ProgressViewStyleChoice(kind: builtIn._kind)
        } else {
            choice = _ProgressViewStyleChoice(
                kind: "",
                custom: { configuration in AnyView(style.makeBody(configuration: configuration)) },
                customType: ObjectIdentifier(S.self))
        }
        return _EnvironmentModifier(child: self, descend: "pstyle") { env in env[_ProgressViewStyleKey.self] = choice }
    }
}

extension ProgressView where Label == ProgressViewStyleConfiguration.Label {
    /// The progress a style was given, drawn as Isomer's (a custom style's
    /// body uses it for the standard indicator): it takes no app style.
    public init(_ configuration: ProgressViewStyleConfiguration) {
        self.value = configuration.fractionCompleted
        self.label = configuration.label ?? ProgressViewStyleConfiguration.Label(content: AnyView(EmptyView()))
        self.hasLabel = configuration.label != nil
        self.fromConfiguration = true
    }
}
