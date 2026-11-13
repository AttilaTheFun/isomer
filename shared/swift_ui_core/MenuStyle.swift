// `MenuStyle`: how a Menu's button looks, as Apple's. The built-in styles
// travel to the host by name (param "menuStyle": "button" a bordered
// button, as SwiftUI draws `.menuStyle(.button)`; "borderlessButton" its
// label alone); an app's own style is drawn as the host draws a menu.

/// How a menu's button looks: Apple's protocol.
@MainActor @preconcurrency
public protocol MenuStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = MenuStyleConfiguration
}

/// What a `MenuStyle` makes a menu from: its label and its content.
public struct MenuStyleConfiguration {
    /// The menu's label, as the Menu was given it.
    @MainActor @preconcurrency
    public struct Label: View {
        let content: AnyView
        public typealias Body = Never
    }

    /// The menu's content, its items.
    @MainActor @preconcurrency
    public struct Content: View {
        let content: AnyView
        public typealias Body = Never
    }

    let label: Label
    let content: Content
}

extension MenuStyleConfiguration.Label: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode { content.makeNode(&ctx) }
}

extension MenuStyleConfiguration.Content: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode { content.makeNode(&ctx) }
}

/// The built-in styles, by the name the host knows them by.
protocol _BuiltInMenuStyle {
    var _menuStyleName: String { get }
}

/// The platform's menu.
public struct DefaultMenuStyle: MenuStyle, _BuiltInMenuStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
    var _menuStyleName: String { "automatic" }
}

/// A menu drawn as a bordered button, its label inside.
public struct ButtonMenuStyle: MenuStyle, _BuiltInMenuStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
    var _menuStyleName: String { "button" }
}

/// A menu drawn as its label alone.
public struct BorderlessButtonMenuStyle: MenuStyle, _BuiltInMenuStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { configuration.label }
    var _menuStyleName: String { "borderlessButton" }
}

extension MenuStyle where Self == DefaultMenuStyle {
    public static var automatic: DefaultMenuStyle { DefaultMenuStyle() }
}

extension MenuStyle where Self == ButtonMenuStyle {
    public static var button: ButtonMenuStyle { ButtonMenuStyle() }
}

extension MenuStyle where Self == BorderlessButtonMenuStyle {
    public static var borderlessButton: BorderlessButtonMenuStyle { BorderlessButtonMenuStyle() }
}

/// The menu style in effect, by name ("automatic" for an app's own).
struct _MenuStyleKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension View {
    /// The style of the menus inside.
    nonisolated public func menuStyle<S>(_ style: S) -> some View where S: MenuStyle {
        let name = (style as? _BuiltInMenuStyle)?._menuStyleName ?? "automatic"
        return _EnvironmentModifier(child: self, descend: "menustyle") { env in env[_MenuStyleKey.self] = name }
    }
}
