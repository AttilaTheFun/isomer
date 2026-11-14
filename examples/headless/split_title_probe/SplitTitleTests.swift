// The detail column's navigation title among the screen's texts, in a split
// view shaped as an app's dashboard (SplitTitleProbe.swift): collapsed (a
// phone's width, the detail alone once a row is picked) and side by side.

import Foundation
import IsomerHeadless
import Testing

@Suite(.serialized)
struct SplitTitleTests {
    private func launch(width: Int, extra: [String: String] = [:]) throws -> HeadlessApp {
        let environment = ProcessInfo.processInfo.environment
        let root = "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "_main")"
        return try HeadlessApp(executable: "\(root)/headless/split_title_probe/split_title_probe",
                               environment: ["ISO_HEADLESS_WIDTH": String(width)].merging(extra) { $1 })
    }

    /// The detail's title on the screen (with the row beside it where the
    /// list stays on screen), whatever the detail is: a bare text, the
    /// screen, an `if`, a Group with a placeholder (an app's dashboard), and
    /// with partial frames off.
    @Test(arguments: ["plain", "screen", "if", "group", "group-whole"])
    func detailTitleIsAText(shape: String) throws {
        for width in [390, 1024] {
            var extra = ["PROBE_DETAIL": shape]
            if shape == "group-whole" { extra = ["ISO_PARTIAL": "0"] }
            let app = try launch(width: width, extra: extra)
            defer { app.quit() }
            _ = try app.wait(for: "Mac Studio")
            _ = try app.tap("Mac Studio")
            let screen = try app.wait(for: "What's running")
            #expect(screen.texts.filter { $0 == "Mac Studio" }.count >= (width >= 700 ? 2 : 1),
                    "\(shape) at \(width): \(screen.texts)")
            if width < 700 {
                // The detail's bar goes back to the list, as a phone's does.
                #expect(try app.back().texts.contains("MacBook Pro"), "\(shape): back")
            }
        }
    }
}
