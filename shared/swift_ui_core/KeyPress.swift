/// `KeyEquivalent`: a key, as the character SwiftUI names it by. The keys
/// that type nothing carry the private-use characters AppKit gives them.
public struct KeyEquivalent: Hashable, Sendable {
    public var character: Character

    public init(_ character: Character) { self.character = character }

    public static let `return` = KeyEquivalent("\r")
    public static let delete = KeyEquivalent("\u{7F}")
    public static let deleteForward = KeyEquivalent("\u{F728}")
    public static let escape = KeyEquivalent("\u{1B}")
    public static let tab = KeyEquivalent("\t")
    public static let space = KeyEquivalent(" ")
    public static let clear = KeyEquivalent("\u{F739}")
    public static let upArrow = KeyEquivalent("\u{F700}")
    public static let downArrow = KeyEquivalent("\u{F701}")
    public static let leftArrow = KeyEquivalent("\u{F702}")
    public static let rightArrow = KeyEquivalent("\u{F703}")
    public static let home = KeyEquivalent("\u{F729}")
    public static let end = KeyEquivalent("\u{F72B}")
    public static let pageUp = KeyEquivalent("\u{F72C}")
    public static let pageDown = KeyEquivalent("\u{F72D}")
}

extension KeyEquivalent: ExpressibleByExtendedGraphemeClusterLiteral {
    public init(extendedGraphemeClusterLiteral character: Character) { self.init(character) }
}

/// `EventModifiers`: the modifier keys held during an event.
public struct EventModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let capsLock = EventModifiers(rawValue: 1 << 0)
    public static let shift = EventModifiers(rawValue: 1 << 1)
    public static let control = EventModifiers(rawValue: 1 << 2)
    public static let option = EventModifiers(rawValue: 1 << 3)
    public static let command = EventModifiers(rawValue: 1 << 4)
    public static let numericPad = EventModifiers(rawValue: 1 << 5)
    public static let function = EventModifiers(rawValue: 1 << 6)
    public static let all: EventModifiers = [.capsLock, .shift, .control, .option, .command, .numericPad, .function]
}

/// `KeyPress`: one key event, as `.onKeyPress` hands it to its action.
public struct KeyPress: Sendable {
    /// `KeyPress.Phases`: down, held (repeat) and up.
    public struct Phases: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let down = Phases(rawValue: 1 << 0)
        public static let `repeat` = Phases(rawValue: 1 << 1)
        public static let up = Phases(rawValue: 1 << 2)
        public static let all: Phases = [.down, .repeat, .up]
    }

    /// `KeyPress.Result`: whether the action took the key. A key taken is
    /// not typed into the focused field.
    public enum Result: Sendable {
        case handled
        case ignored
    }

    public var phase: Phases
    public var key: KeyEquivalent
    public var characters: String
    public var modifiers: EventModifiers

    package init(phase: Phases, key: KeyEquivalent, characters: String, modifiers: EventModifiers) {
        self.phase = phase
        self.key = key
        self.characters = characters
        self.modifiers = modifiers
    }

    /// A host's report of a key: phase ("d"/"r"/"u") and modifier letters
    /// (s shift, c control, o option, m command, l caps lock), the key's
    /// character, the characters it types, separated by U+001F.
    init?(hostValue: String) {
        let parts = hostValue.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let key = parts[1].first, let phase = parts[0].first else { return nil }
        switch phase {
        case "d": self.phase = .down
        case "r": self.phase = .repeat
        case "u": self.phase = .up
        default: return nil
        }
        var modifiers: EventModifiers = []
        for letter in parts[0].dropFirst() {
            switch letter {
            case "s": modifiers.insert(.shift)
            case "c": modifiers.insert(.control)
            case "o": modifiers.insert(.option)
            case "m": modifiers.insert(.command)
            case "l": modifiers.insert(.capsLock)
            default: break
            }
        }
        self.key = KeyEquivalent(key)
        self.characters = String(parts[2])
        self.modifiers = modifiers
    }
}

/// A view's key handlers in scope, innermost first: the focused field asks
/// each in turn until one takes the key.
struct KeyPressHandler {
    let phases: KeyPress.Phases
    let action: (KeyPress) -> KeyPress.Result
}

extension View {
    /// `.onKeyPress(phases:action:)`: key presses while a text field in
    /// this subtree has focus (the field is where the platforms deliver
    /// keys); `.handled` keeps the key from being typed.
    nonisolated public func onKeyPress(
        phases: KeyPress.Phases = [.down, .repeat],
        action: @escaping (KeyPress) -> KeyPress.Result
    ) -> some View {
        _EnvironmentModifier(child: self, descend: "keypress") { env in
            env.keyPressHandlers.append(KeyPressHandler(phases: phases, action: action))
        }
    }

    /// `.onKeyPress(_:action:)`: one key, pressed or held.
    nonisolated public func onKeyPress(
        _ key: KeyEquivalent,
        action: @escaping () -> KeyPress.Result
    ) -> some View {
        onKeyPress(phases: [.down, .repeat]) { $0.key == key ? action() : .ignored }
    }

    /// `.onKeyPress(_:phases:action:)`: one key, in the given phases.
    nonisolated public func onKeyPress(
        _ key: KeyEquivalent,
        phases: KeyPress.Phases,
        action: @escaping (KeyPress) -> KeyPress.Result
    ) -> some View {
        onKeyPress(phases: phases) { $0.key == key ? action($0) : .ignored }
    }

    /// `.onKeyPress(keys:phases:action:)`: any of a set of keys.
    nonisolated public func onKeyPress(
        keys: Set<KeyEquivalent>,
        phases: KeyPress.Phases = [.down, .repeat],
        action: @escaping (KeyPress) -> KeyPress.Result
    ) -> some View {
        onKeyPress(phases: phases) { keys.contains($0.key) ? action($0) : .ignored }
    }
}

extension Runtime {
    /// A host's key event for a field (host -> runtime): true when a
    /// handler took it, so the host keeps the key from the field.
    public func keyPressEvent(id: String, value: String) -> Bool {
        keyPressHandled = false
        hostViewEvent(id: id, value: value)
        return keyPressHandled
    }
}
