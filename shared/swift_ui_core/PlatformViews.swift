
// Bridging platform-native components into the view hierarchy.
//
// Host views: native widgets the host materializes over the canvas, keyed by
// structural identity, by a `kind` the host understands, with parameters and
// a value, and a callback when the user changes them (a real DOM element on
// the web, an Android View). Picker and DatePicker are built-in consumers
// backed by `<select>` and `<input type=date>` on web and the native
// equivalents on Android; the Isomer module's `PlatformViewRepresentable`
// (the cross-platform analogue of UIViewRepresentable) is an app's. On Apple
// the real SwiftUI types are used instead.

import Foundation

func hostViewIntrinsicSize(_ spec: HostViewSpec) -> CGSize {
    switch spec.kind {
    case "datepicker":
        return CGSize(width: 160, height: 34)
    case "picker":
        return CGSize(width: 200, height: 34)
    case "menu":
        return CGSize(width: 120, height: 34)
    case "webview", "metal":
        return CGSize(width: 320, height: 240)
    case "video":
        return CGSize(width: 320, height: 200)
    case "image":
        return CGSize(width: 120, height: 120)
    case "navbar":
        return CGSize(width: 320, height: 44)
    case "tabbar":
        return CGSize(width: 320, height: 56)
    default:
        return CGSize(width: 200, height: 34)
    }
}

// MARK: - Host views

/// A native widget the host materializes by `kind`, keyed where it stands:
/// the node the Isomer module's representables build (their protocol,
/// `PlatformViewRepresentable`, is the Isomer module's, not Apple's).
/// Under a self-drawing renderer, embedded platform surfaces (WebView,
/// VideoPlayer) become drawn placeholders, the GPU layer cannot rasterize
/// their contents, while app-authored representables remain the native
/// escape hatch.
package func hostViewNode(
    kind: String, parameters: [String: String], value: String, options: [String] = [],
    onChange: @escaping (String) -> Void, ctx: inout BuildContext
) -> RenderNode {
    let spec = HostViewSpec(
        id: ctx.path,
        kind: kind,
        params: parameters,
        value: value,
        options: options,
        onChange: onChange
    )
    let node = RenderNode(kind: .hostView(spec))
    node.identityPath = ctx.path
    // A Metal view or a map takes the space it is offered, both ways, as an
    // MTKView and SwiftUI's Map do (under a component renderer a layer that
    // only hugs its content left the element 0×0).
    if kind == "metal" || kind == "map" {
        node.expandsWidth = true
        node.expandsHeight = true
    }
    return node
}

/// A host view as a view: the Isomer module's representables are one.
package struct HostViewPrimitive {
    let kind: String
    let parameters: [String: String]
    let value: String
    let onChange: (String) -> Void

    package init(kind: String, parameters: [String: String], value: String, onChange: @escaping (String) -> Void) {
        self.kind = kind
        self.parameters = parameters
        self.value = value
        self.onChange = onChange
    }
}

extension HostViewPrimitive: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        hostViewNode(kind: kind, parameters: parameters, value: value, onChange: onChange, ctx: &ctx)
    }
}

extension HostViewPrimitive: View {}

// The per-platform refinements (WasmViewRepresentable,
// AndroidViewRepresentable, WindowsViewRepresentable, LinuxViewRepresentable)
// and NativeSlider are the Isomer module's
// (shared/swift_ui_extensions/PlatformViews.swift).

// MARK: - Picker

public struct Picker<SelectionValue: Hashable, Content: View> {
    let titleKey: String
    let selection: Binding<SelectionValue>
    let content: Content

    public init<S: StringProtocol>(
        _ titleKey: S,
        selection: Binding<SelectionValue>,
        @ViewBuilder content: () -> Content
    ) {
        let titleKey = String(titleKey)
        self.titleKey = titleKey
        self.selection = selection
        self.content = content()
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension Picker: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        // Collect the tagged options from the content.
        var tags: [(key: String, label: String, value: SelectionValue)] = []
        collectPickerOptions(content, ctx: &ctx, into: &tags)

        let selectedKey = "\(selection.wrappedValue)"
        let selectedIndex = tags.firstIndex { $0.key == selectedKey } ?? 0

        let binding = selection
        let captured = tags
        // Canonical semantic node; the self-drawing path swaps in
        // DrawnPopUpList via chrome expansion.
        let spec = HostViewSpec(
            id: ctx.path,
            kind: "picker",
            params: ["title": titleKey, "style": Runtime.shared.pickerStyleStack.last ?? "",
                     "labelsHidden": ctx.env.labelsHidden ? "1" : "", "formRow": ctx.env.formRow ? "1" : ""],
            value: String(selectedIndex),
            options: tags.map { $0.label },
            onChange: { newValue in
                if let index = Int(newValue), index >= 0, index < captured.count {
                    binding.wrappedValue = captured[index].value
                }
            }
        )
        let node = RenderNode(kind: .hostView(spec))
        node.identityPath = ctx.path
        return node
    }
}

