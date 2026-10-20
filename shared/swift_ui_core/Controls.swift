/// Button roles: `.destructive` tints the label red; `.confirm` (iOS 26)
/// renders prominent when the button is a `.confirmationAction` bar item.
public struct ButtonRole: Sendable, Equatable {
    enum Kind: Hashable, Sendable { case destructive, cancel, confirm, close }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    public static let destructive = ButtonRole(.destructive)
    public static let cancel = ButtonRole(.cancel)
    public static let confirm = ButtonRole(.confirm)
    public static let close = ButtonRole(.close)

    /// Its name on the wire (a node's `role` param, a menu's `roles`):
    /// "destructive", "cancel", "confirm" or "close", what the hosts read.
    var wireName: String {
        switch kind {
        case .destructive: "destructive"
        case .cancel: "cancel"
        case .confirm: "confirm"
        case .close: "close"
        }
    }
}


public struct Button<Label: View> {
    let action: () -> Void
    let label: Label
    let role: ButtonRole?

    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
        self.role = nil
    }

    public init(role: ButtonRole?, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
        self.role = role
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension Button where Label == Text {
    public init<S: StringProtocol>(_ title: S, action: @escaping () -> Void) {
        let title = String(title)
        self.init(action: action) { Text(title) }
    }

    public init<S: StringProtocol>(_ title: S, role: ButtonRole?, action: @escaping () -> Void) {
        let title = String(title)
        self.init(role: role, action: action) { Text(title) }
    }
}

// `SwiftUI.Label`, as Apple's interface spells it: inside `Button` the name
// is its generic parameter. (The cores built under another module name on
// Apple platforms alias `SwiftUI` to themselves.)
extension Button where Label == SwiftUI.Label<Text, Image> {
    public init<S: StringProtocol>(_ title: S, systemImage: String, action: @escaping () -> Void) {
        let title = String(title)
        self.init(action: action) { SwiftUI.Label(title, systemImage: systemImage) }
    }

    public init<S: StringProtocol>(_ title: S, systemImage: String, role: ButtonRole?, action: @escaping () -> Void) {
        let title = String(title)
        self.init(role: role, action: action) { SwiftUI.Label(title, systemImage: systemImage) }
    }
}

extension Button: _AnyButton {
    var _action: () -> Void { action }
    var _labelView: any View { label }
    var _role: ButtonRole? { role }
}

extension Button: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let style = Runtime.shared.buttonStyleStack.last ?? .automatic
        let size = Runtime.shared.controlSizeStack.last ?? .regular
        let shape = Runtime.shared.buttonBorderShapeStack.last ?? .automatic
        let tint: Color = role == .destructive ? .red : (ctx.env.tint ?? .accentColor)
        var sub = ctx.descend("button")
        // `.plain` keeps the label's own colour (SwiftUI's plain buttons
        // inherit `.primary`); the other styles tint it.
        sub.env.foregroundColor = style.prominent ? .white : (style.name == "plain" && role != .destructive ? ctx.env.foregroundColor : tint)
        // Disabled, a tinted label goes grey rather than a faded tint (with
        // `.disabled`'s dimming, the tertiary label colour iOS draws it in).
        if !ctx.env.isEnabled && !style.prominent && style.name != "plain" { sub.env.foregroundColor = .secondary }
        if let font = size.font { sub.env.font = font }
        if let custom = style.custom {
            // An app's style makes the button from its label.
            let enabled = ctx.env.isEnabled
            let made = custom(AnyView(label), role, enabled ? action : {})
            let child = buildNode(view: made, ctx: &sub)
            let node = RenderNode.box(child: child)
            if !style.customTriggers {
                node.tapAction = enabled ? action : {}
                node.buttonDisabled = !enabled
                node.buttonRole = role
            }
            return node
        }
        let child = buildNode(view: label, ctx: &sub)
        let node = RenderNode.box(child: child)
        // Disabled (`.disabled(true)` around it), a press does nothing; it is
        // still a button, and says it is disabled (param "disabled").
        node.tapAction = ctx.env.isEnabled ? action : {}
        node.buttonDisabled = !ctx.env.isEnabled
        node.pressFeedback = .ripple
        node.buttonRole = role
        node.buttonStyleName = style.name
        if size != .regular { node.buttonControlSize = size.name }
        if shape != .automatic { node.buttonBorderShape = shape.wireName }
        if let tint = ctx.env.tint { node.tint = tint }
        // Bordered families draw a capsule/rounded fill sized by the
        // control size; plain/borderless/automatic keep the bare label —
        // identical on every renderer since the fill is part of the tree.
        if style.bordered {
            node.padding = size.buttonPadding
            node.background = [RenderNode(kind: .shape(
                .rectangle,
                fill: style.prominent ? tint : tint.opacity(style.glassy ? 0.12 : 0.15),
                stroke: nil))]
            node.cornerRadius = shape.cornerRadius(for: size)
        }
        return node
    }
}

