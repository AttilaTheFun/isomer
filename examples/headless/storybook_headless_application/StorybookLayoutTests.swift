// The Storybook's layout as the headless head lays it out (its
// IsomerLayoutServer: HeadlessApp.layout()), where each view stands in the
// window. Headless alone: a headful app's driver stays frameless, and its
// layout is its platform's.

import Foundation
import IsomerHeadless
import Testing

@Suite(.serialized)
struct StorybookLayoutTests {
    private func launch(story: String) throws -> HeadlessApp {
        let environment = ProcessInfo.processInfo.environment
        let root = "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "_main")"
        return try HeadlessApp(
            executable: "\(root)/headless/storybook_headless_application/storybook_headless_application",
            environment: ["ISO_STORYBOOK_STORY": story])
    }

    @Test func viewsStandInTheWindow() throws {
        let app = try launch(story: "state.observableobject")
        defer { app.quit() }
        _ = try app.wait(for: "Taps: 0")
        let layout = try app.layout()
        #expect(layout.width == 390 && layout.height == 844)
        let tap = try #require(layout.frame(of: "Tap", kind: "button"))
        let count = try #require(layout.frame(of: "Taps: 0", kind: "text"))
        let title = try #require(layout.item("Title", kind: "textField"))
        // Each has a size and lies within the window's width.
        for frame in [tap, count, title.frame] {
            #expect(frame.width > 0 && frame.height > 0)
            #expect(frame.minX >= 0 && frame.maxX <= layout.width)
        }
        // The story's order: the count, its field, then its buttons.
        #expect(count.maxY <= title.frame.minY)
        #expect(title.frame.maxY <= tap.minY)
        // The layout follows the app: tapped, the count reads on.
        _ = try app.tap("Tap")
        _ = try app.wait(for: "Taps: 1")
        #expect(try app.layout().frame(of: "Taps: 1", kind: "text") != nil)
    }

    @Test func aSheetIsALayerAbove() throws {
        let app = try launch(story: "presentation.sheet")
        defer { app.quit() }
        _ = try app.tap("Show sheet")
        let layout = try app.layout()
        let done = try #require(layout.item("Done", kind: "button"))
        #expect(done.layer >= 1)
        #expect(done.frame.width > 0 && done.frame.maxY <= layout.height)
    }
}
