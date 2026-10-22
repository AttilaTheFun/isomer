// Text from an AttributedString (`Text(attributed)`), and the attributes
// SwiftUI adds to Foundation's for it (`AttributeScopes.SwiftUI::SwiftUIAttributes`:
// `attributed[range].foregroundColor = .secondary`). Each run of the string
// becomes a styled span of one text, as a concatenation's runs are
// (Text.swift): its colour, weight, italics, underline, strikethrough and
// link, and markdown's emphasis and code from Foundation's inline
// presentation intents. A run's own font size, background colour, kerning,
// tracking and baseline offset are not drawn.
//
// In a feature compiled against Isomer's frameworks on an Apple platform
// (ISOMER_COMPILED_FEATURE) the scope is Apple's: UIKit and AppKit, which
// that SwiftUI imports as Apple's does, load SwiftUICore, whose
// `SwiftUIAttributes` extends Foundation's `AttributeScopes` wherever they
// are imported, so a second one here would make every
// `attributed.foregroundColor` ambiguous. SwiftUICore can't be imported by
// name (it is SwiftUI's implementation), so its attributes are read through
// the scope (`attributes.swiftUI.font`) and its colours and fonts matched
// with the system's named ones (AppleStyles). Everywhere else the scope is
// declared here, named with its module (`AttributeScopes.SwiftUI::…`) where
// it is used: the cores hosted beside Apple's SwiftUI see SwiftUICore's too.

import Foundation
#if ISOMER_COMPILED_FEATURE
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
#endif

extension Text {
    /// A line drawn under or through text (`underlineStyle`,
    /// `strikethroughStyle`): drawn solid, in the text's colour, here.
    public struct LineStyle: Hashable, Sendable {
        let pattern: Pattern
        let color: Color?

        public init(pattern: Text.LineStyle.Pattern = .solid, color: Color? = nil) {
            self.pattern = pattern
            self.color = color
        }

        public struct Pattern: Sendable {
            let name: String

            public static let solid = Pattern(name: "solid")
            public static let dot = Pattern(name: "dot")
            public static let dash = Pattern(name: "dash")
            public static let dashDot = Pattern(name: "dashDot")
            public static let dashDotDot = Pattern(name: "dashDotDot")
        }

        public static let single = LineStyle()

        public static func == (a: Text.LineStyle, b: Text.LineStyle) -> Bool {
            a.pattern.name == b.pattern.name && a.color == b.color
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(pattern.name)
            hasher.combine(color)
        }
    }

    @_disfavoredOverload
    public init(_ attributedContent: AttributedString) {
        #if os(Windows)
        // Swift 6.3.2's Foundation on Windows doesn't export the descriptor
        // of the attributed string's storage index (_FoundationCollections'
        // BigString.Index), so any use of `runs` fails to link: the text,
        // unstyled, until it does.
        self.init(verbatim: String(attributedContent.characters))
        #else
        var content = ""
        var runs: [TextRun] = []
        for run in attributedContent.runs {
            let piece = String(attributedContent[run.range].characters)
            content += piece
            var styled = TextRun(length: piece.count)
            #if ISOMER_COMPILED_FEATURE
            let apple = run.attributes.swiftUI
            let font = apple.font.flatMap { AppleStyles.fonts[AnyHashable($0)] }
            styled.color = apple.foregroundColor.flatMap { AppleStyles.colors[AnyHashable($0)] }
            styled.underline = apple.underlineStyle != nil
            styled.strikethrough = apple.strikethroughStyle != nil
            #else
            typealias Keys = AttributeScopes.SwiftUI::SwiftUIAttributes
            let font = run[Keys.FontAttribute.self]
            styled.color = run[Keys.ForegroundColorAttribute.self]
            styled.underline = run[Keys.UnderlineStyleAttribute.self] != nil
            styled.strikethrough = run[Keys.StrikethroughStyleAttribute.self] != nil
            #endif
            if let font {
                styled.weight = font.weight.value
                styled.bold = font.weight.value >= Font.Weight.semibold.value
                styled.italic = font.isItalic
                styled.monospaced = font.design == .monospaced
            }
            // Markdown's emphasis and code (Apple's Foundation parses
            // markdown; swift-foundation has no presentation intents).
            #if canImport(Darwin)
            if let intent = run[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] {
                styled.strong = intent.contains(.stronglyEmphasized)
                styled.emphasized = intent.contains(.emphasized)
                styled.bold = styled.bold || styled.strong
                styled.italic = styled.italic || styled.emphasized
                styled.monospaced = styled.monospaced || intent.contains(.code)
                styled.strikethrough = styled.strikethrough || intent.contains(.strikethrough)
            }
            #endif
            styled.link = run[AttributeScopes.FoundationAttributes.LinkAttribute.self]?.absoluteString
            runs.append(styled)
        }
        self.init(verbatim: content)
        if runs.count > 1 || runs.contains(where: { $0 != TextRun(length: $0.length) }) {
            self.runs = runs
        }
        #endif
    }
}

