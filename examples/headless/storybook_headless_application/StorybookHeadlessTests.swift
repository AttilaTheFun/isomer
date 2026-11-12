// The Storybook driven headless: its UI read and its controls used through
// the runtime (IsomerHeadless), nothing drawn. Each test launches the app
// on a story (ISO_STORYBOOK_STORY) and works it as a person would.
//
// The same tests drive a headful Storybook when ISOMER_HEADFUL_LAUNCHER
// names a launcher (IsomerHeadless's `HeadlessApp(launcher:environment:)`):
// the app drawn by its platform's renderer, its driver built in
// (--@isomer//drive:headful), dialling out to the test's hub. The web's is
// web_launcher.sh (:storybook_headful_web_test).
//
// Swift Testing's: a swift_test runs them on macOS, Linux and Windows, and an
// iPhone's test bundle hosts them. One at a time: a headful test drives the
// one app its launcher started. Off the main thread, as Swift Testing runs
// them: a hosted test's app works on its main thread meanwhile.

import Foundation
import IsomerHeadless
import IsomerWire
import Testing

/// Whether there's an app to drive: on a phone, the one this bundle is
/// hosted in (with a driver); on Windows, one a launcher starts; anywhere
/// else, the Storybook built headless if no launcher is named.
func storybookToDrive() -> Bool {
    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    return HeadlessApp.hostedIfAny() != nil
    #elseif os(Windows)
    return !(ProcessInfo.processInfo.environment["ISOMER_HEADFUL_LAUNCHER"] ?? "").isEmpty
    #else
    return true
    #endif
}

@Suite(.serialized, .enabled("an app to drive here") { storybookToDrive() })
struct StorybookHeadlessTests {

    /// Why a test doesn't run here (Swift Testing has no skip from inside a
    /// test: the app is launched before each test can know).
    struct NotHere: Error, CustomStringConvertible {
        let description: String
    }
    /// The app built headless, from the test's runfiles; or headful, started
    /// by the launcher the environment names; or the app this bundle is
    /// hosted in (a story opened in-process, with no launch).
    private func launch(story: String? = nil) throws -> HeadlessApp {
        let environment = ProcessInfo.processInfo.environment
        if let app = HeadlessApp.hostedIfAny() {
            // Back to the list, then the story: each test starts as at launch.
            try Self.show("stories")
            if let story { try Self.show(story) }
            return app
        }
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        // On a phone these run hosted alone: no processes to launch.
        throw NotHere(description: "not hosted in an app with a driver (--@isomer//drive:headful)")
        #else
        var launchEnvironment: [String: String] = [:]
        if let story { launchEnvironment["ISO_STORYBOOK_STORY"] = story }
        if let launcher = environment["ISOMER_HEADFUL_LAUNCHER"], !launcher.isEmpty {
            return try HeadlessApp(launcher: launcher, environment: launchEnvironment)
        }
        #if os(Windows)
        // Windows runs these headful alone (HeadlessApp starts no headless
        // app there: no process transport).
        throw NotHere(description: "ISOMER_HEADFUL_LAUNCHER names no launcher")
        #else
        let root = "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "_main")"
        return try HeadlessApp(
            executable: "\(root)/headless/storybook_headless_application/storybook_headless_application",
            environment: launchEnvironment)
        #endif
        #endif
    }

