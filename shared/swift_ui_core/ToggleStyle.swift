// `ToggleStyle`: how a Toggle looks and acts. Isomer draws the switch itself
// (the platform's switch under a component renderer, the drawn one on the
// GPU path); an app's own style makes the whole toggle from its label and
// binding, as SwiftUI's `makeBody(configuration:)` does. A Toggle inside a
// style's body is drawn by the style around that one (the switch, unless
// another custom style encloses it), so the common pattern, a custom style
// wrapping a plain Toggle with something beside it, draws the switch there.
//
// The style in effect is a stack scope (`Runtime.toggleStyleStack`, like
// the button and label styles'): part of what a rebuild site keeps
// (`_BuildStacks`, InPlace.swift) and of a reused subtree's context.

/// The toggle style in effect: the switch Isomer draws, or an app's style
/// (and `.button`, which is made as one is).
struct ToggleStyleOption: Equatable, CustomStringConvertible {
    let name: String
    /// An app's style: the toggle made from its configuration.
    var custom: (@MainActor (ToggleStyleConfiguration) -> AnyView)? = nil
    var customType: ObjectIdentifier? = nil

    static let automatic = ToggleStyleOption(name: "automatic")
    static let `switch` = ToggleStyleOption(name: "switch")

    static func == (a: ToggleStyleOption, b: ToggleStyleOption) -> Bool { a.name == b.name && a.customType == b.customType }
    var description: String { customType.map { "custom\($0.hashValue)" } ?? name }
}

/// A toggle's look and interaction: Apple's protocol. An app's style makes
/// the toggle from `configuration` (its label, its `isOn` binding).
@MainActor @preconcurrency
public protocol ToggleStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = ToggleStyleConfiguration
}

/// What a `ToggleStyle` makes a toggle from.
public struct ToggleStyleConfiguration {
    /// The toggle's label, as the Toggle was given it.
    public struct Label: View {
        let content: AnyView
        public typealias Body = Never
    }

    public let label: ToggleStyleConfiguration.Label
    /// Whether the toggle is on; `$isOn` is its binding.
    @Binding public var isOn: Bool
    /// Whether it stands for several values, some on and some off (a
    /// Toggle over a collection's). Isomer's Toggles are over one value.
    public var isMixed: Bool

    init(label: ToggleStyleConfiguration.Label, isOn: Binding<Bool>, isMixed: Bool = false) {
        self.label = label
        self._isOn = isOn
        self.isMixed = isMixed
    }
}

extension ToggleStyleConfiguration.Label: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode { content.makeNode(&ctx) }
}

extension Toggle where Label == ToggleStyleConfiguration.Label {
    /// A toggle from a style's configuration: inside a style's body, the
    /// toggle the style around it draws (the switch), with this label and
    /// binding.
    public init(_ configuration: ToggleStyleConfiguration) {
        self.init(isOn: configuration.$isOn) { configuration.label }
    }
}

/// The styles Isomer draws itself.
protocol _BuiltInToggleStyle {
    var _option: ToggleStyleOption { get }
}

/// The platform's toggle: the switch.
public struct DefaultToggleStyle: ToggleStyle, _BuiltInToggleStyle {
    nonisolated public init() {}
    nonisolated public func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(SwitchToggleStyle())
    }
    var _option: ToggleStyleOption { .automatic }
}

/// The switch: label leading, switch trailing.
public struct SwitchToggleStyle: ToggleStyle, _BuiltInToggleStyle {
    nonisolated public init() {}
    nonisolated public func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(SwitchToggleStyle())
    }
    var _option: ToggleStyleOption { .switch }
}

/// A button that stays pressed while on: the label, bordered, filled with
/// the tint when on (as iOS draws it).
public struct ButtonToggleStyle: ToggleStyle {
    nonisolated public init() {}
    @ViewBuilder
    nonisolated public func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.$isOn
        if isOn.wrappedValue {
            Button { isOn.wrappedValue = false } label: { configuration.label }
                .buttonStyle(BorderedProminentButtonStyle())
        } else {
            Button { isOn.wrappedValue = true } label: { configuration.label }
                .buttonStyle(BorderedButtonStyle())
        }
    }
}

extension ToggleStyle where Self == DefaultToggleStyle {
    public static var automatic: DefaultToggleStyle { DefaultToggleStyle() }
}

extension ToggleStyle where Self == SwitchToggleStyle {
    nonisolated public static var `switch`: SwitchToggleStyle { SwitchToggleStyle() }
}

extension ToggleStyle where Self == ButtonToggleStyle {
    nonisolated public static var button: ButtonToggleStyle { ButtonToggleStyle() }
}

extension View {
    /// The style of every Toggle in the subtree (innermost wins).
    nonisolated public func toggleStyle<S: ToggleStyle>(_ style: S) -> some View {
        let option = (style as? _BuiltInToggleStyle)?._option ?? ToggleStyleOption(
            name: "custom",
            custom: { configuration in AnyView(style.makeBody(configuration: configuration)) },
            customType: ObjectIdentifier(S.self))
        return _StackScopedView(content: self, keyPath: \.toggleStyleStack, value: option)
    }
}

extension Toggle {
    /// The toggle an app's style makes: its body built with the style taken
    /// off the stack, so a Toggle inside it is drawn by the style around.
    @MainActor
    func makeStyledNode(_ custom: @MainActor (ToggleStyleConfiguration) -> AnyView, ctx: inout BuildContext) -> RenderNode {
        let configuration = ToggleStyleConfiguration(label: .init(content: AnyView(label)), isOn: isOn)
        let enclosing = Runtime.shared.toggleStyleStack
        Runtime.shared.toggleStyleStack.removeLast()
        defer { Runtime.shared.toggleStyleStack = enclosing }
        let made = custom(configuration)
        var sub = ctx.descend("togglestyle")
        return buildNode(view: made, ctx: &sub)
    }
}
