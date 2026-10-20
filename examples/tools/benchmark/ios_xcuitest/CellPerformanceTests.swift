// The platform-native iOS perf harness for the benchmark cells
// (docs/benchmarks.md#ios): XCUITest `measure` blocks driving a REAL,
// release-built cell over real launches and real touches.
//
//  - startup: XCTApplicationLaunchMetric, 10 measured iterations. XCTest
//    itself runs one extra un-measured warmup launch before the first
//    measured one, and reports process-launch → first-frame. >=500 ms
//    between launches (measure serializes them; the app is fully torn down
//    and relaunched each iteration).
//  - interaction: XCTOSSignpostMetric over the app's own "tap" signpost
//    (dev.isomer.bench / Interaction) — the UIEvent→handler edge to the
//    Core Animation commit handoff, emitted by InteractionSignpost. Each
//    measured iteration runs 10 cycles of (50 ms, tap the button, 50 ms,
//    swipe up); one un-measured warmup cycle precedes the measured ones.
//    Injection latency and render-server present time are outside the
//    signpost by construction.
//
// The cell under test is chosen at run time via the ISO_TARGET_BUNDLE_ID
// launch environment (defaults to the cells' shared bundle id: whichever
// cell is installed) so one test bundle measures every iOS cell.

import XCTest

final class CellPerformanceTests: XCTestCase {
    private var bundleID: String {
        ProcessInfo.processInfo.environment["ISO_TARGET_BUNDLE_ID"]
            ?? "com.LoganShire.Isomer"
    }

    private func makeApp() -> XCUIApplication {
        // rules_apple's UI-test runner launches the target app by bundle id.
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments = ["-bench-signpost"]
        // The busy-JS variants: forward ISO_BUSY to the app (RN reads it as
        // initialProperties.busy; the Valdi busy cell is its own app).
        if ProcessInfo.processInfo.environment["ISO_BUSY"] == "1" {
            app.launchEnvironment["ISO_BUSY"] = "1"
        }
        return app
    }

    @MainActor
    func testStartup() throws {
        let options = XCTMeasureOptions()
        options.iterationCount = 10
        let app = makeApp()
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            app.launch()
            // The first content frame: the counter button exists.
            XCTAssertTrue(app.staticTexts.firstMatch.waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    @MainActor
    func testInteraction() throws {
        let app = makeApp()
        app.launch()
        // The button element differs by cell (UIButton, SwiftUI Button, or a
        // tap-gesture text node): probe the precise matchers first.
        _ = app.wait(for: .runningForeground, timeout: 10)
        let candidates: [XCUIElement] = [
            app.buttons["Tap me"],
            app.staticTexts["Tap me"],
            app.otherElements["Tap me"],
        ]
        var target = candidates[0]
        for c in candidates where c.waitForExistence(timeout: 2) {
            target = c
            break
        }
        XCTAssertTrue(target.exists, "no 'Tap me' element in \(bundleID)")

        // Warmup cycle (un-measured).
        cycle(app: app, target: target)

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        let signpost = XCTOSSignpostMetric(
            subsystem: "dev.isomer.bench", category: "Interaction", name: "tap")
        measure(metrics: [signpost], options: options) {
            for _ in 0..<10 { cycle(app: app, target: target) }
        }
        app.terminate()
    }

    private func cycle(app: XCUIApplication, target: XCUIElement) {
        Thread.sleep(forTimeInterval: 0.05)
        target.tap()
        Thread.sleep(forTimeInterval: 0.05)
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.05)
    }
}
