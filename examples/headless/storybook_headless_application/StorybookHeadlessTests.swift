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
import XCTest

final class StorybookHeadlessTests: XCTestCase {
    /// The app built headless, from the test's runfiles; or headful, started
    /// by the launcher the environment names.
    private func launch(story: String? = nil) throws -> HeadlessApp {
        let environment = ProcessInfo.processInfo.environment
        var launchEnvironment = ["ISO_HEADLESS_HEIGHT": "6000"]
        if let story { launchEnvironment["ISO_STORYBOOK_STORY"] = story }
        if let launcher = environment["ISOMER_HEADFUL_LAUNCHER"], !launcher.isEmpty {
            return try HeadlessApp(launcher: launcher, environment: launchEnvironment)
        }
        let root = "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "_main")"
        return try HeadlessApp(
            executable: "\(root)/headless/storybook_headless_application/storybook_headless_application",
            environment: launchEnvironment)
    }

    func testObservableObjectCounts() throws {
        let app = try launch(story: "state.observableobject")
        defer { app.quit() }
        XCTAssertTrue(try app.screen().shows("Taps: 0"))
        try app.tap("Tap")
        try app.tap("Tap")
        try app.wait(for: "Taps: 2")
        // Reset sends on the model's subject: onReceive counts it.
        let screen = try app.tap("Reset")
        XCTAssertTrue(screen.shows("Taps: 0"))
        XCTAssertTrue(screen.shows("Reset 1 times"))
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
        // At compact width the split view shows one column: the story alone.
        var screen = try app.tap("ObservableObject")
        XCTAssertTrue(screen.shows("Taps: 0"))
        XCTAssertNil(screen.element("Text styles"))
        screen = try app.back()
        XCTAssertNotNil(screen.element("Text styles"))
        XCTAssertNil(screen.element("Reset"))
    }

    func testUnknownTargetFailsWithTheScreen() throws {
        let app = try launch(story: "state.observableobject")
        defer { app.quit() }
        XCTAssertThrowsError(try app.tap("No such button")) { error in
            XCTAssertTrue("\(error)".contains("no button No such button"))
        }
    }
}
