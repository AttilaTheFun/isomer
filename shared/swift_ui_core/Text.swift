/// One styled span of a concatenated Text (`Text("a").bold() + Text("b")`):
/// its length in the joined string and the styles it carries beyond the
/// Text's own.
struct TextRun: Equatable {
    var length: Int
    var bold = false
    var italic = false
    var monospaced = false
    var underline = false
    var strikethrough = false
    /// A colour of its own (a link's), else the Text's.
    var color: Color?
    /// Its weight when it set one (`.fontWeight(.semibold)`), which hosts
    /// with fonts of every weight use; `bold` stands for it elsewhere.
    var weight: Int?
    /// A markdown link's URL (`[title](url)`, a bare URL in a literal).
    var link: String?
    /// Markdown's strong emphasis / emphasis (`**`, `*`), which a host with
    /// the system's text draws as its markdown does (flags S, E beside b, i).
    var strong = false
    var emphasized = false
    /// `.monospacedDigit()` on this part (`Text("Score: ") +
    /// Text("\(n)").monospacedDigit()`): tabular figures.
    var tabular = false
}

public struct Text {
    var content: String
    var explicitFont: Font?
    var explicitWeight: Font.Weight?
    var explicitColor: Color?
    var isItalic = false
    /// Styled as its container would style it (`Section("Title")`'s
    /// header): hosts whose container styles text itself leave it to them.
    var containerStyled = false
    var isUnderlined = false
    var isStruck = false
    var isMonospaced = false
    /// `.monospacedDigit()`: tabular figures, whatever its font.
    var monospacedDigits = false
    /// Set once two differently styled Texts are joined; empty otherwise.
    var runs: [TextRun] = []

    /// A string, as it is (a literal is a `LocalizedStringKey`, whose
    /// markdown is styling, as in SwiftUI).
    @_disfavoredOverload
    public init<S: StringProtocol>(_ content: S) {
        self.content = String(content)
    }

    public init(verbatim content: String) {
        self.content = content
    }

    /// A value as a format style writes it (`Text(date, format:
    /// .relative(presentation: .named))`), as it reads when built.
    public init<F: FormatStyle>(_ input: F.FormatInput, format: F) where F.FormatInput: Equatable, F.FormatOutput == String {
        self.content = format.format(input)
    }

    /// An image in a run of text (`Text(Image(systemName:)) + Text(…)`): a
    /// symbol is its glyph among the words; on its own, hosts with SF Symbols
    /// draw the symbol itself.
    public init(_ image: Image) {
        self.content = image.systemGlyph ?? ""
        self.symbolName = image.systemGlyph == nil ? nil : image.source
    }

    /// The SF Symbol this text stands for, when it is one on its own.
    var symbolName: String?

    public typealias Body = Never

    public func bold() -> Text {
        var copy = self
        copy.explicitWeight = .bold
        return copy
    }

    public func italic() -> Text {
        var copy = self
        copy.isItalic = true
        return copy
    }

    /// Bold when `isActive`; otherwise the text as it is (SwiftUI's
    /// `bold(_:)`).
    public func bold(_ isActive: Bool) -> Text {
        isActive ? bold() : self
    }

    /// Italic when `isActive`; otherwise the text as it is.
    public func italic(_ isActive: Bool) -> Text {
        isActive ? italic() : self
    }

    public func underline(_ active: Bool = true, color: Color? = nil) -> Text {
        var copy = self
        copy.isUnderlined = active
        return copy
    }

    public func strikethrough(_ active: Bool = true, color: Color? = nil) -> Text {
        var copy = self
        copy.isStruck = active
        return copy
    }

    public func monospaced(_ active: Bool = true) -> Text {
        var copy = self
        copy.isMonospaced = active
        return copy
    }

    /// Digits of one width (tabular figures).
    public func monospacedDigit() -> Text {
        var copy = self
        copy.monospacedDigits = true
        return copy
    }

