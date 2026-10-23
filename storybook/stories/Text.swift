// Text: styles, weights and designs, decoration, Markdown, formatting,
// line limits, and Label.

import Foundation
import SwiftUI

extension StoryCatalog {
    static let text = StoryArea(id: "text", title: "Text", symbol: "textformat", stories: [
        Story(
            "text.styles", "Text styles", apis: ["Text", ".font(_:)", "Font.largeTitle … .caption2"],
            summary: "The system's text styles, from largeTitle to caption2. Each platform maps them to its own type scale: Dynamic Type on Apple's, Material's type roles on Android, the page's on the web."
        ) { TextStylesStory() },
        Story(
            "text.weights", "Weights and designs", apis: [".fontWeight(_:)", ".bold()", ".italic()", "Font.system(size:weight:design:)", ".monospaced()"],
            summary: "A font's weight, slant and design: the default sans serif, rounded, serif and monospaced, at a size of your own."
        ) { TextWeightsStory() },
        Story(
            "text.decoration", "Decoration and color", apis: [".underline(_:color:)", ".strikethrough(_:color:)", ".foregroundStyle(_:)", "Text(\"\\(Text)\")"],
            summary: "Underline and strikethrough, colored text, and styled Text interpolated into a string: one run that wraps as one paragraph."
        ) { TextDecorationStory() },
        Story(
            "text.markdown", "Markdown", apis: ["Text(_: LocalizedStringKey)", "Text(verbatim:)"],
            summary: "A string literal is a LocalizedStringKey, read as Markdown: bold, italic, code and links. Text(verbatim:) shows the characters as they are."
        ) { TextMarkdownStory() },
        Story(
            "text.format", "Formatted values", apis: ["Text(_:format:)", "FormatStyle", "Text(\"\\(Image)\")"],
            summary: "A value shown through a FormatStyle of your own, and an image inline in a line of text."
        ) { TextFormatStory() },
        Story(
            "text.lines", "Lines and alignment", apis: [".lineLimit(_:)", ".multilineTextAlignment(_:)", ".truncationMode(_:)", ".fixedSize(horizontal:vertical:)"],
            summary: "How a long string wraps: limited to a number of lines, truncated at its head, middle or tail, aligned within its frame."
        ) { TextLinesStory() },
        Story(
            "text.label", "Label", apis: ["Label(_:systemImage:)", ".labelStyle(_:)", ".titleAndIcon", ".iconOnly", ".titleOnly"],
            summary: "A title with an icon, shown whole, as its icon or as its title. Lists, menus and toolbars choose a style for the labels in them."
        ) { LabelStory() },
    ])
}

// story: text.styles
struct TextStylesStory: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Large Title").font(.largeTitle)
            Text("Title").font(.title)
            Text("Title 2").font(.title2)
            Text("Title 3").font(.title3)
            Text("Headline").font(.headline)
            Text("Body").font(.body)
            Text("Callout").font(.callout)
            Text("Subheadline").font(.subheadline)
            Text("Footnote").font(.footnote)
            Text("Caption").font(.caption)
            Text("Caption 2").font(.caption2)
        }
    }
}
// end story

// story: text.weights
struct TextWeightsStory: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Light").fontWeight(.light)
                Text("Regular")
                Text("Semibold").fontWeight(.semibold)
                Text("Bold").bold()
                Text("Heavy").fontWeight(.heavy)
            }
            Text("Italic, and bold italic").italic()
            Text("Rounded").font(.system(size: 22, weight: .medium, design: .rounded))
            Text("Serif").font(.system(size: 22, weight: .regular, design: .serif))
            Text("Monospaced 0123").font(.system(size: 18, design: .monospaced))
            Text("let x = 42").monospaced()
        }
    }
}
// end story

// story: text.decoration
struct TextDecorationStory: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Underlined").underline()
            Text("Underlined in red").underline(color: .red)
            Text("Struck through").strikethrough()
            Text("Orange text").foregroundStyle(.orange)
            Text("Secondary text").foregroundColor(.secondary)
            Text("A \(Text("bold").bold()) word and an \(Text("orange").foregroundColor(.orange)) one, interpolated into one paragraph that wraps as prose does.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
// end story

// story: text.markdown
struct TextMarkdownStory: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("**Bold**, *italic*, ~~struck~~ and `code`.")
            Text("A link to [Swift.org](https://swift.org).")
            Text(verbatim: "Verbatim: **not bold**")
        }
    }
}
// end story

// story: text.format
struct TextFormatStory: View {
    struct Temperature: FormatStyle {
        func format(_ celsius: Double) -> String {
            "\(Int(celsius.rounded()))°C / \(Int((celsius * 9 / 5 + 32).rounded()))°F"
        }
    }

    struct Duration: FormatStyle {
        func format(_ seconds: Int) -> String {
            seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(21.6, format: Temperature())
            Text(-4.2, format: Temperature())
            Text(135, format: Duration())
            Text("Rated \(Image(systemName: "star.fill")) 4.8")
        }
    }
}
// end story

// story: text.lines
struct TextLinesStory: View {
    private let long = "SwiftUI describes an interface as a function of its state; Isomer draws the same description with each platform's own components."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(long)
                .lineLimit(1)
            Text(long)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(long)
                .lineLimit(2)
            Text(long)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            Text(long)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
// end story

// story: text.label
struct LabelStory: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Favorites", systemImage: "star")
            Label("Downloads", systemImage: "arrow.down.circle")
                .labelStyle(.titleAndIcon)
            Label("Settings", systemImage: "gearshape")
                .labelStyle(.iconOnly)
            Label("Title only", systemImage: "eye.slash")
                .labelStyle(.titleOnly)
            Label("Large", systemImage: "folder")
                .font(.title2)
        }
    }
}
// end story
