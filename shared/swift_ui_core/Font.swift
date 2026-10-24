public struct Font: Hashable, Sendable {
    public struct Weight: Hashable, Sendable {
        /// CSS-style numeric weight 100...900.
        package let value: Int

        public static let ultraLight = Weight(value: 100)
        public static let thin = Weight(value: 200)
        public static let light = Weight(value: 300)
        public static let regular = Weight(value: 400)
        public static let medium = Weight(value: 500)
        public static let semibold = Weight(value: 600)
        public static let bold = Weight(value: 700)
        public static let heavy = Weight(value: 800)
        public static let black = Weight(value: 900)
    }

    public enum Design: Sendable {
        case `default`, monospaced, rounded, serif
    }

    package var size: CGFloat
    package var weight: Weight
    package var design: Design
    /// The text style it is (`.body`, `.subheadline`, …), nil for a fixed
    /// size: hosts with their own type ramp use the style (its leading,
    /// Dynamic Type) rather than the size (param "textStyle").
    var textStyle: String?
    /// `.italic()`: slanted.
    var isItalic = false
    /// `Font.custom`: a typeface by name, which hosts that have it use
    /// (param "family"); the system's otherwise.
    var family: String?
    /// `.monospacedDigit()`: digits of one width, so numbers that change
    /// keep their place (param "tnum": hosts set tabular figures).
    var monospacedDigits = false

    init(size: CGFloat, weight: Weight = .regular, design: Design = .default, textStyle: String? = nil) {
        self.size = size
        self.weight = weight
        self.design = design
        self.textStyle = textStyle
    }

    /// `Font.custom(_:size:)`: the named typeface at this size.
    public static func custom(_ name: String, size: CGFloat) -> Font {
        var font = Font(size: size)
        font.family = name
        return font
    }

    /// `Font.custom(_:size:relativeTo:)`: as a text style scales (here, at
    /// the size given).
    public static func custom(_ name: String, size: CGFloat, relativeTo textStyle: Font.TextStyle) -> Font {
        var font = custom(name, size: size)
        font.textStyle = nil
        return font
    }

    /// `Font.system(_:design:weight:)`: a text style in a design and weight.
    public static func system(_ style: Font.TextStyle, design: Design? = nil, weight: Weight? = nil) -> Font {
        var font = style.font
        if let design { font.design = design }
        if let weight { font.weight = weight }
        return font
    }

    /// SwiftUI's text styles, by name.
    public enum TextStyle: Hashable, Sendable, CaseIterable {
        case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2

        var font: Font {
            switch self {
            case .largeTitle: return .largeTitle
            case .title: return .title
            case .title2: return .title2
            case .title3: return .title3
            case .headline: return .headline
            case .subheadline: return .subheadline
            case .body: return .body
            case .callout: return .callout
            case .footnote: return .footnote
            case .caption: return .caption
            case .caption2: return .caption2
            }
        }
    }

    public static func system(
        size: CGFloat,
        weight: Weight = .regular,
        design: Design = .default
    ) -> Font {
        Font(size: size, weight: weight, design: design)
    }

    public static let largeTitle = Font(size: 34, weight: .regular, textStyle: "largeTitle")
    public static let title = Font(size: 28, weight: .regular, textStyle: "title")
    public static let title2 = Font(size: 22, weight: .regular, textStyle: "title2")
    public static let title3 = Font(size: 20, weight: .regular, textStyle: "title3")
    public static let headline = Font(size: 17, weight: .semibold, textStyle: "headline")
    public static let body = Font(size: 17, weight: .regular, textStyle: "body")
    public static let callout = Font(size: 16, weight: .regular, textStyle: "callout")
    public static let subheadline = Font(size: 15, weight: .regular, textStyle: "subheadline")
    public static let footnote = Font(size: 13, weight: .regular, textStyle: "footnote")
    public static let caption = Font(size: 12, weight: .regular, textStyle: "caption")
    public static let caption2 = Font(size: 11, weight: .regular, textStyle: "caption2")

    public func weight(_ weight: Weight) -> Font {
        var font = self
        font.weight = weight
        return font
    }

    public func bold() -> Font {
        weight(.bold)
    }

    public func monospaced() -> Font {
        var font = self
        font.design = .monospaced
        return font
    }

    public func italic() -> Font {
        var font = self
        font.isItalic = true
        return font
    }

    /// Digits of one width (tabular figures), the rest as it was.
    public func monospacedDigit() -> Font {
        var font = self
        font.monospacedDigits = true
        return font
    }
}
