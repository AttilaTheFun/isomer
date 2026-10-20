// `LocalizedStringKey` — what a string literal given to `Text` is, as in
// SwiftUI: its inline markdown is the text's styling (**bold**, *italic*,
// `code`, ~~struck~~, [links](url) and bare http(s) URLs), while what is
// interpolated into it is taken as it is (markup around an interpolation
// still applies to it, as SwiftUI's format string does). `Text(variable)`
// with a String stays plain, as in SwiftUI.

public struct LocalizedStringKey: Equatable, Sendable, ExpressibleByStringInterpolation {
    /// The key's characters, and which of them came from interpolations
    /// (never read as markup).
    let characters: [Character]
    let verbatim: [Bool]
    /// Texts interpolated into the key (`"\(Text(Image(…)).foregroundColor(.orange)) \(title)"`,
    /// SwiftUI's way to join styled texts now that `Text + Text` is
    /// deprecated), each at the character offset it stands at.
    let texts: _InterpolatedTexts?

    public init(_ value: String) {
        characters = Array(value)
        verbatim = Array(repeating: false, count: characters.count)
        texts = nil
    }

    init(characters: ArraySlice<Character>, verbatim: ArraySlice<Bool>) {
        self.characters = Array(characters)
        self.verbatim = Array(verbatim)
        texts = nil
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public init(stringInterpolation: StringInterpolation) {
        characters = stringInterpolation.characters
        verbatim = stringInterpolation.verbatim
        texts = stringInterpolation.texts.isEmpty ? nil : _InterpolatedTexts(items: stringInterpolation.texts)
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var characters: [Character] = []
        var verbatim: [Bool] = []
        var texts: [(offset: Int, text: Text)] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            characters.reserveCapacity(literalCapacity)
            verbatim.reserveCapacity(literalCapacity)
        }

        public mutating func appendLiteral(_ literal: String) {
            for character in literal {
                characters.append(character)
                verbatim.append(false)
            }
        }

        public mutating func appendInterpolation<T>(_ value: T) {
            for character in String(describing: value) {
                characters.append(character)
                verbatim.append(true)
            }
        }

        /// A text, with its own styles, where it stands.
        public mutating func appendInterpolation(_ text: Text) {
            texts.append((characters.count, text))
        }

        /// An image among the words (an SF Symbol as its glyph).
        public mutating func appendInterpolation(_ image: Image) {
            appendInterpolation(Text(image))
        }
    }
}

/// The texts interpolated into a key, by offset.
final class _InterpolatedTexts: Equatable, @unchecked Sendable {
    let items: [(offset: Int, text: Text)]

    init(items: [(offset: Int, text: Text)]) {
        self.items = items
    }

    static func == (lhs: _InterpolatedTexts, rhs: _InterpolatedTexts) -> Bool {
        lhs.items.count == rhs.items.count && zip(lhs.items, rhs.items).allSatisfy {
            $0.offset == $1.offset && $0.text.content == $1.text.content && $0.text.runs == $1.text.runs
                && $0.text.ownRun == $1.text.ownRun
        }
    }
}

/// A span of a key's text with its markdown styles.
struct _MarkdownSpan {
    var text = ""
    var bold = false
    var italic = false
    var code = false
    var strike = false
    var link: String?
}

/// Whether any character of the key outside its interpolations is one
/// inline markdown starts at: an escape, a code span, a link, emphasis or
/// strikethrough, or the colon of an autolink.
private func _mayHaveMarkup(_ chars: [Character], _ opaque: [Bool]) -> Bool {
    for (i, c) in chars.enumerated() where !opaque[i] {
        switch c.asciiValue {
        case UInt8(ascii: "\\"), UInt8(ascii: "`"), UInt8(ascii: "["), UInt8(ascii: "*"),
             UInt8(ascii: "_"), UInt8(ascii: "~"), UInt8(ascii: ":"):
            return true
        default:
            continue
        }
    }
    return false
}

