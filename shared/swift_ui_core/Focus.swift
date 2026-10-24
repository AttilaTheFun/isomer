// Text-input details and scroll targeting that chat-style screens reach for:
// `@FocusState` + `.focused`, `.textInputAutocapitalization`,
// `.autocorrectionDisabled`, `.truncationMode`, and `ScrollViewReader` /
// `ScrollViewProxy.scrollTo` with `.id(_:)`. All cross the wire as params
// on the text field / text / scroll nodes; hosts that have the platform
// feature apply it (iOS: focus binding, scrollTo). `.keyboardType` only
// where UIKit is (an app compiled against Isomer's frameworks on iOS): its
// type is UIKit's (the hosts can still take a node's keyboard type).

// MARK: - FocusState

/// `@FocusState`: `Bool` (one field) or an optional `Hashable` (which of
/// several fields). Setting it focuses the matching `.focused` field; the
/// host reports the keyboard going away by clearing it.
@propertyWrapper
public struct FocusState<Value: Hashable>: _DynamicProperty {
    private var state: State<Value>

    public init() where Value == Bool {
        state = State(wrappedValue: false)
    }

    public init<T: Hashable>() where Value == T? {
        state = State(wrappedValue: nil)
    }

    public var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }

    /// Persisted across builds exactly like `@State` (same storage slot).
    func _connect(storage: StateStorage, key: String, env: EnvironmentValues) {
        state._connect(storage: storage, key: key, env: env)
    }

    public var projectedValue: FocusState<Value>.Binding {
        FocusState<Value>.Binding(get: { self.wrappedValue }, set: { self.wrappedValue = $0 })
    }

    public struct Binding {
        let get: () -> Value
        let set: (Value) -> Void
        public var wrappedValue: Value {
            get { get() }
            nonmutating set { set(newValue) }
        }
    }
}

extension View {
    /// `.focused($isFocused)`: this field's focus follows the Bool.
    nonisolated public func focused(_ binding: FocusState<Bool>.Binding) -> some View {
        _ModifiedView(child: self, descend: "focus", pure: true) { inner, _ in
            inner.focusGet = { binding.wrappedValue }
            inner.focusSet = { binding.wrappedValue = $0 }
            return inner
        }
    }

    /// `.focused($field, equals: .name)`: focused while the state equals `value`.
    nonisolated public func focused<T: Hashable>(_ binding: FocusState<T?>.Binding, equals value: T) -> some View {
        _ModifiedView(child: self, descend: "focus", pure: true) { inner, _ in
            inner.focusGet = { binding.wrappedValue == value }
            inner.focusSet = { focused in
                if focused { binding.wrappedValue = value }
                else if binding.wrappedValue == value { binding.wrappedValue = nil }
            }
            return inner
        }
    }
}

// MARK: - Keyboard

public struct TextInputAutocapitalization: Sendable {
    enum Kind: Hashable, Sendable { case never, words, sentences, characters }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }

    public static let never = TextInputAutocapitalization(Kind.never)
    public static let words = TextInputAutocapitalization(Kind.words)
    public static let sentences = TextInputAutocapitalization(Kind.sentences)
    public static let characters = TextInputAutocapitalization(Kind.characters)
}

extension View {
    nonisolated public func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some View {
        _EnvironmentModifier(child: self, descend: "autocap") { env in env.autocapitalization = autocapitalization.map { "\($0.kind)" } }
    }

    nonisolated public func autocorrectionDisabled(_ disable: Bool = true) -> some View {
        _EnvironmentModifier(child: self, descend: "autocorrect") { env in env.autocorrectionDisabled = disable }
    }
}

// MARK: - Truncation

extension Text {
    public enum TruncationMode: Hashable, Sendable { case head, tail, middle }
}

extension View {
    /// `.lineSpacing`: extra space between lines of descendant text.
    nonisolated public func lineSpacing(_ spacing: CGFloat) -> some View {
        _EnvironmentModifier(child: self, descend: "linesp") { env in env.lineSpacing = Double(spacing) }
    }

    nonisolated public func truncationMode(_ mode: Text.TruncationMode) -> some View {
        _EnvironmentModifier(child: self, descend: "trunc") { env in env.truncationMode = "\(mode)" }
    }

