// The Storybook's model: stories (one API, or a few that go together), each
// shown three ways on its page: its code, what it does, and the code running
// on this platform; grouped into areas (Text, Controls, Layout…), the
// sidebar's sections.
//
// A story's view is written once, in stories/<Area>.swift, between a
// `// story: <id>` line and an `// end story` line; the build copies that
// source into the snippet table (BUILD.bazel's :snippets), so the code a
// page shows is the code it runs.

import SwiftUI

/// One story: its id (`area.name`), title, what it says about its APIs,
/// and its view.
public struct Story: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let summary: String
    /// A fixed height for the result (a story that fills its space: a split
    /// view, a map), else its own.
    let height: Double?
    let make: @MainActor () -> AnyView

    init<V: View>(
        _ id: String, _ title: String, height: Double? = nil, summary: String,
        @ViewBuilder view: @escaping @MainActor () -> V
    ) {
        self.id = id
        self.title = title
        self.height = height
        self.summary = summary
        self.make = { AnyView(view()) }
    }

    /// Its source, as the build copied it.
    public var code: String { storySnippets[id] ?? "" }

    public static func == (a: Story, b: Story) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A sidebar section of stories.
public struct StoryArea: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let symbol: String
    public let stories: [Story]
}

/// Every area, in the sidebar's order.
@MainActor
public enum StoryCatalog {
    public static let areas: [StoryArea] = [
        text, images, buttons, controls, textInput, lists, layout, scrolling,
        navigation, presentation, shapes, animation, gestures, state, isomer,
    ]

    public static var stories: [Story] { areas.flatMap(\.stories) }

    public static func story(_ id: String) -> Story? {
        stories.first { $0.id == id }
    }

    public static func area(of story: Story) -> StoryArea? {
        areas.first { $0.stories.contains(story) }
    }
}