/// The button style in effect. The bordered family (`.bordered`,
/// `.borderedProminent`, `.glass`, `.glassProminent` — the iOS 26 glass
/// styles render as their bordered counterparts) draws a tinted fill;
/// `.plain`, `.borderless` and `.automatic` are the bare accent-colored
/// label. An app's own style makes the button from its label.
struct ButtonStyleOption: Equatable {
    let name: String
    /// An app's style: the button made from (label, role, action).
    var custom: (@MainActor (AnyView, ButtonRole?, @escaping () -> Void) -> AnyView)? = nil
    /// A `PrimitiveButtonStyle` of the app's: it decides when the action
    /// runs (the button itself takes no tap).
    var customTriggers = false
    var customType: ObjectIdentifier? = nil

    static let automatic = ButtonStyleOption(name: "automatic")
    static let plain = ButtonStyleOption(name: "plain")
    static let borderless = ButtonStyleOption(name: "borderless")
    static let bordered = ButtonStyleOption(name: "bordered")
    static let borderedProminent = ButtonStyleOption(name: "borderedProminent")
    static let glass = ButtonStyleOption(name: "glass")
    static let glassProminent = ButtonStyleOption(name: "glassProminent")

    var bordered: Bool { name == "bordered" || name == "borderedProminent" || glassy }
    var prominent: Bool { name == "borderedProminent" || name == "glassProminent" }
    var glassy: Bool { name == "glass" || name == "glassProminent" }

    static func == (a: ButtonStyleOption, b: ButtonStyleOption) -> Bool { a.name == b.name && a.customType == b.customType }
}

/// A button's look and its interaction: Apple's protocol. Isomer draws its
/// own styles itself; an app's makes the button, calling `trigger()` when
/// it should act.
@MainActor @preconcurrency
public protocol PrimitiveButtonStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = PrimitiveButtonStyleConfiguration
}

/// A button's look: Apple's protocol. An app's style makes the button's
/// appearance from its label; the button keeps the tap.
@MainActor @preconcurrency
public protocol ButtonStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = ButtonStyleConfiguration
}

public struct ButtonStyleConfiguration {
    public struct Label: View {
        let content: AnyView
        public typealias Body = Never
    }

    public let label: ButtonStyleConfiguration.Label
    /// Pressed state is the host's (its own press feedback); a style sees
    /// the button at rest.
    public let isPressed: Bool
    public let role: ButtonRole?
}

public struct PrimitiveButtonStyleConfiguration {
    public struct Label: View {
        let content: AnyView
        public typealias Body = Never
    }

    public let label: PrimitiveButtonStyleConfiguration.Label
    public let role: ButtonRole?
    let action: () -> Void

    /// Runs the button's action.
    public func trigger() { action() }
}

extension ButtonStyleConfiguration.Label: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode { content.makeNode(&ctx) }
}

extension PrimitiveButtonStyleConfiguration.Label: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode { content.makeNode(&ctx) }
}

/// The styles Isomer draws itself, by name.
protocol _BuiltInButtonStyle {
    var _option: ButtonStyleOption { get }
}

public struct DefaultButtonStyle: PrimitiveButtonStyle, _BuiltInButtonStyle {
    nonisolated public init() {}
    nonisolated public func makeBody(configuration: Configuration) -> some View { configuration.label }
    var _option: ButtonStyleOption { .automatic }
}

public struct PlainButtonStyle: PrimitiveButtonStyle, _BuiltInButtonStyle {
    nonisolated public init() {}
    nonisolated public func makeBody(configuration: Configuration) -> some View { configuration.label }
    var _option: ButtonStyleOption { .plain }
}

public struct BorderlessButtonStyle: PrimitiveButtonStyle, _BuiltInButtonStyle {
    nonisolated public init() {}
    nonisolated public func makeBody(configuration: Configuration) -> some View { configuration.label }
    var _option: ButtonStyleOption { .borderless }
}