/// The key's inline markdown, as spans. Unclosed markup is literal text.
func _inlineMarkdown(_ key: LocalizedStringKey) -> [_MarkdownSpan] {
    let chars = key.characters
    let opaque = key.verbatim
    // Most keys have nothing markdown acts on: their text is one plain span,
    // without the parse (character by character, over a millisecond a Text
    // interpreted).
    if !_mayHaveMarkup(chars, opaque) { return chars.isEmpty ? [] : [_MarkdownSpan(text: String(chars))] }
    var spans: [_MarkdownSpan] = []
    var current = _MarkdownSpan()
    var bold = false, italic = false, strike = false

    func flush() {
        if !current.text.isEmpty { spans.append(current) }
        current = _MarkdownSpan(bold: bold, italic: italic, strike: strike)
    }
    func markup(_ i: Int) -> Bool { i < chars.count && !opaque[i] }
    /// Where `marker` (unescaped, not interpolated) next occurs from `i`.
    func find(_ marker: [Character], from i: Int) -> Int? {
        var j = i
        while j + marker.count <= chars.count {
            if chars[j] == "\\" && markup(j) { j += 2; continue }
            if (0..<marker.count).allSatisfy({ markup(j + $0) && chars[j + $0] == marker[$0] }) { return j }
            j += 1
        }
        return nil
    }
    func isWordCharacter(_ i: Int) -> Bool { i >= 0 && i < chars.count && (chars[i].isLetter || chars[i].isNumber) }

    var i = 0
    while i < chars.count {
        let c = chars[i]
        guard markup(i) else { current.text.append(c); i += 1; continue }
        // An escaped character is itself.
        if c == "\\", i + 1 < chars.count, "\\`*_{}[]()#+-.!~<>".contains(chars[i + 1]) {
            current.text.append(chars[i + 1]); i += 2; continue
        }
        // `code`: verbatim to the closing tick.
        if c == "`", let close = find(["`"], from: i + 1) {
            flush()
            current.code = true
            current.text = String(chars[(i + 1)..<close])
            flush()
            i = close + 1; continue
        }
        // [title](url)
        if c == "[", let closeBracket = find(["]"], from: i + 1), closeBracket + 1 < chars.count,
           chars[closeBracket + 1] == "(", let closeParen = find([")"], from: closeBracket + 2) {
            flush()
            current.link = String(chars[(closeBracket + 2)..<closeParen])
            current.text = String(chars[(i + 1)..<closeBracket])
            flush()
            i = closeParen + 1; continue
        }
        // A bare URL, to the next space (trailing punctuation left out).
        if c == "h", (String(chars[i..<min(i + 8, chars.count)]).hasPrefix("https://") || String(chars[i..<min(i + 7, chars.count)]).hasPrefix("http://")),
           !isWordCharacter(i - 1) {
            var end = i
            while end < chars.count, !chars[end].isWhitespace { end += 1 }
            while end > i, ".,;:!?)'\"".contains(chars[end - 1]) { end -= 1 }
            flush()
            let url = String(chars[i..<end])
            current.link = url
            current.text = url
            flush()
            i = end; continue
        }
        // **bold** / __bold__ and ~~struck~~: toggles that need a closing pair.
        if (c == "*" || c == "_" || c == "~"), i + 1 < chars.count, chars[i + 1] == c, markup(i + 1) {
            let isOpen = c == "~" ? strike : bold
            if isOpen || find([c, c], from: i + 2) != nil {
                flush()
                if c == "~" { strike.toggle(); current.strike = strike } else { bold.toggle(); current.bold = bold }
                i += 2; continue
            }
        }
        // *italic* / _italic_ (an underscore not inside a word).
        if c == "*" || (c == "_" && (italic || !isWordCharacter(i - 1))) {
            if italic || (i + 1 < chars.count && !chars[i + 1].isWhitespace && find([c], from: i + 1) != nil) {
                flush()
                italic.toggle()
                current.italic = italic
                i += 1; continue
            }
        }
        current.text.append(c)
        i += 1
    }
    flush()
    return spans
}

extension Text {
    /// A literal (or a key): its markdown as styled runs, and the texts
    /// interpolated into it joined in where they stand.
    public init(_ key: LocalizedStringKey) {
        if let texts = key.texts {
            var joined: Text?
            var start = 0
            func append(_ text: Text) { joined = joined.map { $0 + text } ?? text }
            func words(to end: Int) {
                guard end > start else { return }
                append(Text(LocalizedStringKey(characters: key.characters[start..<end], verbatim: key.verbatim[start..<end])))
                start = end
            }
            for (offset, text) in texts.items {
                words(to: offset)
                append(text)
            }
            words(to: key.characters.count)
            self = joined ?? Text(verbatim: "")
            return
        }
        let spans = _inlineMarkdown(key)
        self.content = spans.map(\.text).joined()
        let styled = spans.contains { $0.bold || $0.italic || $0.code || $0.strike || $0.link != nil }
        guard styled else { return }
        runs = spans.map { span in
            TextRun(length: span.text.count, bold: span.bold, italic: span.italic, monospaced: span.code,
                    strikethrough: span.strike, color: span.link == nil ? nil : .accentColor,
                    link: span.link, strong: span.bold, emphasized: span.italic)
        }
    }
}
