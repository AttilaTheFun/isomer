// Buttons: styles and roles, labels, menus, links and sharing.

import Foundation
import SwiftUI

extension StoryCatalog {
    static let buttons = StoryArea(id: "buttons", title: "Buttons", symbol: "hand.tap", stories: [
        Story(
            "buttons.styles", "Button styles",
            summary: "A button in each of the built-in styles, tinted, and disabled. The styles are the platform's own buttons: filled and tonal buttons on Android, the page's on the web."
        ) { ButtonStylesStory() },
        Story(
            "buttons.labels", "Labels and roles",
            summary: "A button's label is any view: an icon, a Label, a stack. A role says what the button does; a destructive one is red."
        ) { ButtonLabelsStory() },
        Story(
            "buttons.menu", "Menu",
            summary: "A button that opens a list of actions: the platform's own pop-up menu."
        ) { MenuStory() },
        Story(
            "buttons.links", "Link and ShareLink",
            summary: "A link opens a URL in the browser; a share link hands one to the platform's share sheet."
        ) { LinksStory() },
    ])
}

// story: buttons.styles
struct ButtonStylesStory: View {
    @State private var taps = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Automatic") { taps += 1 }
            Button("Bordered") { taps += 1 }
                .buttonStyle(.bordered)
            Button("Bordered prominent") { taps += 1 }
                .buttonStyle(.borderedProminent)
            Button("Borderless") { taps += 1 }
                .buttonStyle(.borderless)
            Button("Plain") { taps += 1 }
                .buttonStyle(.plain)
            Button("Tinted green") { taps += 1 }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            Button("Disabled") { taps += 1 }
                .buttonStyle(.bordered)
                .disabled(true)
            Text("Tapped \(taps) times")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}
// end story

// story: buttons.labels
struct ButtonLabelsStory: View {
    @State private var last = "nothing yet"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Button { last = "add" } label: {
                    Image(systemName: "plus.circle.fill").font(.title)
                }
                Button { last = "favorite" } label: {
                    Label("Favorite", systemImage: "star")
                }
                .buttonStyle(.bordered)
            }
            Button { last = "send" } label: {
                HStack {
                    Image(systemName: "paperplane.fill")
                    VStack(alignment: .leading) {
                        Text("Send").bold()
                        Text("to 3 people").font(.caption)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            HStack(spacing: 12) {
                Button("Delete", role: .destructive) { last = "delete" }
                    .buttonStyle(.bordered)
                Button("Cancel", role: .cancel) { last = "cancel" }
            }
            Text("Last: \(last)")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}
// end story

// story: buttons.menu
struct MenuStory: View {
    @State private var choice = "none"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Menu("Actions") {
                Button("Duplicate") { choice = "Duplicate" }
                Button("Rename") { choice = "Rename" }
                Divider()
                Button("Delete", role: .destructive) { choice = "Delete" }
            }
            Menu {
                Button { choice = "Share" } label: { Label("Share", systemImage: "square.and.arrow.up") }
                Button { choice = "Pin" } label: { Label("Pin", systemImage: "pin") }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            Text("Chose: \(choice)")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}
// end story

// story: buttons.links
struct LinksStory: View {
    private let swift = URL(string: "https://swift.org")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Link("Swift.org", destination: swift)
            Link(destination: swift) {
                Label("The Swift Programming Language", systemImage: "safari")
            }
            ShareLink(item: swift) {
                Label("Share Swift.org", systemImage: "square.and.arrow.up")
            }
        }
    }
}
// end story