public struct BorderedButtonStyle: PrimitiveButtonStyle, _BuiltInButtonStyle {
    nonisolated public init() {}
    nonisolated public func makeBody(configuration: Configuration) -> some View { configuration.label }
    var _option: ButtonStyleOption { .bordered }
}

public struct BorderedProminentButtonStyle: PrimitiveButtonStyle, _BuiltInButtonStyle {
    nonisolated public init() {}
    nonisolated public func makeBody(configuration: Configuration) -> some View { configuration.label }
    var _option: ButtonStyleOption { .borderedProminent }
}

public struct GlassButtonStyle: PrimitiveButtonStyle, _BuiltInButtonStyle {
    nonisolated public init() {}
    nonisolated public init(_ glass: Glass) {}
    nonisolated public func makeBody(configuration: Configuration) -> some View { configuration.label }
    var _option: ButtonStyleOption { .glass }
}

public struct GlassProminentButtonStyle: PrimitiveButtonStyle, _BuiltInButtonStyle {
    nonisolated public init() {}
    nonisolated public func makeBody(configuration: Configuration) -> some View { configuration.label }
    var _option: ButtonStyleOption { .glassProminent }
}

extension PrimitiveButtonStyle where Self == DefaultButtonStyle {
    nonisolated public static var automatic: DefaultButtonStyle { DefaultButtonStyle() }
}

extension PrimitiveButtonStyle where Self == PlainButtonStyle {
    public static var plain: PlainButtonStyle { PlainButtonStyle() }
}

extension PrimitiveButtonStyle where Self == BorderlessButtonStyle {
    nonisolated public static var borderless: BorderlessButtonStyle { BorderlessButtonStyle() }
}

extension PrimitiveButtonStyle where Self == BorderedButtonStyle {
    nonisolated public static var bordered: BorderedButtonStyle { BorderedButtonStyle() }
}

extension PrimitiveButtonStyle where Self == BorderedProminentButtonStyle {
    nonisolated public static var borderedProminent: BorderedProminentButtonStyle { BorderedProminentButtonStyle() }
}

extension PrimitiveButtonStyle where Self == GlassButtonStyle {
    nonisolated public static var glass: GlassButtonStyle { GlassButtonStyle() }
    nonisolated public static func glass(_ glass: Glass) -> Self { GlassButtonStyle(glass) }
}

extension PrimitiveButtonStyle where Self == GlassProminentButtonStyle {
    public static var glassProminent: GlassProminentButtonStyle { GlassProminentButtonStyle() }
}

extension View {
    /// Style for every Button in the subtree (innermost wins).
    nonisolated public func buttonStyle<S: PrimitiveButtonStyle>(_ style: S) -> some View {
        let option = (style as? _BuiltInButtonStyle)?._option ?? ButtonStyleOption(
            name: "plain",
            custom: { label, role, action in
                AnyView(style.makeBody(configuration: PrimitiveButtonStyleConfiguration(
                    label: .init(content: label), role: role, action: action)))
            },
            customTriggers: true,
            customType: ObjectIdentifier(S.self))
        return _StackScopedView(content: self, keyPath: \.buttonStyleStack, value: option)
    }

    /// An app's `ButtonStyle` for every Button in the subtree.
    nonisolated public func buttonStyle<S: ButtonStyle>(_ style: S) -> some View {
        let option = ButtonStyleOption(
            name: "plain",
            custom: { label, role, _ in
                AnyView(style.makeBody(configuration: ButtonStyleConfiguration(
                    label: .init(content: label), isPressed: false, role: role)))
            },
            customTriggers: false,
            customType: ObjectIdentifier(S.self))
        return _StackScopedView(content: self, keyPath: \.buttonStyleStack, value: option)
    }

    /// `.controlSize`: scales bordered buttons' padding and label font.
    nonisolated public func controlSize(_ size: ControlSize) -> some View {
        _StackScopedView(content: self, keyPath: \.controlSizeStack, value: size)
    }

    /// `.buttonBorderShape`: corner treatment of bordered buttons.
    nonisolated public func buttonBorderShape(_ shape: ButtonBorderShape) -> some View {
        _StackScopedView(content: self, keyPath: \.buttonBorderShapeStack, value: shape)
    }
}