    /// Opens `story` in the app this test is hosted in, as the Storybook
    /// takes a request in-process (StorybookView's followOpenRequests): the
    /// request posted on the main queue, where the app takes it, and waited
    /// for until the Storybook says the story is shown.
    private static func show(_ story: String) throws {
        let shown = DispatchSemaphore(value: 0)
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name("IsomerStorybookShownStory"), object: nil, queue: nil
        ) { note in
            if note.object as? String == story { shown.signal() }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("IsomerStorybookOpenStory"), object: story)
        }
        guard shown.wait(timeout: .now() + 15) == .success else {
            throw NotHere(description: "the Storybook never showed \(story)")
        }
    }

    @Test func observableObjectCounts() throws {
        let app = try launch(story: "state.observableobject")
        defer { app.quit() }
        #expect(try app.screen().shows("Taps: 0"))
        // The story's code is one element: one text of many lines.
        #expect(try app.screen().texts.contains { $0.hasPrefix("final class StoryCounter") && $0.contains("\n") })
        try app.tap("Tap")
        try app.tap("Tap")
        try app.wait(for: "Taps: 2")
        // Reset sends on the model's subject: onReceive counts it.
        let screen = try app.tap("Reset")
        #expect(screen.shows("Taps: 0"))
        #expect(screen.shows("Reset 1 times"))
        // The proof's picture of it, headful (headless: none).
        try app.picture("state.observableobject")
    }

    @Test func textFieldBindsTheModel() throws {
        let app = try launch(story: "state.observableobject")
        defer { app.quit() }
        #expect(try app.screen().element("Title")?.value == "Taps")
        let screen = try app.type("Title", "Hits")
        #expect(screen.shows("Hits: 0"))
    }

    @Test func toggles() throws {
        let app = try launch(story: "controls.toggle")
        defer { app.quit() }
        #expect(try app.screen().shows("Wi-Fi on, Bluetooth off"))
        try app.set("Wi-Fi", "0")
        let screen = try app.set("Bluetooth", "1")
        #expect(screen.shows("Wi-Fi off, Bluetooth on"))
    }

    /// A Menu opens to its items, as a person's tap does; one is chosen.
    @Test func menuOpensAndChooses() throws {
        let app = try launch(story: "buttons.menu")
        defer { app.quit() }
        try app.tap("Actions")
        try app.tap("Rename")
        try app.wait(for: "Chose: Rename")
        // A Label's menu, by its title.
        try app.tap("More")
        let screen = try app.tap("Pin")
        #expect(screen.shows("Chose: Pin"))
    }

    /// `.searchable`'s field, by its prompt.
    @Test func searchFieldFilters() throws {
        let app = try launch(story: "lists.search")
        defer { app.quit() }
        #expect(try app.screen().shows("Paris"))
        let screen = try app.type("Search cities", "lis")
        #expect(screen.shows("Lisbon"))
        #expect(!screen.shows("Paris"))
    }

    /// The navigation bar's items, an icon item by its Label's title.
    @Test func toolbarItemsTap() throws {
        let app = try launch(story: "navigation.toolbar")
        defer { app.quit() }
        try app.tap("Add")
        try app.tap("Add")
        try app.wait(for: "Added 2, last tapped: add")
        let screen = try app.tap("Settings")
        #expect(screen.shows("last tapped: settings"))
    }

    @Test func sheetPresentsAndDismisses() throws {
        let app = try launch(story: "presentation.sheet")
        defer { app.quit() }
        var screen = try app.tap("Show sheet")
        #expect(screen.presented.first?.style == "sheet")
        #expect(screen.shows("A sheet"))
        screen = try app.tap("Done")
        #expect(screen.presented.isEmpty)
    }

    @Test func opensAStoryFromTheList() throws {
        let app = try launch()
        defer { app.quit() }
        let screen = try app.tap("ObservableObject")
        #expect(screen.shows("Taps: 0"))
    }

    @Test func aStoryReplacesTheListAndBackReturns() throws {
        let app = try launch()
        defer { app.quit() }
        // A compact width's: at regular width (a Mac's window) the list and
        // the story stand side by side.
        // (At regular width the split view shows both columns: nothing to check.)
        guard try app.info().width < 700 else { return }
        // At compact width the split view shows one column: the story alone.
        var screen = try app.tap("ObservableObject")
        #expect(screen.shows("Taps: 0"))
        #expect(screen.element("Text styles") == nil)
        screen = try app.back()
        // The list again, at the row it opened (a phone keeps the list where
        // it was scrolled).
        #expect(screen.element("ObservableObject") != nil)
        #expect(screen.element("Reset") == nil)
    }

    @Test func namesTargetElementsAndInspectTellsMore() throws {
        let app = try launch(story: "state.observableobject")
        defer { app.quit() }
        // Each element has a name: its role and its place among that role's.
        let tap = try #require(app.screen().element("Tap"))
        #expect(tap.name.hasPrefix("button-"))
        try app.tap(tap.name)
        let screen = try app.wait(for: "Taps: 1")
        // A text by its place among the texts (text-<n>).
        let index = try #require(screen.texts.firstIndex(of: "Taps: 1"))
        let text = try app.inspect("text-\(index + 1)")
        #expect(text.role == "text")
        #expect(text.label == "Taps: 1")
        let field = try app.inspect("Title")
        #expect(field.role == "textField")
        #expect(field.actions.contains("edit"))
        #expect(throws: (any Error).self) { try app.inspect("button-999") }
    }

    @Test func anAlertIsTheWholeScreen() throws {
        let app = try launch(story: "presentation.alert")
        defer { app.quit() }
        var screen = try app.tap("Delete draft…")
        // What is presented is all that can be used: the page behind is not
        // listed.
        #expect(screen.presented.last?.style == "alert")
        #expect(screen.element("Delete") != nil)
        #expect(screen.element("Cancel") != nil)
        #expect(screen.element("Delete draft…") == nil)
        screen = try app.tap("Cancel")
        #expect(screen.presented.isEmpty)
        #expect(screen.element("Delete draft…") != nil)
    }

    @Test func unknownTargetFailsWithTheScreen() throws {
        let app = try launch(story: "state.observableobject")
        defer { app.quit() }
        let error = try #require(throws: (any Error).self) { try app.tap("No such button") }
        #expect("\(error)".contains("no button No such button"))
    }
}