/// `.pickerStyle`: `.segmented` renders a segmented control on hosts that
/// have one (web react — inline and in toolbar items); other styles are
/// advisory and keep the host's pop-up list.
public protocol PickerStyle {
}

public struct DefaultPickerStyle: PickerStyle, NamedStyle {
    nonisolated public init() {}
    var styleName: String { "" }
}

public struct MenuPickerStyle: PickerStyle, NamedStyle {
    nonisolated public init() {}
    var styleName: String { "menu" }
}

public struct SegmentedPickerStyle: PickerStyle, NamedStyle {
    nonisolated public init() {}
    var styleName: String { "segmented" }
}

public struct InlinePickerStyle: PickerStyle, NamedStyle {
    nonisolated public init() {}
    var styleName: String { "inline" }
}

public struct WheelPickerStyle: PickerStyle, NamedStyle {
    nonisolated public init() {}
    var styleName: String { "wheel" }
}

public struct NavigationLinkPickerStyle: PickerStyle, NamedStyle {
    nonisolated public init() {}
    var styleName: String { "navigationLink" }
}

public struct PalettePickerStyle: PickerStyle, NamedStyle {
    nonisolated public init() {}
    var styleName: String { "palette" }
}

extension PickerStyle where Self == DefaultPickerStyle {
    nonisolated public static var automatic: DefaultPickerStyle { DefaultPickerStyle() }
}

extension PickerStyle where Self == MenuPickerStyle {
    nonisolated public static var menu: MenuPickerStyle { MenuPickerStyle() }
}

extension PickerStyle where Self == SegmentedPickerStyle {
    nonisolated public static var segmented: SegmentedPickerStyle { SegmentedPickerStyle() }
}

extension PickerStyle where Self == InlinePickerStyle {
    nonisolated public static var inline: InlinePickerStyle { InlinePickerStyle() }
}

extension PickerStyle where Self == WheelPickerStyle {
    nonisolated public static var wheel: WheelPickerStyle { WheelPickerStyle() }
}

extension PickerStyle where Self == NavigationLinkPickerStyle {
    nonisolated public static var navigationLink: NavigationLinkPickerStyle { NavigationLinkPickerStyle() }
}

extension PickerStyle where Self == PalettePickerStyle {
    nonisolated public static var palette: PalettePickerStyle { PalettePickerStyle() }
}

extension View {
    nonisolated public func pickerStyle<S: PickerStyle>(_ style: S) -> some View {
        _PickerStyleView(content: self, style: styleName(style, otherwise: ""))
    }

    /// `.labelsHidden()`: controls leave out their own label (param
    /// "labelsHidden" for hosts whose controls show one, as a Picker in a
    /// Form does).
    nonisolated public func labelsHidden() -> some View {
        _EnvironmentModifier(child: self, descend: "nolabels") { env in env.labelsHidden = true }
    }
}

struct _PickerStyleView<Content: View> {
    let content: Content
    let style: String

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _PickerStyleView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        Runtime.shared.pickerStyleStack.append(style)
        defer { Runtime.shared.pickerStyleStack.removeLast() }
        var sub = ctx.descend("pickerstyle")
        return buildNode(view: content, ctx: &sub)
    }
}

/// Walks a Picker's content, pulling out each tagged row's (tag, label).
@MainActor
private func collectPickerOptions<SelectionValue: Hashable>(
    _ view: any View,
    ctx: inout BuildContext,
    into tags: inout [(key: String, label: String, value: SelectionValue)]
) {
    if let tagged = view as? _AnyTaggedView {
        if let value = tagged.tagValue as? SelectionValue {
            tags.append((
                key: "\(tagged.tagValue)",
                label: firstText(of: tagged.content, ctx: &ctx),
                value: value
            ))
        }
        return
    }
    if let multi = view as? _MultiView {
        for entry in multi.childViews() {
            var sub = ctx.descend(entry.suffix)
            collectPickerOptions(entry.view, ctx: &sub, into: &tags)
        }
        return
    }
    // A non-tagged view (e.g. a plain Text in a ForEach over Hashable data):
    // use its rendered text as both label and tag.
    let label = firstText(of: view, ctx: &ctx)
    if let value = label as? SelectionValue {
        tags.append((key: label, label: label, value: value))
    }
}

/// Renders a view to a node and returns the first text run it contains.
@MainActor
private func firstText(of view: any View, ctx: inout BuildContext) -> String {
    var sub = ctx.descend("opt")
    let node = buildNode(view: view, ctx: &sub)
    return firstTextNode(node) ?? ""
}

