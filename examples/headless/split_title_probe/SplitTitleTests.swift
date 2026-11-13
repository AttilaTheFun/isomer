// The detail column's navigation title among the screen's texts, in a split
// view shaped as an app's dashboard (SplitTitleProbe.swift): collapsed (a
// phone's width, the detail alone once a row is picked) and side by side.

import Foundation
import IsomerHeadless
import Testing

@Suite(.serialized)
struct SplitTitleTests {
    private func launch(width: Int) throws -> HeadlessApp {
        let environment = ProcessInfo.processInfo.environment
        let root = "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "_main")"
        return try HeadlessApp(executable: "\(root)/headless/split_title_probe/split_title_probe",
                               environment: ["ISO_HEADLESS_WIDTH": String(width)])
    }

    @Test(arguments: [390, 1024])
    func detailTitleIsAText(width: Int) throws {
        let app = try launch(width: width)
        defer { app.quit() }
        _ = try app.wait(for: "Mac Studio")
        _ = try app.tap("Mac Studio")
        let screen = try app.wait(for: "What's running")
        // The title, and the row beside it when the list stays on screen.
        #expect(screen.texts.filter { $0 == "Mac Studio" }.count == (width >= 700 ? 2 : 1),
                "texts: \(screen.texts)")
    }
}
