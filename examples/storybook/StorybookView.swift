// The Storybook's screens: the stories in a sidebar by area, and a story's
// page beside it (its code, what it does, the code running). Visor's
// two-column shape: a phone shows one column at a time, the sidebar first.
//
// Launch hooks (the process environment natively, a reactor's WASI
// environment, an Android intent's ISO_ extras, the web page's ISO_ query):
// ISO_STORYBOOK_STORY=<id> opens that story; ISO_STORYBOOK_CONTROL=<file>
// opens whichever story the file names ("stories": the list, as at
// launch), read four times a second, and
// writes `<file>.shown` with the story once it is open; and the URL
// iso://story/<id> opens one too (Android's VIEW intents): the proof's ways
// through every page without a launch each.

import Foundation
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
        .task { await followControl() }
        .task { await followOpenRequests() }
        .onOpenURL { url in
            let id = url.path.split(separator: "/").last.map(String.init) ?? ""
            if url.host == "story" { open(id) }
        }
        .onChange(of: selection) { _, value in
            // A phone shows the story picked, and the sidebar again when none is.
            if compact { compactColumn = value == nil ? .sidebar : .detail }
        }
    }

    /// ISO_STORYBOOK_CONTROL: the story its file names, opened as it
    /// changes; `<file>.shown` names it once its page has had a moment to
    /// build.
    private func followControl() async {
        guard let path = launchEnvironment("ISO_STORYBOOK_CONTROL") else { return }
        var shown: String?
        while !Task.isCancelled {
            let named = (try? String(contentsOfFile: path, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = named, id != shown, id == "stories" || StoryCatalog.story(id) != nil {
                shown = id
                show(id)
                try? await Task.sleep(for: .milliseconds(300))
                // Atomically where it can be; Wine's file replacement fails
                // on its Unix drive, so plainly there (whoever reads it
                // reads until it names the story).
                if (try? id.write(toFile: path + ".shown", atomically: true, encoding: .utf8)) == nil {
                    try? id.write(toFile: path + ".shown", atomically: false, encoding: .utf8)
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// A test hosted in the app (HeadlessApp.hosted) opens a story the
    /// same way, in-process: it posts `storybookOpenStory` with the story's
    /// id ("stories": the list, as at launch), and is told by
    /// `storybookShownStory` once the page has had a moment to build. Its
    /// own environment it can't set, so not the control file.
    private func followOpenRequests() async {
        let token = NotificationCenter.default.addObserver(forName: storybookOpenStory, object: nil, queue: .main) { note in
            guard let id = note.object as? String else { return }
            MainActor.assumeIsolated { show(id) }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                NotificationCenter.default.post(name: storybookShownStory, object: id)
            }
        }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        NotificationCenter.default.removeObserver(token)
    }

    /// The list (as at launch) or a story.
    private func show(_ id: String) {
        if id == "stories" {
            selection = nil
            openFirstStoryIfWide()
        } else {
            open(id)
        }
    }

    private func open(_ id: String) {
        guard StoryCatalog.story(id) != nil else { return }
        selection = id
        compactColumn = .detail
    }

    /// Wide, the first story is open beside the sidebar; a phone stays on
    /// the sidebar until a story is picked.
    private func openFirstStoryIfWide() {
        guard !compact, selection == nil, let first = StoryCatalog.stories.first else { return }
        selection = first.id
    }
}

/// What a test hosted in the app posts to open a story, and is told back
/// (StorybookView's followOpenRequests).
let storybookOpenStory = Notification.Name("IsomerStorybookOpenStory")
let storybookShownStory = Notification.Name("IsomerStorybookShownStory")

/// A story's page: its code, what it does, and the code running.
struct StoryPage: View {
    let story: Story

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CodeCard(code: story.code)
                Text(story.summary)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
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

/// A story's source in a monospaced card, coloured as the Playground's
/// editor colours it.
struct CodeCard: View {
    let code: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.horizontal) {
            SwiftHighlighter.text(code, dark: colorScheme == .dark)
            .font(.system(size: 12, design: .monospaced))
            .fixedSize(horizontal: true, vertical: true)
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12)))
        .accessibilityIdentifier("story-code")
    }
}
