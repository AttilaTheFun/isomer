// Golden draw-list snapshots. Each check renders a view through the real
// build → layout → draw pipeline (RecordingHost) and compares the emitted draw
// list to an inline golden. Run as a plain executable (not XCTest, which is
// awkward to load on a hermetic macOS host); exits non-zero on any mismatch.
// To update goldens after an intentional change, run with `ISO_RECORD=1` and
// paste the printed block.

import Foundation
import IsomerCore

private var failures = 0

@MainActor
private func snapshot(_ view: any View, _ width: Double, _ height: Double) -> String {
    let host = RecordingHost()
    renderViewOnce(view, width: width, height: height, host: host)
    return host.output
}

private func check(_ name: String, _ actual: String, _ expected: String) {
    let recording = ProcessInfo.processInfo.environment["ISO_RECORD"] != nil
    if recording || actual != expected {
        print("=== SNAPSHOT \(name) ===\n\(actual)\n=== END SNAPSHOT ===")
    }
    if !recording && actual != expected {
        failures += 1
        print("FAIL \(name): snapshot mismatch")
    }
}

@main
struct SnapshotRunner {
    static func main() {
        check("textStack", snapshot(VStack(spacing: 8) {
            Text("Hello")
            Text("World")
        }, 200, 120), GOLDEN_textStack)

        check("paddedBackground", snapshot(
            Text("Hi").padding(12).background(Color.blue), 200, 80), GOLDEN_paddedBackground)

        check("shapeInFrame", snapshot(
            Circle().fill(Color.red).frame(width: 40, height: 40), 100, 100), GOLDEN_shapeInFrame)

        check("hstackSpacer", snapshot(HStack {
            Text("A")
            Spacer()
            Text("B")
        }, 200, 44), GOLDEN_hstackSpacer)

        checkLongTokenDoesntStretchColumn()
        checkFixedSizeTakesIdealWidth()
        checkViewThatFits()

        if failures > 0 {
            print("FAILED: \(failures) snapshot check(s)")
            exit(1)
        }
        print("OK: all snapshot checks passed")
    }

    // `.fixedSize()` lays text out at its ideal width even where less is
    // offered — how a view measures a run of characters (a terminal's cell)
    // inside a narrow frame — while the same text without it wraps to fit.
    @MainActor
    static func checkFixedSizeTakesIdealWidth() {
        func widths(_ view: some View) -> [Double] {
            let host = RecordingHost()
            renderViewOnce(view, width: 100, height: 200, host: host)
            return host.lines.filter { $0.hasPrefix("text ") }.compactMap { line in
                let rect = line.drop(while: { $0 != "(" }).dropFirst().prefix(while: { $0 != ")" })
                let parts = rect.split(separator: ",").map { Double($0) ?? 0 }
                return parts.count >= 3 ? parts[2] : nil
            }
        }
        let run = String(repeating: "M", count: 20)
        let fixed = widths(Text(run).lineLimit(1).fixedSize().frame(width: 60))
        let free = widths(Text(run).lineLimit(1).frame(width: 60))
        if fixed.first.map({ $0 < 120 }) ?? true {
            failures += 1
            print("FAIL fixedSize: text kept to the 60 pt frame: \(fixed)")
        }
        if free.first.map({ $0 > 62 }) ?? true {
            failures += 1
            print("FAIL fixedSize: without it the text should fit the frame: \(free)")
        }
    }

    // `ViewThatFits(in: .horizontal)`: the first view whose ideal width fits
    // what is offered, else the last (AgentUI's pictures: a row when they
    // fit, a carousel when not); only the one chosen is drawn.
    @MainActor
    static func checkViewThatFits() {
        func drawn(_ width: Double) -> [String] {
            let host = RecordingHost()
            renderViewOnce(ViewThatFits(in: .horizontal) {
                HStack { Text("one"); Text("two"); Text("three") }
                Text("short")
            }, width: width, height: 100, host: host)
            return host.lines.filter { $0.hasPrefix("text ") }.map { String($0.split(separator: "\"")[1]) }
        }
        // The row's ideal width: 13 characters at 17 × 0.6, and two gaps of 8.
        let wide = drawn(300), narrow = drawn(100)
        if wide != ["one", "two", "three"] {
            failures += 1
            print("FAIL viewThatFits: 300 wide should show the row: \(wide)")
        }
        if narrow != ["short"] {
            failures += 1
            print("FAIL viewThatFits: 100 wide should show the last view: \(narrow)")
        }
    }

    // A long unbreakable token must not widen the column past the proposal.
    @MainActor
    static func checkLongTokenDoesntStretchColumn() {
        let view = VStack(alignment: .leading) {
            Text("https://example.com/a-very-long-unbreakable-url-that-would-overflow-the-line")
            Text("Short")
        }
        let host = RecordingHost()
        renderViewOnce(view, width: 200, height: 200, host: host)
        for line in host.lines where line.hasPrefix("text ") {
            let rect = line.drop(while: { $0 != "(" }).dropFirst().prefix(while: { $0 != ")" })
            let parts = rect.split(separator: ",").map { Double($0) ?? 0 }
            if parts.count >= 3, parts[0] + parts[2] > 201 {
                failures += 1
                print("FAIL longToken: text overflows: \(line)")
            }
        }
    }
}

// MARK: - Goldens (regenerate with ISO_RECORD=1)

private let GOLDEN_textStack = """
text "Hello" (74.5,33.9,51,22.1) s17 w400 #000000d9
text "World" (74.5,64,51,22.1) s17 w400 #000000d9
"""

private let GOLDEN_paddedBackground = """
fillRect (77.8,17,44.4,46.1) r0 #007affff
text "Hi" (89.8,29,20.4,22.1) s17 w400 #000000d9
"""

private let GOLDEN_shapeInFrame = """
fillRect (30,30,40,40) r20 #ff3b30ff
"""

private let GOLDEN_hstackSpacer = """
text "A" (0,11,10.2,22.1) s17 w400 #000000d9
text "B" (189.8,11,10.2,22.1) s17 w400 #000000d9
"""