public enum ControlSize: Sendable, Equatable, CaseIterable {
    case mini
    case small
    case regular
    case large
    case extraLarge

    /// The case's name, for the host ("small"): a description made by
    /// reflection, each build of a control.
    var name: String {
        switch self {
        case .mini: return "mini"
        case .small: return "small"
        case .regular: return "regular"
        case .large: return "large"
        case .extraLarge: return "extraLarge"
        }
    }

    var font: Font? {
        switch self {
        case .mini: return .caption2
        case .small: return .footnote
        case .regular: return nil
        case .large: return .headline
        case .extraLarge: return .title3
        }
    }

    var buttonPadding: EdgeInsets {
        switch self {
        case .mini: return EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)
        case .small: return EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        case .regular: return EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
        case .large: return EdgeInsets(top: 11, leading: 20, bottom: 11, trailing: 20)
        case .extraLarge: return EdgeInsets(top: 14, leading: 26, bottom: 14, trailing: 26)
        }
    }
}

public struct ButtonBorderShape: Sendable, Equatable {
    enum Kind: Equatable { case automatic, capsule, circle, roundedRectangle }
    let kind: Kind
    let radius: CGFloat?

    public static let automatic = ButtonBorderShape(kind: .automatic, radius: nil)
    public static let capsule = ButtonBorderShape(kind: .capsule, radius: nil)
    public static let circle = ButtonBorderShape(kind: .circle, radius: nil)
    public static let roundedRectangle = ButtonBorderShape(kind: .roundedRectangle, radius: nil)
    public static func roundedRectangle(radius: CGFloat) -> ButtonBorderShape {
        ButtonBorderShape(kind: .roundedRectangle, radius: radius)
    }

    /// On the wire: "capsule", "circle", "roundedRectangle" or
    /// "roundedRectangle:<radius>".
    var wireName: String {
        switch kind {
        case .automatic: return "automatic"
        case .capsule: return "capsule"
        case .circle: return "circle"
        case .roundedRectangle: return radius.map { "roundedRectangle:\(Int($0))" } ?? "roundedRectangle"
        }
    }

    func cornerRadius(for size: ControlSize) -> CGFloat {
        switch kind {
        case .capsule, .circle: return 9999
        case .roundedRectangle: return radius ?? 8
        case .automatic: return size == .large || size == .extraLarge ? 12 : 8
        }
    }
}

/// Pushes `value` onto a Runtime stack for the duration of the subtree's
/// build (the pattern behind `.tabViewStyle`, `.pickerStyle`, …).
struct _StackScopedView<Content: View, Value> {
    let content: Content
    let keyPath: ReferenceWritableKeyPath<Runtime, [Value]>
    let value: Value

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _StackScopedView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        Runtime.shared[keyPath: keyPath].append(value)
        defer { Runtime.shared[keyPath: keyPath].removeLast() }
        var sub = ctx.descend("scoped")
        return buildNode(view: content, ctx: &sub)
    }
}

public struct Toggle<Label: View> {
    let isOn: Binding<Bool>
    let label: Label

    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self.isOn = isOn
        self.label = label()
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension Toggle where Label == Text {
    public init<S: StringProtocol>(_ title: S, isOn: Binding<Bool>) {
        let title = String(title)
        self.init(isOn: isOn) { Text(title) }
    }
}

extension Toggle: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var sub = ctx.descend("toggle")
        let labelNode = buildNode(view: label, ctx: &sub)

        // Canonical semantic node: component systems render the platform's
        // real switch; the self-drawing path swaps in the drawn switch via
        // chrome expansion (ChromeExpansion.swift).
        let binding = isOn
        let spec = HostViewSpec(
            id: ctx.path, kind: "toggle", params: [:],
            value: binding.wrappedValue ? "1" : "0", options: [],
            onChange: { binding.wrappedValue = $0 == "1" })
        let toggle = RenderNode(kind: .hostView(spec))
        toggle.identityPath = ctx.path
        // Label leading, switch trailing (the row fills its width, as in
        // SwiftUI); a spacer between keeps the switch at the trailing edge.
        let row = RenderNode(kind: .stack(.horizontal))
        row.stackAlignment = .center
        row.stackSpacing = 10
        row.expandsWidth = true
        let gap = RenderNode(kind: .spacer(nil))
        row.children = [labelNode, gap, toggle]
        return row
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension Button: View {}
extension _StackScopedView: View {}
extension Toggle: View {}
