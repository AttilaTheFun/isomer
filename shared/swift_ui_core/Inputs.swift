// Interactive input controls: TextField (text entry through the host's
// native input mechanism), Slider (drag), and Stepper (composite).

public struct TextField {
    let placeholder: String
    let text: Binding<String>
    let axis: Axis
    /// A `selection` binding, as UTF-16 offsets into the text (TextSelection.swift).
    var selection: FieldSelectionBinding?

    public init<S: StringProtocol>(_ placeholder: S, text: Binding<String>) {
        let placeholder = String(placeholder)
        self.placeholder = placeholder
        self.text = text
        axis = .horizontal
    }

    /// The growing-input form: `.vertical` renders a multi-line field that
    /// grows with its content, bounded by `.lineLimit(_:)` /
    /// `.lineLimit(1...6)` (mirrors `TextField(_:text:axis:)`).
    /// `prompt:` overrides the placeholder (the title is the accessibility
    /// label in SwiftUI; here the prompt's text becomes the placeholder).
    public init<S: StringProtocol>(_ title: S, text: Binding<String>, prompt: Text?) {
        let title = String(title)
        self.init(prompt?.content ?? title, text: text)
    }

    public init<S: StringProtocol>(_ placeholder: S, text: Binding<String>, axis: Axis) {
        let placeholder = String(placeholder)
        self.placeholder = placeholder
        self.text = text
        self.axis = axis
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension TextField: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let node = RenderNode(kind: .textField(placeholder: placeholder))
        node.identityPath = ctx.path
        node.font = ctx.env.font
        node.opacity = ctx.env.opacity
        // SwiftUI text fields expand to the width their container offers
        // (the classic composer `HStack { TextField; Button }` gives the
        // field all remaining space).
        node.expandsWidth = true
        node.textFieldStyle = ctx.env.textFieldStyle
        node.keyboardType = ctx.env.keyboardType
        node.autocapitalization = ctx.env.autocapitalization
        node.autocorrectionDisabled = ctx.env.autocorrectionDisabled
        if axis == .vertical {
            node.textAxis = .vertical
            node.lineRange = ctx.env.lineRange
                ?? ctx.env.lineLimit.map { 1 ... max(1, $0) }
        }
        if ctx.env.isEnabled {
            let binding = text
            node.textGet = { binding.wrappedValue }
            node.textSet = { binding.wrappedValue = $0 }
            node.textSubmit = ctx.env.onSubmit
            node.keyPress = ctx.env.keyPressHandlers.reversed()
            if let selection {
                connect(selection, to: node, at: ctx.path)
            }
        }
        return node
    }
}

/// `SecureField`: a one-line field whose text is masked (a password): the
/// host's own secure input where it has one, its characters drawn as dots
/// where the field is drawn.
public struct SecureField {
    let field: TextField

    public init<S: StringProtocol>(_ title: S, text: Binding<String>) {
        let title = String(title)
        field = TextField(title, text: text)
    }

    /// `prompt:` is the placeholder (the title is what assistive technology
    /// reads).
    public init<S: StringProtocol>(_ title: S, text: Binding<String>, prompt: Text?) {
        let title = String(title)
        field = TextField(title, text: text, prompt: prompt)
    }

    public init<Label: View>(text: Binding<String>, prompt: Text? = nil, @ViewBuilder label: () -> Label) {
        field = TextField(prompt?.content ?? _extractText(label()), text: text)
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension SecureField: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let node = field.makeNode(&ctx)
        node.secureEntry = true
        return node
    }
}

extension SecureField: View {}

/// `TextEditor(text:)`: a scrolling multi-line text view that fills the
/// space its container offers (a code editor, a notes field). Typography
/// comes from the environment font (`.font(.system(size:design:))`), the
/// keyboard/autocorrection modifiers apply as on a TextField.
public struct TextEditor {
    let text: Binding<String>

    public init(text: Binding<String>) {
        self.text = text
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension TextEditor: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let node = RenderNode(kind: .textField(placeholder: ""))
        node.identityPath = ctx.path
        node.font = ctx.env.font
        node.opacity = ctx.env.opacity
        node.expandsWidth = true
        node.expandsHeight = true
        node.textFieldStyle = "plain"
        node.keyboardType = ctx.env.keyboardType
        node.autocapitalization = ctx.env.autocapitalization
        node.autocorrectionDisabled = ctx.env.autocorrectionDisabled
        node.textAxis = .vertical
        node.textEditor = true
        if ctx.env.isEnabled {
            let binding = text
            node.textGet = { binding.wrappedValue }
            node.textSet = { binding.wrappedValue = $0 }
            node.keyPress = ctx.env.keyPressHandlers.reversed()
        }
        return node
    }
}

public struct Slider {
    let value: Binding<Double>
    let bounds: ClosedRange<Double>

    public init<V: BinaryFloatingPoint>(
        value: Binding<V>, in bounds: ClosedRange<V> = 0 ... 1, onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) where V.Stride: BinaryFloatingPoint {
        self.value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = V($0) })
        self.bounds = Double(bounds.lowerBound) ... Double(bounds.upperBound)
    }

    /// With a label, which SwiftUI reads to VoiceOver and does not draw
    /// beside a slider on a phone: the same slider here.
    public init<V: BinaryFloatingPoint, L: View>(
        value: Binding<V>, in bounds: ClosedRange<V> = 0 ... 1,
        @ViewBuilder label: () -> L, onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) where V.Stride: BinaryFloatingPoint {
        self.init(value: value, in: bounds, onEditingChanged: onEditingChanged)
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension Slider: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let node = RenderNode(kind: .slider)
        node.identityPath = ctx.path
        node.opacity = ctx.env.opacity
        let span = bounds.upperBound - bounds.lowerBound
        let fraction = span > 0 ? (value.wrappedValue - bounds.lowerBound) / span : 0
        node.sliderFraction = min(max(fraction, 0), 1)
        if ctx.env.isEnabled {
            let binding = value
            let lower = bounds.lowerBound
            node.sliderSet = { newFraction in
                binding.wrappedValue = lower + newFraction * span
            }
        }
        return node
    }
}

/// Composite control built from existing primitives.
public struct Stepper {
    let title: String
    let increment: () -> Void
    let decrement: () -> Void
    let canIncrement: Bool
    let canDecrement: Bool

    public init<S: StringProtocol, V: Strideable>(
        _ title: S,
        value: Binding<V>,
        in bounds: ClosedRange<V>,
        step: V.Stride = 1,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.title = String(title)
        increment = { value.wrappedValue = Swift.min(bounds.upperBound, value.wrappedValue.advanced(by: step)) }
        decrement = { value.wrappedValue = Swift.max(bounds.lowerBound, value.wrappedValue.advanced(by: -step)) }
        canIncrement = value.wrappedValue < bounds.upperBound
        canDecrement = value.wrappedValue > bounds.lowerBound
    }

    public var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            HStack(spacing: 1) {
                StepperButton(symbol: "−", action: decrement)
                    .opacity(canDecrement ? 1 : 0.35)
                StepperButton(symbol: "+", action: increment)
                    .opacity(canIncrement ? 1 : 0.35)
            }
            .background(Color(white: 0, opacity: 0.08))
            .cornerRadius(8)
        }
    }
}

struct StepperButton {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(symbol)
                .frame(width: 34, height: 28)
        }
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension TextField: View {}
extension TextEditor: View {}
extension Slider: View {}
extension Stepper: View {}
extension StepperButton: View {}
