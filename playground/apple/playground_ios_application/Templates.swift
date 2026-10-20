// Project templates: a blank starter, or any of the bundled example apps —
// the SAME sources the example apps ship, assembled into single-file
// projects at build time (BUILD: playground_sample). New installs seed one
// project per example; a deleted example can be recreated from the picker.

import Foundation

struct ProjectTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    /// The bundled samples/<resource>.swift; nil = the blank starter.
    let resource: String?

    static let blank = ProjectTemplate(
        id: "blank", name: "Blank", subtitle: "An App and a ContentView to start from", resource: nil)

    /// The bundled examples, in the order they seed (the last created sorts
    /// first and opens on first launch).
    static let examples: [ProjectTemplate] = [
        ProjectTemplate(id: "counter", name: "Counter", subtitle: "The smallest example", resource: "Counter"),
        ProjectTemplate(id: "game2048", name: "2048", subtitle: "Swipe to merge tiles", resource: "Game2048"),
        ProjectTemplate(id: "meme", name: "Meme Creator", subtitle: "Caption a photo", resource: "MemeCreator"),
        ProjectTemplate(id: "wikipedia", name: "Wikipedia", subtitle: "Browse & search articles", resource: "Wikipedia"),
        ProjectTemplate(id: "hackernews", name: "Hacker News", subtitle: "Top stories & comments", resource: "HackerNews"),
        ProjectTemplate(id: "pokedex", name: "Pokédex", subtitle: "Catalog every Pokémon", resource: "Pokedex"),
    ]

    static let all: [ProjectTemplate] = [blank] + examples

    /// The template's App.swift.
    var source: String {
        guard let resource,
              let url = Bundle.main.url(forResource: resource, withExtension: "swift", subdirectory: "samples")
                ?? Bundle.main.url(forResource: resource, withExtension: "swift"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return Self.blankSource
        }
        return text
    }

    static let blankSource = """
    import SwiftUI

    @main
    struct PlaygroundApp: App {
        var body: some Scene {
            WindowGroup { ContentView() }
        }
    }

    struct ContentView: View {
        var body: some View {
            Text("Hello, world!")
                .padding()
        }
    }
    """
}