#if ISOMER_COMPILED_FEATURE
/// Apple's named colours and text styles (at each weight) as Isomer's, keyed
/// by Apple's values (as `AnyHashable`: their type is SwiftUICore's), made by
/// setting each on an attribute container. Another colour or font is not
/// drawn.
private enum AppleStyles {
    static let colors: [AnyHashable: Color] = {
        var colors: [AnyHashable: Color] = [:]
        func add(_ set: (inout AttributeContainer) -> Void, _ color: Color) {
            var probe = AttributeContainer()
            set(&probe)
            if let apple = probe.swiftUI.foregroundColor { colors[AnyHashable(apple)] = color }
        }
        add({ $0.swiftUI.foregroundColor = .primary }, .primary)
        add({ $0.swiftUI.foregroundColor = .secondary }, .secondary)
        add({ $0.swiftUI.foregroundColor = .accentColor }, .accentColor)
        add({ $0.swiftUI.foregroundColor = .red }, .red)
        add({ $0.swiftUI.foregroundColor = .orange }, .orange)
        add({ $0.swiftUI.foregroundColor = .yellow }, .yellow)
        add({ $0.swiftUI.foregroundColor = .green }, .green)
        add({ $0.swiftUI.foregroundColor = .mint }, .mint)
        add({ $0.swiftUI.foregroundColor = .teal }, .teal)
        add({ $0.swiftUI.foregroundColor = .cyan }, .cyan)
        add({ $0.swiftUI.foregroundColor = .blue }, .blue)
        add({ $0.swiftUI.foregroundColor = .indigo }, .indigo)
        add({ $0.swiftUI.foregroundColor = .purple }, .purple)
        add({ $0.swiftUI.foregroundColor = .pink }, .pink)
        add({ $0.swiftUI.foregroundColor = .brown }, .brown)
        add({ $0.swiftUI.foregroundColor = .gray }, .gray)
        add({ $0.swiftUI.foregroundColor = .white }, .white)
        add({ $0.swiftUI.foregroundColor = .black }, .black)
        add({ $0.swiftUI.foregroundColor = .clear }, .clear)
        return colors
    }()

