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
            // The app's own pictures, kept as the run's attachments (an
            // XCTest run's result bundle carries them home).
            HeadlessApp.onPicture = { id, png in
                print("[picture] \(id): \(png.count) bytes")
                Attachment.record(png, named: id.replacingOccurrences(of: "/", with: "~") + ".png")
            }
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

    /// A view's state lasts as long as the view (state.lifetime). Each of
    /// the story's counters is tapped to 1, its view is taken away and
    /// brought back (by an if, a new id, a ForEach's items, its sheet), and
    /// its count read again; one is left alone. Apple's SwiftUI is the
    /// reference: every renderer gives the counts SwiftUI gives.
    @Test func stateLastsAsLongAsItsView() throws {
        let app = try launch(story: "state.lifetime")
        defer { app.quit() }
        var seen: [(scenario: String, swiftUI: Int, count: Int)] = []
        /// A counter's count as the screen shows it: its button's label
        /// (Apple's accessibility lists a button by its label, not as a
        /// text), or a text; -1 when it isn't there.
        func shown(_ name: String, on screen: HeadlessScreen) -> Int {
            (0...3).first { n in
                screen.elements.contains { $0.label == "\(name): \(n)" } || screen.shows("\(name): \(n)")
            } ?? -1
        }
        /// Taps `name`'s counter to 1, makes `change`, and reads its count.
        func count(_ name: String, after change: () throws -> Void) throws -> Int {
            try app.tap("\(name): 0")
            try app.wait(for: "\(name): 1")
            try change()
            return shown(name, on: try app.screen())
        }
        try app.tap("Stays: 0")
        try app.wait(for: "Stays: 1")
        seen.append(("an if's branch swapped away and back", 0, try count("Branch") {
            try app.tap("Swap the branch")
            try app.tap("Swap the branch")
        }))
        seen.append(("an if's other branch, the same type", 0, try count("Either branch") {
            try app.tap("Swap the counters")
        }))
        seen.append(("a new id", 0, try count("Identified") {
            try app.tap("Give it a new id")
        }))
        seen.append(("a ForEach item removed and added again", 0, try count("Item 2") {
            try app.tap("Remove item 2")
            try app.tap("Add item 2")
        }))
        try app.tap("Show the sheet")
        seen.append(("its sheet closed and shown again", 0, try count("In the sheet") {
            try app.tap("Close the sheet")
            try app.tap("Show the sheet")
        }))
        try app.tap("Close the sheet")
        seen.append(("a view left alone", 1, shown("Stays", on: try app.screen())))
        for (scenario, swiftUI, count) in seen {
            print("[state.lifetime] \(scenario): \(count) (SwiftUI's: \(swiftUI))")
            #expect(count == swiftUI, "\(scenario): \(count), SwiftUI's \(swiftUI)")
        }
    }

    /// A TabView's tabs are buttons named by their titles, as the system's
    /// tab bar lists them: a tap on one shows its content (navigation.tabs).
    @Test func tabsAreSelectedByTheirTitles() throws {
        let app = try launch(story: "navigation.tabs")
        defer { app.quit() }
        #expect(try app.screen().texts.contains("Home"))
        let screen = try app.tap("Profile")
        #expect(screen.texts.contains("Profile"), "the Profile tab's content shows: \(screen.texts)")
        #expect(!screen.texts.contains("Home"), "the Home tab's content is gone: \(screen.texts)")
    }

    /// A trip to the background and back (`scene`): the app comes back as
    /// it was, still driven, whichever way its platform moves it (Android's
    /// launcher sends it home and brings it back; iOS tells SwiftUI's scene
    /// delegate; the Mac hides it; Isomer's own runtimes set the phase).
    @Test func comesBackFromTheBackground() throws {
        let app = try launch(story: "state.observableobject")
        defer { app.quit() }
        try app.tap("Tap")
        try app.wait(for: "Taps: 1")
        try app.scene(.background)
        try app.scene(.active)
        try app.tap("Tap")
        try app.wait(for: "Taps: 2")
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
        try app.tap("Pin")
        try app.wait(for: "Chose: Pin")
        // A menu whose items are a view of the app's own.
        try app.tap("Sort")
        let screen = try app.tap("By date")
        #expect(screen.shows("Chose: By date"))
    }

    /// `.searchable`'s field, by its prompt.
    @Test func searchFieldFilters() throws {
        let app = try launch(story: "lists.search")
        defer { app.quit() }
        // A city is a text of its own (the story's code names them too);
        // Berlin is on screen on a phone as well (the list shows its rows).
        #expect(try app.screen().texts.contains("Berlin"))
        let screen = try app.type("Search cities", "lis")
        #expect(screen.texts.contains("Lisbon"))
        #expect(!screen.texts.contains("Berlin"))
    }

    /// The navigation bar's items, an icon item by its Label's title.
    @Test func toolbarItemsTap() throws {
        let app = try launch(story: "navigation.toolbar")
        defer { app.quit() }
        try app.tap("Add")
        try app.tap("Add")
        try app.wait(for: "Added 2, last tapped: add")
        // By its accessibility identifier.
        let screen = try app.tap("settings")
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

    /// A story opened at launch (ISO_STORYBOOK_STORY: the split view starts
    /// on its detail column, `preferredCompactColumn` .detail, the list's
    /// selection set before the first frame) goes back as one picked from
    /// the list does: to the list, not to the detail's placeholder under the
    /// story's title.
    @Test func aStoryOpenedAtLaunchGoesBackToTheList() throws {
        let app = try launch(story: "state.observableobject")
        defer { app.quit() }
        // (At regular width the split view shows both columns: nothing to check.)
        guard try app.info().width < 700 else { return }
        var screen = try app.screen()
        #expect(screen.shows("Taps: 0"))
        #expect(screen.element("Text styles") == nil)
        screen = try app.back()
        // The list, by its title, which only the sidebar shows (its rows are
        // where its scroll is, which differs: Apple's own list comes back at
        // its top after a launch, at the story's row after one opened
        // in-process) …
        #expect(screen.texts.contains("Storybook"), "texts: \(screen.texts.prefix(12))")
        // … and nothing of the detail: neither the story nor the
        // placeholder a detail with no story shows.
        #expect(!screen.shows("Pick a story"), "texts: \(screen.texts.prefix(12))")
        #expect(screen.element("Reset") == nil)
    }

    /// A split view's columns' navigation titles are texts on the screen
    /// (the sidebar's "Storybook"; the opened story's, and its row too where
    /// the list stands beside it), as the system's bar shows them.
    @Test func navigationTitlesAreTexts() throws {
        let app = try launch()
        defer { app.quit() }
        // A Mac shows a split view's titles in its window's toolbar, which
        // the Mac's driver doesn't read (the window's own accessibility):
        // the bars in the window are the other platforms'.
        guard try app.info().platform != "macOS" else { return }
        #expect(try app.screen().texts.contains("Storybook"))
        let screen = try app.tap("ObservableObject")
        let wide = try app.info().width >= 700
        #expect(screen.texts.filter { $0 == "ObservableObject" }.count >= (wide ? 2 : 1),
                "wide: \(wide), texts: \(screen.texts.prefix(12))")
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

    /// A long press opens a row's context menu: its items are the screen's
    /// buttons until one is tapped.
    @Test func aLongPressOpensTheContextMenu() throws {
        let app = try launch(story: "lists.actions")
        defer { app.quit() }
        // Apple's driver reads the accessibility tree, which offers no long
        // press it can use in process (drive/apple): Isomer's apps alone.
        guard try app.info().renderer != "SwiftUI" else { return }
        var screen = try app.longPress("Weekly report")
        #expect(screen.elements.map(\.label) == ["Flag", "Delete"], "\(screen.elements)")
        // (A row's subject is a text of its own: the story's code names
        // them too, in its listing.)
        #expect(!screen.texts.contains("Lunch on Friday?"), "an open menu is all there is")
        // Closed again, nothing chosen.
        screen = try app.dismiss()
        #expect(screen.texts.contains("Weekly report"))
        try app.longPress("Weekly report")
        screen = try app.tap("Delete")
        #expect(!screen.texts.contains("Weekly report"), "\(screen.texts)")
        #expect(screen.texts.contains("Lunch on Friday?"))
    }

    /// A swipe on a row reveals its swipe actions as buttons (left: the
    /// trailing ones, `.onDelete`'s Delete; right: the leading Flag), or
    /// performs the one it names.
    @Test func aSwipeRevealsARowsActions() throws {
        let app = try launch(story: "lists.actions")
        defer { app.quit() }
        guard try app.info().renderer != "SwiftUI" else { return }
        let before = try app.screen()
        var screen = try app.swipe("Lunch on Friday?", "right")
        #expect(screen.elements.contains { $0.role == "button" && $0.label == "Flag" }, "\(screen.elements)")
        screen = try app.tap("Flag")
        // Flagged: the flag's symbol beside its subject, a text more.
        #expect(screen.texts.count == before.texts.count + 1, "\(screen.texts)")
        // (By its label exactly: the story's code, an element of its own by
        // its identifier, holds the word.)
        #expect(!screen.elements.contains { $0.role == "button" && $0.label == "Flag" },
                "the actions close once one is tapped")
        screen = try app.swipe("Your order has shipped", "left", action: "Delete")
        #expect(!screen.texts.contains("Your order has shipped"), "\(screen.texts)")
        #expect(throws: (any Error).self) { try app.swipe("Weekly report", "left", action: "Archive") }
    }

    /// A headful launch starts with none of the app's data from before (the
    /// launchers' ISOMER_FRESH, HeadlessApp's default), as an app built
    /// headless does; asked to, it keeps it.
    @Test func aLaunchStartsFreshUnlessAskedToKeep() throws {
        // (Hosted in the iPhone app, there is no launcher to start one.)
        #if !(os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
        let environment = ProcessInfo.processInfo.environment
        guard let launcher = environment["ISOMER_HEADFUL_LAUNCHER"], !launcher.isEmpty,
              HeadlessApp.hostedIfAny() == nil else { return }
        let story = ["ISO_STORYBOOK_STORY": "state.appstorage"]
        var platform = ""
        do {
            let app = try HeadlessApp(launcher: launcher, environment: story)
            defer { app.quit() }
            platform = try app.info().platform
            // Windows' launcher keeps an app's data as it is, for now.
            guard platform != "Windows" else { return }
            try app.wait(for: "Starred 0 times")
            try app.tap("Star")
            try app.wait(for: "Starred 1 times")
        }
        // Kept where the platform's app keeps its defaults between launches
        // for sure: not a web page (a browser profile of its own each
        // launch), nor Linux's app (corelibs' UserDefaults, which a launcher
        // stopping the app with SIGTERM gives no time to write).
        if ["iOS", "Android", "macOS"].contains(platform) {
            let app = try HeadlessApp(launcher: launcher, environment: story, fresh: false)
            defer { app.quit() }
            try app.wait(for: "Starred 1 times")
        }
        let app = try HeadlessApp(launcher: launcher, environment: story)
        defer { app.quit() }
        try app.wait(for: "Starred 0 times")
        #endif
    }

    @Test func unknownTargetFailsWithTheScreen() throws {
        let app = try launch(story: "state.observableobject")
        defer { app.quit() }
        let error = try #require(throws: (any Error).self) { try app.tap("No such button") }
        #expect("\(error)".contains("no button No such button"))
    }
}