    /// This Text as one run (its own styles), for concatenation.
    var ownRun: TextRun {
        TextRun(length: content.count, bold: explicitWeight == .bold || explicitWeight == .semibold || explicitWeight == .heavy,
                italic: isItalic, monospaced: isMonospaced, underline: isUnderlined, strikethrough: isStruck, color: explicitColor,
                weight: explicitWeight?.value, tabular: monospacedDigits)
    }

    public func fontWeight(_ weight: Font.Weight?) -> Text {
        var copy = self
        copy.explicitWeight = weight
        return copy
    }

    public func font(_ font: Font?) -> Text {
        var copy = self
        copy.explicitFont = font
        return copy
    }

    public func foregroundColor(_ color: Color?) -> Text {
        var copy = self
        copy.explicitColor = color
        return copy
    }

    /// The generic form (see the View overload in Modifiers.swift).
    public func foregroundStyle(_ style: some ShapeStyle) -> Text {
        foregroundColor(resolveStyleColor(style))
    }
}

extension Text: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let cased = ctx.env.textCase == "upper" ? content.uppercased() : ctx.env.textCase == "lower" ? content.lowercased() : content
        let node = RenderNode(kind: .text(cased))
        node.symbolName = symbolName
        node.truncation = ctx.env.truncationMode
        node.minimumScaleFactor = ctx.env.minimumScaleFactor
        node.textCase = ctx.env.textCase
        node.lineSpacing = ctx.env.lineSpacing
        var font = explicitFont ?? ctx.env.font
        if let weight = explicitWeight {
            font = font.weight(weight)
        }
        if monospacedDigits { font = font.monospacedDigit() }
        node.font = font
        if let alignment = Runtime.shared.textAlignmentStack.last {
            node.alignment = alignment == .leading ? .leading : alignment == .trailing ? .trailing : .center
            node.textAlignmentExplicit = true
        }
        node.color = (explicitColor ?? ctx.env.foregroundColor).opacity(ctx.env.opacity)
        node.colorAuto = (explicitColor == nil || containerStyled) && !ctx.env.foregroundColorSet && ctx.env.opacity == 1
        node.fontAuto = ((explicitFont == nil && explicitWeight == nil) || containerStyled) && !ctx.env.fontSet
        node.lineLimit = ctx.env.lineLimit
        if !runs.isEmpty {
            node.textRuns = runs
        } else if isItalic || font.isItalic || isUnderlined || isStruck || isMonospaced {
            var styled = self
            styled.isItalic = isItalic || font.isItalic
            node.textRuns = [styled.ownRun]
        }
        return node
    }
}

extension Text {
    /// `Text + Text` concatenation: the strings join and each side's styles
    /// become runs on the result (rendered as styled spans of one text).
    public static func + (lhs: Text, rhs: Text) -> Text {
        var joined = Text(lhs.content + rhs.content)
        joined.explicitFont = lhs.explicitFont ?? rhs.explicitFont
        joined.explicitColor = lhs.explicitColor
        // A side already joined keeps its runs; its own monospacedDigit()
        // reaches each of them.
        func parts(_ text: Text) -> [TextRun] {
            guard !text.runs.isEmpty else { return [text.ownRun] }
            guard text.monospacedDigits else { return text.runs }
            return text.runs.map { var run = $0; run.tabular = true; return run }
        }
        joined.runs = parts(lhs) + parts(rhs)
        return joined
    }
}

public enum TextAlignment: Sendable, Equatable {
    case leading
    case center
    case trailing
}

extension View {
    /// `.multilineTextAlignment`: positions descendant text within its box
    /// (leading/center/trailing). Line-level alignment inside a wrapped
    /// paragraph follows the box alignment on the renderers that support it.
    nonisolated public func multilineTextAlignment(_ alignment: TextAlignment) -> some View {
        _StackScopedView(content: self, keyPath: \.textAlignmentStack, value: alignment)
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension Text: View {}