    /// `.menuIndicator(_:)`: whether menus below show their chevron
    /// (`.automatic` and `.visible` do).
    nonisolated public func menuIndicator(_ visibility: Visibility) -> some View {
        _EnvironmentModifier(child: self, descend: "menuind") { env in env.menuIndicatorHidden = visibility == .hidden }
    }

    /// `.minimumScaleFactor`: descendant text may shrink to this fraction
    /// of its size to fit before it wraps or truncates, where the host can.
    nonisolated public func minimumScaleFactor(_ factor: CGFloat) -> some View {
        _EnvironmentModifier(child: self, descend: "minscale") { env in env.minimumScaleFactor = Double(factor) }
    }

    /// `.textCase`: descendant text in capitals or small letters, or —
    /// `nil` — as written, where a container would otherwise case it (a
    /// list's section header on iOS is in capitals unless told).
    nonisolated public func textCase(_ textCase: Text.Case?) -> some View {
        _EnvironmentModifier(child: self, descend: "tcase") { env in
            switch textCase {
            case .uppercase: env.textCase = "upper"
            case .lowercase: env.textCase = "lower"
            case nil: env.textCase = "none"
            }
        }
    }
}

extension Text {
    /// What `.textCase` sets.
    public enum Case: Sendable, Hashable { case uppercase, lowercase }
}

// MARK: - Scroll targeting

extension View {
    /// `.id(_:)`: names this view for `ScrollViewProxy.scrollTo` (identity
    /// for ForEach rows is handled by ForEach itself).
    nonisolated public func id<ID: Hashable>(_ id: ID) -> some View {
        _ModifiedView(child: self, descend: "vid", pure: true) { inner, _ in
            inner.scrollTarget = String(describing: id)
            return inner
        }
    }
}

public struct ScrollViewProxy {
    /// Scrolls the ScrollView containing the view with that `.id` so it sits
    /// at `anchor` (nil = the nearest edge that makes it visible).
    public func scrollTo<ID: Hashable>(_ id: ID, anchor: UnitPoint? = nil) {
        let name: String
        if let anchor {
            switch (anchor.x, anchor.y) {
            case (_, 0): name = "top"
            case (_, 1): name = "bottom"
            case (_, 0.5): name = "center"
            default: name = "bottom"
            }
        } else {
            name = "auto"
        }
        let runtime = Runtime.shared
        runtime.pendingScroll = (String(describing: id), name, (runtime.pendingScroll?.tick ?? 0) + 1,
                                 runtime.transactionAnimation != nil)
        // A list holding the target row unbuilt builds it (Reuse.swift's
        // window): that list is not reused across the request. (A chat's
        // scroll to its bottom row, always built, rebuilds nothing.)
        runtime.listsMissingScrollTarget(String(describing: id)).forEach { runtime.stateDidChange(key: $0 + "#window") }
        runtime.requestFrame()
    }
}

/// `ScrollViewReader { proxy in … }`: the content gets a proxy whose
/// `scrollTo` targets `.id`s inside the ScrollViews it contains.
public struct ScrollViewReader<Content: View> {
    let content: (ScrollViewProxy) -> Content

    public init(@ViewBuilder content: @escaping (ScrollViewProxy) -> Content) {
        self.content = content
    }

    public var body: some View { content(ScrollViewProxy()) }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension ScrollViewReader: View {}

#if os(iOS) && canImport(UIKit)
import UIKit

extension View {
    /// The keyboard a text field asks for.
    nonisolated public func keyboardType(_ type: UIKeyboardType) -> some View {
        _EnvironmentModifier(child: self, descend: "keyboard") { env in env.keyboardType = keyboardName(type) }
    }
}

/// A keyboard type as the hosts name it.
private func keyboardName(_ type: UIKeyboardType) -> String {
    switch type {
    case .asciiCapable: return "asciiCapable"
    case .numbersAndPunctuation: return "numbersAndPunctuation"
    case .URL: return "URL"
    case .numberPad: return "numberPad"
    case .phonePad: return "phonePad"
    case .namePhonePad: return "namePhonePad"
    case .emailAddress: return "emailAddress"
    case .decimalPad: return "decimalPad"
    case .twitter: return "twitter"
    case .webSearch: return "webSearch"
    case .asciiCapableNumberPad: return "asciiCapableNumberPad"
    default: return "default"
    }
}
#endif