    static let fonts: [AnyHashable: Font] = {
        var fonts: [AnyHashable: Font] = [:]
        func add(_ set: (inout AttributeContainer) -> Void, _ font: Font) {
            var probe = AttributeContainer()
            set(&probe)
            guard let apple = probe.swiftUI.font else { return }
            fonts[AnyHashable(apple)] = font
            fonts[AnyHashable(apple.bold())] = font.bold()
            fonts[AnyHashable(apple.italic())] = font.italic()
            let weights: [(AnyHashable, Font.Weight)] = [
                (AnyHashable(apple.weight(.ultraLight)), .ultraLight), (AnyHashable(apple.weight(.thin)), .thin),
                (AnyHashable(apple.weight(.light)), .light), (AnyHashable(apple.weight(.regular)), .regular),
                (AnyHashable(apple.weight(.medium)), .medium), (AnyHashable(apple.weight(.semibold)), .semibold),
                (AnyHashable(apple.weight(.bold)), .bold), (AnyHashable(apple.weight(.heavy)), .heavy),
                (AnyHashable(apple.weight(.black)), .black),
            ]
            for (key, weight) in weights { fonts[key] = font.weight(weight) }
        }
        add({ $0.swiftUI.font = .largeTitle }, .largeTitle)
        add({ $0.swiftUI.font = .title }, .title)
        add({ $0.swiftUI.font = .title2 }, .title2)
        add({ $0.swiftUI.font = .title3 }, .title3)
        add({ $0.swiftUI.font = .headline }, .headline)
        add({ $0.swiftUI.font = .subheadline }, .subheadline)
        add({ $0.swiftUI.font = .body }, .body)
        add({ $0.swiftUI.font = .callout }, .callout)
        add({ $0.swiftUI.font = .footnote }, .footnote)
        add({ $0.swiftUI.font = .caption }, .caption)
        add({ $0.swiftUI.font = .caption2 }, .caption2)
        return fonts
    }()
}
#else
@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AttributeScopes {
    public var swiftUI: AttributeScopes.SwiftUI::SwiftUIAttributes.Type { AttributeScopes.SwiftUI::SwiftUIAttributes.self }

    public struct SwiftUIAttributes: AttributeScope {
        public let font: AttributeScopes.SwiftUI::SwiftUIAttributes.FontAttribute
        public let foregroundColor: AttributeScopes.SwiftUI::SwiftUIAttributes.ForegroundColorAttribute
        public let backgroundColor: AttributeScopes.SwiftUI::SwiftUIAttributes.BackgroundColorAttribute
        public let strikethroughStyle: AttributeScopes.SwiftUI::SwiftUIAttributes.StrikethroughStyleAttribute
        public let underlineStyle: AttributeScopes.SwiftUI::SwiftUIAttributes.UnderlineStyleAttribute
        public let kern: AttributeScopes.SwiftUI::SwiftUIAttributes.KerningAttribute
        public let tracking: AttributeScopes.SwiftUI::SwiftUIAttributes.TrackingAttribute
        public let baselineOffset: AttributeScopes.SwiftUI::SwiftUIAttributes.BaselineOffsetAttribute
        public let foundation: AttributeScopes.FoundationAttributes

        public typealias DecodingConfiguration = AttributeScopeCodableConfiguration
        public typealias EncodingConfiguration = AttributeScopeCodableConfiguration
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AttributeScopes.SwiftUI::SwiftUIAttributes {
    @frozen public enum FontAttribute: AttributedStringKey {
        public typealias Value = Font
        public static let name = "SwiftUI.Font"
    }

    @frozen public enum ForegroundColorAttribute: AttributedStringKey {
        public typealias Value = Color
        public static let name = "SwiftUI.ForegroundColor"
    }

    @frozen public enum BackgroundColorAttribute: AttributedStringKey {
        public typealias Value = Color
        public static let name = "SwiftUI.BackgroundColor"
    }

    @frozen public enum StrikethroughStyleAttribute: AttributedStringKey {
        public typealias Value = Text.LineStyle
        public static let name = "SwiftUI.StrikethroughStyle"
    }

    @frozen public enum UnderlineStyleAttribute: AttributedStringKey {
        public typealias Value = Text.LineStyle
        public static let name = "SwiftUI.UnderlineStyle"
    }

    @frozen public enum KerningAttribute: CodableAttributedStringKey {
        public typealias Value = CGFloat
        public static let name = "SwiftUI.Kern"
    }

    @frozen public enum TrackingAttribute: CodableAttributedStringKey {
        public typealias Value = CGFloat
        public static let name = "SwiftUI.Tracking"
    }

    @frozen public enum BaselineOffsetAttribute: CodableAttributedStringKey {
        public typealias Value = CGFloat
        public static let name = "SwiftUI.BaselineOffset"
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.SwiftUI::SwiftUIAttributes, T>) -> T {
        self[T.self]
    }
}
#endif
