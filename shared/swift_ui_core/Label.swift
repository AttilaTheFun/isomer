// `Label` — a title + icon pair, SwiftUI's shape. The mainstream form is
// `Label("Refresh", systemImage: "arrow.clockwise")`: the SF name renders
// through `Image(systemName:)`'s text-glyph mapping. Composed (icon leading,
// like Apple), so it works everywhere a view does; in a `.toolbar` item the
// toolbar item builds its content under `.iconOnly` (Apple's default for
// Labels in toolbars), so the bar shows the glyph named by the title.

public struct Label<Title: View, Icon: View> {
    let title: Title
    let icon: Icon

    public init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) {
        self.title = title()
        self.icon = icon()
    }

    @MainActor @ViewBuilder
    public var body: some View {
        let style = Runtime.shared.labelStyleStack.last ?? .automatic
        switch style.kind {
        case .custom:
            if let custom = style.custom { custom(AnyView(title), AnyView(icon)) }
        case .iconOnly:
            // The title still names the icon (a bar item's aria-label).
            if let text = title as? Text { icon.accessibilityLabel(text.content) } else { icon }
        case .titleOnly:
            title
        default:
            HStack(spacing: 5) {
                icon
                title
            }
            ._markedLabel()
        }
    }
}

extension Label where Title == Text, Icon == Image {
    public init<S: StringProtocol>(_ title: S, systemImage: String) {
        let title = String(title)
        self.title = Text(title)
        self.icon = Image(systemName: systemImage)
    }
}

/// `.labelStyle`: which parts of the enclosed Labels render (an app's own
/// `LabelStyle` makes the whole label).
struct LabelStyleOption: Equatable, CustomStringConvertible {
    enum Kind: Equatable { case automatic, iconOnly, titleOnly, titleAndIcon, custom }
    let kind: Kind
    var custom: (@MainActor (AnyView, AnyView) -> AnyView)? = nil
    var customType: ObjectIdentifier? = nil

    static let automatic = LabelStyleOption(kind: .automatic)
    static let iconOnly = LabelStyleOption(kind: .iconOnly)
    static let titleOnly = LabelStyleOption(kind: .titleOnly)
    static let titleAndIcon = LabelStyleOption(kind: .titleAndIcon)

    static func == (a: LabelStyleOption, b: LabelStyleOption) -> Bool { a.kind == b.kind && a.customType == b.customType }
    var description: String { customType.map { "custom\($0.hashValue)" } ?? "\(kind)" }
}

/// How a label is drawn: Apple's protocol. Isomer's own four styles pick
/// the label's parts; an app's style makes the label from its title and
/// icon.
@MainActor @preconcurrency
public protocol LabelStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = LabelStyleConfiguration
}

/// A label's parts, as a `LabelStyle` gets them.
public struct LabelStyleConfiguration {
    public struct Title: View {
        let content: AnyView
        public typealias Body = Never
    }

    public struct Icon: View {
        let content: AnyView
        public typealias Body = Never
    }

    public var title: LabelStyleConfiguration.Title { Title(content: titleView) }
    public var icon: LabelStyleConfiguration.Icon { Icon(content: iconView) }
    let titleView: AnyView
    let iconView: AnyView
}

extension LabelStyleConfiguration.Title: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode { content.makeNode(&ctx) }
}

extension LabelStyleConfiguration.Icon: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode { content.makeNode(&ctx) }
}

/// The four styles Isomer draws itself.
protocol _BuiltInLabelStyle {
    var _option: LabelStyleOption { get }
}

public struct DefaultLabelStyle: LabelStyle, _BuiltInLabelStyle {
    nonisolated public init() {}
    nonisolated public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon; configuration.title }
    }
    var _option: LabelStyleOption { .automatic }
}

public struct IconOnlyLabelStyle: LabelStyle, _BuiltInLabelStyle {
    nonisolated public init() {}
    nonisolated public func makeBody(configuration: Configuration) -> some View { configuration.icon }
    var _option: LabelStyleOption { .iconOnly }
}

public struct TitleOnlyLabelStyle: LabelStyle, _BuiltInLabelStyle {
    nonisolated public init() {}
    nonisolated public func makeBody(configuration: Configuration) -> some View { configuration.title }
    var _option: LabelStyleOption { .titleOnly }
}

public struct TitleAndIconLabelStyle: LabelStyle, _BuiltInLabelStyle {
    nonisolated public init() {}
    nonisolated public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon; configuration.title }
    }
    var _option: LabelStyleOption { .titleAndIcon }
}

extension LabelStyle where Self == DefaultLabelStyle {
    public static var automatic: DefaultLabelStyle { DefaultLabelStyle() }
}

extension LabelStyle where Self == IconOnlyLabelStyle {
    nonisolated public static var iconOnly: IconOnlyLabelStyle { IconOnlyLabelStyle() }
}

extension LabelStyle where Self == TitleOnlyLabelStyle {
    nonisolated public static var titleOnly: TitleOnlyLabelStyle { TitleOnlyLabelStyle() }
}

extension LabelStyle where Self == TitleAndIconLabelStyle {
    nonisolated public static var titleAndIcon: TitleAndIconLabelStyle { TitleAndIconLabelStyle() }
}

extension View {
    /// The stack a Label builds, marked as one (param "label") for hosts
    /// that make the system's Label from its icon and title.
    nonisolated func _markedLabel() -> some View {
        _ModifiedView(child: self, descend: "label", pure: true) { inner, _ in
            inner.isLabel = true
            return inner
        }
    }

    nonisolated public func labelStyle<S: LabelStyle>(_ style: S) -> some View {
        let option = (style as? _BuiltInLabelStyle)?._option ?? LabelStyleOption(
            kind: .custom,
            custom: { title, icon in
                AnyView(style.makeBody(configuration: LabelStyleConfiguration(titleView: title, iconView: icon)))
            },
            customType: ObjectIdentifier(S.self))
        return _StackScopedView(content: self, keyPath: \.labelStyleStack, value: option)
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension Label: View {}
