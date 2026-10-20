// Modifiers that mark a view for the host: its drawing order, whether it
// takes touches, its blur, a tooltip, the pointer over it, a keyboard
// shortcut, the scroll's indicators and background. Each host does what its
// platform can (the web all of them; Compose the order and the blur; the
// drawn path the order and the touches).

extension View {
    /// `.zIndex(_:)`: drawn above its siblings with lower values.
    nonisolated public func zIndex(_ value: Double) -> some View {
        _ModifiedView(child: self, descend: "zindex", pure: true) { inner, _ in
            inner.zIndex = value
            return inner
        }
    }

    /// `.allowsHitTesting(_:)`: false, it is drawn but touches pass through
    /// it to what is under it.
    nonisolated public func allowsHitTesting(_ enabled: Bool) -> some View {
        _ModifiedView(child: self, descend: "hittesting", pure: true) { inner, _ in
            inner.hitTestingDisabled = !enabled
            return inner
        }
    }

    /// `.blur(radius:opaque:)`.
    nonisolated public func blur(radius: CGFloat, opaque: Bool = false) -> some View {
        _ModifiedView(child: self, descend: "blur", pure: true) { inner, _ in
            let box = RenderNode.box(child: inner)
            if radius > 0 { box.hostHints.append(("blur", String(Double(radius)))) }
            return box
        }
    }

    /// `.help(_:)`: what the view does, shown when the pointer rests on it.
    nonisolated public func help<S: StringProtocol>(_ text: S) -> some View {
        let text = String(text)
        return _ModifiedView(child: self, descend: "help", pure: true) { inner, _ in
            let box = RenderNode.box(child: inner)
            box.hostHints.append(("help", text))
            return box
        }
    }

    nonisolated public func help(_ text: Text) -> some View { help(text.content) }

    /// `.onHover(perform:)`: told true when a pointer comes over the view,
    /// false when it leaves (where there is a pointer).
    nonisolated public func onHover(perform action: @escaping (Bool) -> Void) -> some View {
        _ModifiedView(child: self, descend: "hover", pure: false) { inner, _ in
            let box = RenderNode.box(child: inner)
            box.hoverAction = action
            return box
        }
    }

    /// `.keyboardShortcut(_:modifiers:)`: the key presses the button in it
    /// (where there is a keyboard).
    nonisolated public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        _ModifiedView(child: self, descend: "shortcut", pure: true) { inner, _ in
            let box = RenderNode.box(child: inner)
            box.hostHints.append(("shortcut", _shortcutName(key, modifiers)))
            return box
        }
    }

    /// `.keyboardShortcut(.defaultAction)` and the like.
    nonisolated public func keyboardShortcut(_ shortcut: KeyboardShortcut) -> some View {
        keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
    }

    /// `.scrollIndicators(_:axes:)`: whether the scrolls in it show their
    /// indicators.
    nonisolated public func scrollIndicators(_ visibility: ScrollIndicatorVisibility, axes: Axis.Set = [.vertical, .horizontal]) -> some View {
        _EnvironmentModifier(child: self, descend: "indicators") { env in
            env.scrollIndicatorsHidden = visibility == .hidden || visibility == .never
        }
    }

    /// `.scrollContentBackground(.hidden)`: a List's or a Form's own ground
    /// is not drawn, so what is behind it shows.
    nonisolated public func scrollContentBackground(_ visibility: Visibility) -> some View {
        _EnvironmentModifier(child: self, descend: "contentbg") { env in
            env.scrollContentBackgroundHidden = visibility == .hidden
        }
    }
}

/// A shortcut as the hosts read it: "cmd+shift+n", "return", "escape".
func _shortcutName(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> String {
    var parts: [String] = []
    if modifiers.contains(.command) { parts.append("cmd") }
    if modifiers.contains(.control) { parts.append("ctrl") }
    if modifiers.contains(.option) { parts.append("alt") }
    if modifiers.contains(.shift) { parts.append("shift") }
    let names: [Character: String] = [
        "\r": "enter", "\u{1B}": "escape", "\t": "tab", " ": "space", "\u{7F}": "backspace",
        "\u{F700}": "arrowup", "\u{F701}": "arrowdown", "\u{F702}": "arrowleft", "\u{F703}": "arrowright",
    ]
    parts.append(names[key.character] ?? String(key.character).lowercased())
    return parts.joined(separator: "+")
}

/// `KeyboardShortcut`: a key and its modifiers, and the two standard ones.
public struct KeyboardShortcut: Hashable, Sendable {
    public let key: KeyEquivalent
    public let modifiers: EventModifiers

    public init(_ key: KeyEquivalent, modifiers: EventModifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Return: a dialog's default button.
    public static let defaultAction = KeyboardShortcut(.return, modifiers: [])
    /// Escape: a dialog's cancel button.
    public static let cancelAction = KeyboardShortcut(.escape, modifiers: [])

    // Written out, as Apple's are: EventModifiers is not Hashable.
    public static func == (lhs: KeyboardShortcut, rhs: KeyboardShortcut) -> Bool {
        lhs.key == rhs.key && lhs.modifiers == rhs.modifiers
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }
}

/// `.scrollIndicators` visibility.
public struct ScrollIndicatorVisibility: Equatable, Sendable {
    enum Kind: Hashable, Sendable { case automatic, visible, hidden, never }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
    public static let automatic = ScrollIndicatorVisibility(.automatic)
    public static let visible = ScrollIndicatorVisibility(.visible)
    public static let hidden = ScrollIndicatorVisibility(.hidden)
    public static let never = ScrollIndicatorVisibility(.never)
}
