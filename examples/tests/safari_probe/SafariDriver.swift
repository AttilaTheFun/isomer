import XCTest

/// Drives Safari in the simulator from a command file, so a web build can be
/// looked at the way an iPhone shows it (safe areas, the soft keyboard).
/// Write commands to /private/tmp/safari_probe/cmd.txt, one per line; the
/// results land in out.txt. Commands: `open <url>`, `tap <x> <y>` (points),
/// `tapl <label>` (a web element by accessibility label), `press <x> <y>
/// [seconds]` (a touch held in place, 1 s by default), `drag <x1> <y1>
/// <x2> <y2>`, `dragshot <x1> <y1> <x2> <y2> <name>` (a screenshot with the
/// finger held at the drag's end), `type <text>` (`\n` for return), `shot <name>` (PNG in the same
/// folder), `tree` (the web view's elements), `sleep <seconds>`, `quit`;
/// `tapany <label>` (any element of the frontmost app), `apptree`, `bundle
/// <bundle id>` (bring that app to the front and drive it), `home`
/// (the Home Screen), and `app <label>` (open a Home Screen icon, e.g. a
/// web app added with Share > Add to Home Screen; later commands drive it),
/// `webapp` (type into the frontmost Home Screen web app).
final class SafariDriver: XCTestCase {
    let folder = "/private/tmp/safari_probe"

    func testDrive() throws {
        let files = FileManager.default
        try? files.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        var current = safari
        try? "ready\n".write(toFile: "\(folder)/out.txt", atomically: true, encoding: .utf8)
        while true {
            let path = "\(folder)/cmd.txt"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty else {
                usleep(150_000)
                continue
            }
            try? files.removeItem(atPath: path)
            var out = ""
            var quit = false
            for line in text.split(separator: "\n") {
                if line == "quit" { quit = true; break }
                out += run(String(line), in: &current, safari: safari) + "\n"
            }
            try? out.write(toFile: "\(folder)/out.tmp", atomically: true, encoding: .utf8)
            try? files.removeItem(atPath: "\(folder)/out.txt")
            try? files.moveItem(atPath: "\(folder)/out.tmp", toPath: "\(folder)/out.txt")
            if quit { break }
        }
    }

    private func point(_ app: XCUIApplication, _ x: Double, _ y: Double) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    private func run(_ line: String, in current: inout XCUIApplication, safari: XCUIApplication) -> String {
        let app = current
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0]
        let rest = parts.count > 1 ? parts[1] : ""
        let numbers = rest.split(separator: " ").compactMap { Double($0) }
        switch command {
        case "open":
            guard let url = URL(string: rest) else { return "bad url" }
            XCUIDevice.shared.system.open(url)
            return "opened"
        case "tap" where numbers.count == 2:
            point(app, numbers[0], numbers[1]).tap()
            return "tapped"
        case "tapl":
            let element = app.webViews.descendants(matching: .any)[rest].firstMatch
            guard element.waitForExistence(timeout: 5) else { return "no \(rest)" }
            element.tap()
            return "tapped \(rest)"
        case "press" where numbers.count >= 2:
            // A touch held in place (a long press: text selection, a menu).
            point(app, numbers[0], numbers[1]).press(forDuration: numbers.count > 2 ? numbers[2] : 1.0)
            return "pressed"
        case "drag" where numbers.count == 4:
            point(app, numbers[0], numbers[1]).press(forDuration: 0.05, thenDragTo: point(app, numbers[2], numbers[3]))
            return "dragged"
        case "dragshot" where numbers.count == 4:
            // A screenshot with the finger still down at the drag's end (what
            // a page does under a held pan: a rubber band, say).
            let name = rest.split(separator: " ").last.map(String.init) ?? "dragshot"
            let file = "\(folder)/\(name).png"
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.6) {
                try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: file))
            }
            point(app, numbers[0], numbers[1]).press(
                forDuration: 0.05, thenDragTo: point(app, numbers[2], numbers[3]),
                withVelocity: .slow, thenHoldForDuration: 2.5)
            return "dragged, shot \(name)"
        case "type":
            app.typeText(rest.replacingOccurrences(of: "\\n", with: "\n"))
            return "typed"
        case "shot":
            let png = XCUIScreen.main.screenshot().pngRepresentation
            let file = "\(folder)/\(rest).png"
            return (try? png.write(to: URL(fileURLWithPath: file))) != nil ? file : "write failed"
        case "tree":
            return app.webViews.firstMatch.debugDescription
        case "apptree":
            return String(app.debugDescription.prefix(20000))
        case "tapany":
            let element = app.descendants(matching: .any)[rest].firstMatch
            guard element.waitForExistence(timeout: 5) else { return "no \(rest)" }
            element.tap()
            return "tapped \(rest)"
        case "webapp":
            // Drive a Home Screen web app's own process (its keyboard).
            current = XCUIApplication(bundleIdentifier: "com.apple.webapp")
            return current.exists ? "webapp" : "no webapp"
        case "bundle":
            // Any installed app, brought to the front: later commands
            // (tapany, apptree, tap) act on it.
            current = XCUIApplication(bundleIdentifier: rest)
            current.activate()
            return current.wait(for: .runningForeground, timeout: 10) ? "front \(rest)" : "not running \(rest)"
        case "home":
            XCUIDevice.shared.press(.home)
            return "home"
        case "app":
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let icon = springboard.icons[rest].firstMatch
            guard icon.waitForExistence(timeout: 5) else { return "no icon \(rest)" }
            // An icon on a later page: swipe along to it.
            for _ in 0..<4 where !icon.isHittable { springboard.swipeLeft(); usleep(600_000) }
            guard icon.isHittable else { return "icon \(rest) not reachable" }
            icon.tap()
            // A home-screen web app runs in a process of its own: taps go
            // through the Home Screen's coordinates, which are the screen's.
            current = springboard
            return "opened \(rest)"
        case "sleep" where numbers.count == 1:
            usleep(useconds_t(numbers[0] * 1_000_000))
            return "slept"
        default:
            return "unknown: \(line)"
        }
    }
}
