// The Storybook's screens: the stories in a sidebar by area, and a story's
// page beside it (its code, what it does, the code running). Visor's
// two-column shape: a phone shows one column at a time, the sidebar first.
//
// Launch hook (the process environment natively, a reactor's WASI
// environment, an Android intent's ISO_ extras, the web page's ISO_ query):
// ISO_STORYBOOK_STORY=<id> opens that story (the proof's way to each page).

import SwiftUI
#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(ucrt)
import ucrt
#endif

/// A launch-environment variable: the process environment natively, the
/// WASI environment in a reactor.
func launchEnvironment(_ name: String) -> String? {
    guard let value = getenv(name) else { return nil }
    let text = String(cString: value)
    return text.isEmpty ? nil : text
}

/// The Storybook: every story, by area.
public struct StorybookView: View {
    @State private var selection: String?
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @Environment(\.horizontalSizeClass) private var sizeClass

    public init() {
        if let id = launchEnvironment("ISO_STORYBOOK_STORY"), StoryCatalog.story(id) != nil {
            _selection = State(initialValue: id)
            _compactColumn = State(initialValue: .detail)
        }
    }

    private var compact: Bool { sizeClass == .compact }

    public var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            List(selection: $selection) {
                ForEach(StoryCatalog.areas) { area in
                    Section(area.title) {
                        ForEach(area.stories) { story in
                            Text(story.title)
                                .tag(story.id)
                                .accessibilityIdentifier("story-\(story.id)")
                        }
                    }
                }
            }
            .navigationTitle("Storybook")
        } detail: {
            // The page has its own stack: a story may push a screen.
            NavigationStack {
                if let id = selection, let story = StoryCatalog.story(id) {
                    StoryPage(story: story)
                } else {
                    VStack {
                        Spacer()
                        Text("Pick a story").font(.headline).foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .id(selection)
        }
        .onAppear { openFirstStoryIfWide() }
        .onChange(of: sizeClass) { openFirstStoryIfWide() }
        .onChange(of: selection) { _, value in
            // A phone shows the story picked, and the sidebar again when none is.
            if compact { compactColumn = value == nil ? .sidebar : .detail }
        }
    }

    /// Wide, the first story is open beside the sidebar; a phone stays on
    /// the sidebar until a story is picked.
    private func openFirstStoryIfWide() {
        guard !compact, selection == nil, let first = StoryCatalog.stories.first else { return }
        selection = first.id
    }
}

/// A story's page: its code, what it does and the APIs it shows, and the
/// code running.
struct StoryPage: View {
    let story: Story

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CodeCard(code: story.code)
                VStack(alignment: .leading, spacing: 6) {
                    Text(story.summary)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(story.apis.joined(separator: "  ·  "))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Result")
                    .font(.headline)
                    .accessibilityIdentifier("story-result")
                result
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(story.title)
    }

    @ViewBuilder
    private var result: some View {
        if let height = story.height {
            story.make().frame(maxWidth: .infinity, maxHeight: .infinity).frame(height: height)
        } else {
            story.make()
        }
    }
}

/// A story's source in a monospaced card: its first lines, with the rest a
/// tap away, so the result stays on screen beside it.
struct CodeCard: View {
    let code: String
    @State private var expanded = false
    private static let compactLines = 12

    var body: some View {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        let clipped = !expanded && lines.count > Self.compactLines
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                Text(clipped ? lines.prefix(Self.compactLines).joined(separator: "\n") : code)
                    .font(.system(size: 12, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
            if clipped {
                Button("Show all \(lines.count) lines") { expanded = true }
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12)))
        .accessibilityIdentifier("story-code")
    }
}