private func firstTextNode(_ node: RenderNode) -> String? {
    if case .text(let string) = node.kind {
        return string
    }
    for child in node.children {
        if let found = firstTextNode(child) {
            return found
        }
    }
    return nil
}

// MARK: - tag()

protocol _AnyTaggedView {
    var tagValue: AnyHashable { get }
    var content: any View { get }
}

struct _TaggedView<V: Hashable, Content: View>: _AnyTaggedView {
    let value: V
    let inner: Content

    var tagValue: AnyHashable { AnyHashable(value) }
    var content: any View { inner }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension _TaggedView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var sub = ctx.descend("tagged")
        return buildNode(view: inner, ctx: &sub)
    }
}

extension View {
    nonisolated public func tag<V: Hashable>(_ tag: V, includeOptional: Bool = true) -> some View {
        _TaggedView(value: tag, inner: self)
    }
}

// MARK: - DatePicker

public struct DatePicker<Label: View> {
    let titleKey: String
    let selection: Binding<Date>
    var components: DatePickerComponents = [.hourAndMinute, .date]

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension DatePicker where Label == Text {
    /// The host shows its own date and time inputs (`<input type=date>`
    /// and `type=time` on the web, Material's pickers on Android), for the
    /// components asked for.
    public init<S: StringProtocol>(_ title: S, selection: Binding<Date>, displayedComponents: DatePicker<Label>.Components = [.hourAndMinute, .date]) {
        self.titleKey = String(title)
        self.selection = selection
        self.components = displayedComponents
    }
}

extension DatePicker {
    public typealias Components = DatePickerComponents
}

/// What a date picker shows: the date, the time.
public struct DatePickerComponents: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let hourAndMinute = DatePickerComponents(rawValue: 1 << 0)
    public static let date = DatePickerComponents(rawValue: 1 << 1)
}

extension DatePicker: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let binding = selection
        // Canonical semantic node; the self-drawing path swaps in
        // DrawnDatePicker via chrome expansion.
        // The value in the user's time zone: the date (yyyy-MM-dd) as `v`,
        // its time (HH:mm) and the components shown as params. A host sends
        // back a date (its time kept), "time:HH:mm" (its date kept), or both
        // ("yyyy-MM-ddTHH:mm"); it formats them for its locale itself.
        let local = DatePickerValue(binding.wrappedValue)
        var shown: [String] = []
        if components.contains(.date) { shown.append("date") }
        if components.contains(.hourAndMinute) { shown.append("time") }
        let spec = HostViewSpec(
            id: ctx.path,
            kind: "datepicker",
            params: [
                "title": titleKey, "labelsHidden": ctx.env.labelsHidden ? "1" : "",
                "components": shown.joined(separator: ","), "time": local.time,
            ],
            value: local.date,
            options: [],
            onChange: { value in
                if let date = DatePickerValue.date(binding.wrappedValue, changedBy: value) {
                    binding.wrappedValue = date
                }
            }
        )
        let node = RenderNode(kind: .hostView(spec))
        node.identityPath = ctx.path
        return node
    }
}

/// A date picker's value in the user's calendar and time zone: its date
/// (yyyy-MM-dd) and time (HH:mm), and a host's change applied to a date.
package struct DatePickerValue {
    package let date: String
    package let time: String

    package init(_ value: Date) {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: value)
        func pad(_ number: Int?, _ width: Int = 2) -> String {
            let text = String(number ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        date = "\(pad(parts.year, 4))-\(pad(parts.month))-\(pad(parts.day))"
        time = "\(pad(parts.hour)):\(pad(parts.minute))"
    }

    /// `value` with a host's change: "yyyy-MM-dd" (the time kept),
    /// "time:HH:mm" (the date kept) or "yyyy-MM-ddTHH:mm"; nil for neither.
    package static func date(_ value: Date, changedBy change: String) -> Date? {
        let calendar = Calendar.current
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: value)
        var datePart: Substring?
        var timePart: Substring?
        if change.hasPrefix("time:") {
            timePart = change.dropFirst(5)
        } else if let t = change.firstIndex(of: "T") {
            datePart = change[..<t]
            timePart = change[change.index(after: t)...]
        } else {
            datePart = Substring(change)
        }
        if let datePart {
            let numbers = datePart.split(separator: "-").compactMap { Int($0) }
            guard numbers.count == 3 else { return nil }
            parts.year = numbers[0]
            parts.month = numbers[1]
            parts.day = numbers[2]
        }
        if let timePart {
            let numbers = timePart.split(separator: ":").compactMap { Int($0) }
            guard numbers.count >= 2 else { return nil }
            parts.hour = numbers[0]
            parts.minute = numbers[1]
            parts.second = 0
        }
        return calendar.date(from: parts)
    }
}

// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension Picker: View {}
extension _PickerStyleView: View {}
extension _TaggedView: View {}
extension DatePicker: View {}
