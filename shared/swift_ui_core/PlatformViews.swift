
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

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension DatePicker where Label == Text {
    /// The host shows a native date input (`<input type=date>` on web, a
    /// date picker on Android); the components are the date's.
    public init<S: StringProtocol>(_ title: S, selection: Binding<Date>, displayedComponents: DatePicker<Label>.Components = [.hourAndMinute, .date]) {
        self.titleKey = String(title)
        self.selection = selection
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
        let spec = HostViewSpec(
            id: ctx.path,
            kind: "datepicker",
            params: ["title": titleKey, "labelsHidden": ctx.env.labelsHidden ? "1" : ""],
            value: isoDate(fromEpochSeconds: binding.wrappedValue.timeIntervalSince1970),
            options: [],
            onChange: { iso in
                if let seconds = epochSeconds(fromISO: iso) {
                    binding.wrappedValue = Date(timeIntervalSince1970: seconds)
                }
            }
        )
        let node = RenderNode(kind: .hostView(spec))
        node.identityPath = ctx.path
        return node
    }
}

// Minimal yyyy-MM-dd <-> epoch-seconds conversion (UTC, date-only), no
// Foundation. Good enough for a date picker demo.
private let daysInMonth = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

private func isLeap(_ year: Int) -> Bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

func isoDate(fromEpochSeconds seconds: Double) -> String {
    var days = Int(seconds / 86400)
    var year = 1970
    while true {
        let yearDays = isLeap(year) ? 366 : 365
        if days >= yearDays {
            days -= yearDays
            year += 1
        } else {
            break
        }
    }
    var month = 0
    while month < 12 {
        var dim = daysInMonth[month]
        if month == 1 && isLeap(year) { dim = 29 }
        if days >= dim {
            days -= dim
            month += 1
        } else {
            break
        }
    }
    let m = month + 1
    let d = days + 1
    func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
    return "\(year)-\(pad(m))-\(pad(d))"
}

func epochSeconds(fromISO iso: String) -> Double? {
    let parts = iso.split(separator: "-")
    guard parts.count == 3,
          let year = Int(parts[0]),
          let month = Int(parts[1]),
          let day = Int(parts[2]) else { return nil }
    var days = 0
    for y in 1970 ..< year {
        days += isLeap(y) ? 366 : 365
    }
    for m in 0 ..< (month - 1) {
        var dim = daysInMonth[m]
        if m == 1 && isLeap(year) { dim = 29 }
        days += dim
    }
    days += day - 1
    return Double(days) * 86400
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension Picker: View {}
extension _PickerStyleView: View {}
extension _TaggedView: View {}
extension DatePicker: View {}
