// The Storybook driven headless: its UI read and its controls used through
// the runtime (IsomerHeadless), nothing drawn. Each test launches the app
// on a story (ISO_STORYBOOK_STORY) and works it as a person would.
//
// The same tests drive a headful Storybook when ISOMER_HEADFUL_LAUNCHER
// names a launcher (IsomerHeadless's `HeadlessApp(launcher:environment:)`):
// the app drawn by its platform's renderer, its driver built in
// (--@isomer//drive:headful), dialling out to the test's hub. The web's is
// web_launcher.sh (:storybook_headful_web_test).

import IsomerHeadless
import IsomerWire
import XCTest

final class StorybookHeadlessTests: XCTestCase {
    /// The app built headless, from the test's runfiles; or headful, started
    /// by the launcher the environment names.
    private func launch(story: String? = nil) throws -> HeadlessApp {
        let environment = ProcessInfo.processInfo.environment
        var launchEnvironment: [String: String] = [:]
        if let story { launchEnvironment["ISO_STORYBOOK_STORY"] = story }
        if let launcher = environment["ISOMER_HEADFUL_LAUNCHER"], !launcher.isEmpty {
            return try HeadlessApp(launcher: launcher, environment: launchEnvironment)
        }
        #if os(Windows)
        // Windows runs these headful alone (HeadlessApp starts no headless
        // app there: no process transport).
        throw XCTSkip("ISOMER_HEADFUL_LAUNCHER names no launcher")
        #else
        let root = "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "_main")"
        return try HeadlessApp(
            executable: "\(root)/headless/storybook_headless_application/storybook_headless_application",
            environment: launchEnvironment)
        #endif
    }

    func testObservableObjectCounts() throws {
        let app = try launch(story: "state.observableobject")
        defer { app.quit() }
        XCTAssertTrue(try app.screen().shows("Taps: 0"))
        // The story's code is one element: one text of many lines.
        XCTAssertTrue(try app.screen().texts.contains { $0.hasPrefix("final class StoryCounter") && $0.contains("\n") })
        try app.tap("Tap")
        try app.tap("Tap")
        try app.wait(for: "Taps: 2")
        // Reset sends on the model's subject: onReceive counts it.
        let screen = try app.tap("Reset")
        XCTAssertTrue(screen.shows("Taps: 0"))
        XCTAssertTrue(screen.shows("Reset 1 times"))
        // The proof's picture of it, headful (headless: none).
        try app.picture("state.observableobject")
    }

    func testTextFieldBindsTheModel() throws {
        let app = try launch(story: "state.observableobject")
        defer { app.quit() }
        XCTAssertEqual(try app.screen().element("Title")?.value, "Taps")
        let screen = try app.type("Title", "Hits")
        XCTAssertTrue(screen.shows("Hits: 0"))
    }

    func testToggles() throws {
        let app = try launch(story: "controls.toggle")
        defer { app.quit() }
        XCTAssertTrue(try app.screen().shows("Wi-Fi on, Bluetooth off"))
        try app.set("Wi-Fi", "0")
        let screen = try app.set("Bluetooth", "1")
        XCTAssertTrue(screen.shows("Wi-Fi off, Bluetooth on"))
    }

    func testSheetPresentsAndDismisses() throws {
        let app = try launch(story: "presentation.sheet")
        defer { app.quit() }
        var screen = try app.tap("Show sheet")
        XCTAssertEqual(screen.presented.first?.style, "sheet")
        XCTAssertTrue(screen.shows("A sheet"))
        screen = try app.tap("Done")
        XCTAssertTrue(screen.presented.isEmpty)
    }

    func testOpensAStoryFromTheList() throws {
        let app = try launch()
        defer { app.quit() }
        let screen = try app.tap("ObservableObject")
        XCTAssertTrue(screen.shows("Taps: 0"))
    }

    func testAStoryReplacesTheListAndBackReturns() throws {
        let app = try launch()
        defer { app.quit() }
        // A compact width's: at regular width (a Mac's window) the list and
        // the story stand side by side.
        try XCTSkipIf(try app.info().width >= 700, "the split view shows both columns at this width")
        // At compact width the split view shows one column: the story alone.
        var screen = try app.tap("ObservableObject")
        XCTAssertTrue(screen.shows("Taps: 0"))
        XCTAssertNil(screen.element("Text styles"))
        screen = try app.back()
        // The list again, at the row it opened (a phone keeps the list where
        // it was scrolled).
        XCTAssertNotNil(screen.element("ObservableObject"))
        XCTAssertNil(screen.element("Reset"))
    }

    func testNamesTargetElementsAndInspectTellsMore() throws {
        let app = try launch(story: "state.observableobject")
        defer { app.quit() }
        // Each element has a name: its role and its place among that role's.
        let tap = try XCTUnwrap(app.screen().element("Tap"))
        XCTAssertTrue(tap.name.hasPrefix("button-"))
        try app.tap(tap.name)
        let screen = try app.wait(for: "Taps: 1")
        // A text by its place among the texts (text-<n>).
        let index = try XCTUnwrap(screen.texts.firstIndex(of: "Taps: 1"))
        let text = try app.inspect("text-\(index + 1)")
        XCTAssertEqual(text.role, "text")
        XCTAssertEqual(text.label, "Taps: 1")
        let field = try app.inspect("Title")
        XCTAssertEqual(field.role, "textField")
        XCTAssertTrue(field.actions.contains("edit"))
        XCTAssertThrowsError(try app.inspect("button-999"))
    }

    func testAnAlertIsTheWholeScreen() throws {
        let app = try launch(story: "presentation.alert")
        defer { app.quit() }
        var screen = try app.tap("Delete draft…")
        // What is presented is all that can be used: the page behind is not
        // listed.
        XCTAssertEqual(screen.presented.last?.style, "alert")
        XCTAssertNotNil(screen.element("Delete"))
        XCTAssertNotNil(screen.element("Cancel"))
        XCTAssertNil(screen.element("Delete draft…"))
        screen = try app.tap("Cancel")
        XCTAssertTrue(screen.presented.isEmpty)
        XCTAssertNotNil(screen.element("Delete draft…"))
    }

    func testUnknownTargetFailsWithTheScreen() throws {
        let app = try launch(story: "state.observableobject")
        defer { app.quit() }
        XCTAssertThrowsError(try app.tap("No such button")) { error in
            XCTAssertTrue("\(error)".contains("no button No such button"))
        }
    }
}
