// The driver against views shaped as an app's are (DriverProbe.swift), as an
// app's UI tests found them wanting: each finds an element by the identifier
// or label SwiftUI gives it, and uses it, as XCUITest would on Apple's
// SwiftUI.
//
// Headless (the probe built headless, :driver_probe_test), and headful when
// ISOMER_HEADFUL_LAUNCHER names a launcher: the iPhone's probe on Apple's
// SwiftUI through Apple's driver (:driver_probe_headful_apple_runner, on
// GitHub's Mac in a run by hand, tools/ci/hosted_headful_test.sh), with
// ISOMER_LANDSCAPE_BUNDLE_ID the same probe turned to landscape by itself;
// and the Mac's (//apple/driver_probe_macos_application, ISOMER_MAC_APP,
// drive/launchers/macos_launcher.sh).

import Foundation
import IsomerHeadless
import Testing

@Suite(.serialized)
struct DriverProbeTests {
    private var headful: Bool { !(ProcessInfo.processInfo.environment["ISOMER_HEADFUL_LAUNCHER"] ?? "").isEmpty }

    /// The probe on `screen`: headful through the launcher the environment
    /// names (`bundle`, another app than ISOMER_BUNDLE_ID's: the landscape
    /// probe), else built headless.
    private func launch(_ screen: String = "", arguments: [String] = [], fresh: Bool = true,
                        bundle: String? = nil, environment extra: [String: String] = [:]) throws -> HeadlessApp {
        let environment = ProcessInfo.processInfo.environment
        if let launcher = environment["ISOMER_HEADFUL_LAUNCHER"], !launcher.isEmpty {
            // The launcher reads the app's bundle from its environment, which
            // it takes from this process's as it starts.
            let saved = environment["ISOMER_BUNDLE_ID"]
            if let bundle { setenv("ISOMER_BUNDLE_ID", bundle, 1) }
            defer { if bundle != nil { if let saved { setenv("ISOMER_BUNDLE_ID", saved, 1) } else { unsetenv("ISOMER_BUNDLE_ID") } } }
            return try HeadlessApp(launcher: launcher, environment: extra.merging(["PROBE_SCREEN": screen]) { $1 },
                                   arguments: arguments, fresh: fresh)
        }
        let root = "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "_main")"
        return try HeadlessApp(executable: "\(root)/headless/driver_probe/driver_probe",
                               environment: extra.merging(["PROBE_SCREEN": screen]) { $1 }, arguments: arguments)
    }

    /// An identifier or a label applied outside what wraps a button
    /// (`.padding`, `.frame`, `.background`, an app's own modifier) is the
    /// button's, as SwiftUI applies accessibility to the element whatever
    /// the modifiers' order.
    @Test func identifiersOutsideWrappersReachTheButton() throws {
        let app = try launch()
        defer { app.quit() }
        let screen = try app.screen()
        #expect(screen.element("allow")?.role == "button", "\(screen.elements)")
        #expect(screen.element("allow")?.label == "Allow")
        #expect(screen.element("deny")?.role == "button", "\(screen.elements)")
        #expect(screen.elements.contains { $0.role == "button" && $0.label == "Close" }, "\(screen.elements)")
        try app.tap("allow")
        try app.wait(for: "Last: allowed")
        try app.tap("deny")
        try app.wait(for: "Last: denied")
        try app.tap("Close")
        try app.wait(for: "Last: closed")
    }

    /// `List(selection:)`'s rows are found by their content's identifier.
    @Test func selectionRowsCarryTheirContentsIdentifier() throws {
        let app = try launch("list")
        defer { app.quit() }
        let screen = try app.screen()
        #expect(screen.element("server-beta")?.role == "button", "\(screen.elements)")
        try app.tap("server-beta")
        try app.wait(for: "Selected: beta")
    }

    /// A combined element with an identifier is listed, by its words.
    @Test func aCombinedElementIsListedByItsIdentifier() throws {
        let app = try launch()
        defer { app.quit() }
        let card = try #require(app.screen().element("server-card"))
        #expect(card.role == "staticText")
        #expect(card.label.contains("Mac Studio"))
        #expect(card.label.contains("2 sessions"))
        #expect(try app.inspect("server-card").id == "server-card")
    }

    @Test func aTogglesIdentifierIsListed() throws {
        let app = try launch()
        defer { app.quit() }
        let toggle = try #require(app.screen().element("notifications"))
        #expect(toggle.role == "toggle")
        #expect(toggle.label == "Notifications")
        let screen = try app.set("notifications", "1")
        #expect(screen.shows("Notifying"))
    }

    /// A bottom bar's `Button(_:systemImage:)` is labelled by its title, as
    /// its accessibility label is, not by its symbol's glyph.
    @Test func aBottomBarIconButtonIsLabelledByItsTitle() throws {
        let app = try launch()
        defer { app.quit() }
        let screen = try app.screen()
        #expect(screen.elements.contains { $0.role == "button" && $0.label == "New session" }, "\(screen.elements)")
        #expect(!screen.elements.contains { $0.label == "✎" })
        try app.tap("New session")
        try app.wait(for: "Last: new session")
    }

    /// A disabled toolbar item is listed, disabled; a tap on it fails.
    @Test func aDisabledBarItemIsListedDisabled() throws {
        let app = try launch()
        defer { app.quit() }
        let save = try #require(app.screen().element("Save"))
        #expect(save.role == "button")
        #expect(save.disabled)
        #expect(try app.screen().element("allow")?.disabled == false)
        #expect(throws: (any Error).self) { try app.tap("Save") }
        #expect(try app.screen().shows("Last: nothing yet"))
    }

    /// `back` on a page pushed inside a sheet goes back to the sheet's page
    /// before it (its bar's Back, listed, labelled with that page's title),
    /// then out of the sheet.
    @Test func backInASheetPopsItsOwnPage() throws {
        let app = try launch("sheet")
        defer { app.quit() }
        try app.tap("Settings…")
        var screen = try app.wait(for: "General settings")
        #expect(screen.presented.first?.style == "sheet")
        // The sheet's root has no Back.
        #expect(screen.element("BackButton") == nil, "\(screen.elements)")
        try app.tap("Advanced")
        screen = try app.wait(for: "Advanced settings")
        let back = try #require(screen.element("BackButton"), "\(screen.elements)")
        #expect(back.role == "button")
        // Labelled with the page it goes back to, but on the Mac, whose
        // Back is a chevron alone.
        let mac = try app.info().platform == "macOS"
        #expect(back.label == (mac ? "Back" : "Settings"))
        screen = try app.back()
        #expect(screen.presented.count == 1, "the sheet is still up")
        #expect(screen.shows("General settings"), "\(screen.texts)")
        #expect(!screen.shows("Advanced settings"))
        // Its Back, tapped, does the same.
        try app.tap("Advanced")
        try app.wait(for: "Advanced settings")
        screen = try app.tap("BackButton")
        #expect(screen.presented.count == 1)
        #expect(screen.shows("General settings"))
        // Nothing pushed in it: back closes the sheet.
        screen = try app.back()
        #expect(screen.presented.isEmpty)
        #expect(screen.shows("Home page"))
    }

    /// A long press fires a view's `onLongPressGesture`, on its own and in
    /// a list's row.
    @Test func aLongPressFiresTheGesture() throws {
        do {
            let app = try launch()
            defer { app.quit() }
            try app.longPress("Hold to pin")
            try app.wait(for: "Last: pinned")
            // A view that takes no long press: an error.
            #expect(throws: (any Error).self) { try app.longPress("Mac Studio") }
        }
        let app = try launch("dialogs")
        defer { app.quit() }
        try app.longPress("Hold to star")
        try app.wait(for: "Last: starred")
    }

    /// An alert's buttons and text field are the screen's while it is up,
    /// listed, typed into and tapped by their labels, as any others; its
    /// title and message are the presentation's. The same read from the
    /// alert's controller alone on Apple's iPhone
    /// (ISO_DRIVE_ALERT_FROM_CONTROLLER: as when the walk can't reach its
    /// views); headless, as it is.
    @Test(arguments: [false, true]) func anAlertsButtonsAndFieldAreListed(fromController: Bool) throws {
        let app = try launch("dialogs", environment: fromController ? ["ISO_DRIVE_ALERT_FROM_CONTROLLER": "1"] : [:])
        defer { app.quit() }
        var screen = try app.tap("Rename…")
        let alert = try #require(screen.presented.last, "\(screen.elements)")
        #expect(alert.style == "alert")
        #expect(alert.title == "Rename Session")
        #expect(alert.message == "Give the session a name.")
        #expect(screen.element("Rename")?.role == "button", "\(screen.elements)")
        #expect(screen.element("Cancel")?.role == "button", "\(screen.elements)")
        #expect(screen.element("Name")?.role == "textField", "\(screen.elements)")
        // What is under it is not.
        #expect(screen.element("session-alpha") == nil, "\(screen.elements)")
        try app.type("Name", "Beta")
        screen = try app.tap("Rename")
        #expect(screen.presented.isEmpty, "\(screen.presented)")
        try app.wait(for: "Last: renamed Beta")
        // Its cancel button, by its label.
        try app.tap("Rename…")
        screen = try app.tap("Cancel")
        #expect(screen.presented.isEmpty, "\(screen.presented)")
        try app.wait(for: "Last: rename cancelled")
    }

    /// An alert presented as a page arrives (at launch, over a page with its
    /// composer focused) is listed and used as any other.
    @Test func anAlertAsAPageArrivesIsListed() throws {
        let app = try launch("signin")
        defer { app.quit() }
        var screen = try app.wait(for: "Open Sign-In Page")
        #expect(screen.presented.last?.title == "Sign In to Claude", "\(screen.presented)")
        #expect(screen.element("Later")?.role == "button", "\(screen.elements)")
        screen = try app.tap("Open Sign-In Page")
        #expect(screen.presented.isEmpty, "\(screen.presented)")
        try app.wait(for: "Last: opened the page")
    }

    /// A confirmation dialog's buttons are the screen's while it is up.
    @Test func aConfirmationDialogsButtonsAreListed() throws {
        let app = try launch("dialogs")
        defer { app.quit() }
        var screen = try app.tap("Delete…")
        let dialog = try #require(screen.presented.last, "\(screen.elements)")
        #expect(dialog.style == "alert")
        #expect(dialog.title == "Delete the session?")
        #expect(screen.element("Delete")?.role == "button", "\(screen.elements)")
        screen = try app.tap("Delete")
        #expect(screen.presented.isEmpty, "\(screen.presented)")
        try app.wait(for: "Last: deleted")
        // Closed without a choice, as tapping outside it closes it (on
        // Apple's SwiftUI its cancel button's action runs then).
        try app.tap("Delete…")
        screen = try app.dismiss()
        #expect(screen.presented.isEmpty, "\(screen.presented)")
    }

    /// A long press on a list's row opens its context menu, whose items are
    /// then the screen's buttons, tapped by their titles; a tap on the row
    /// still opens it.
    @Test func aLongPressOpensARowsContextMenu() throws {
        let app = try launch("dialogs")
        defer { app.quit() }
        var screen = try app.longPress("session-alpha")
        #expect(screen.element("Project Settings")?.role == "button", "\(screen.elements)")
        #expect(screen.element("Archive")?.role == "button", "\(screen.elements)")
        // The menu is all that can be used while it is open.
        #expect(screen.element("Rename…") == nil, "\(screen.elements)")
        screen = try app.tap("Project Settings")
        try app.wait(for: "Last: project settings")
        #expect(screen.element("Project Settings") == nil, "the menu closed: \(screen.elements)")
        try app.tap("session-alpha")
        try app.wait(for: "Last: opened alpha")
    }

    /// Controls in a Form's rows, a text field and the navigation title's
    /// own button, each found by its identifier, as XCUITest finds them.
    @Test func aFormsRowsCarryTheirIdentifiers() throws {
        let app = try launch("form")
        defer { app.quit() }
        let screen = try app.screen()
        for (id, role) in [("add-computer", "button"), ("connect", "button"), ("sync", "toggle"), ("runner", "button"),
                           ("host", "textField"), ("session-title", "button")] {
            #expect(screen.element(id)?.role == role, "\(id): \(screen.elements)")
        }
        try app.tap("add-computer")
        try app.wait(for: "Last: add computer")
        try app.tap("connect")
        try app.wait(for: "Last: connect")
        try app.tap("session-title")
        try app.wait(for: "Last: title")
        try app.type("host", "studio.local")
        try app.wait(for: "Host: studio.local")
        try app.tap("runner")
        try app.wait(for: "Runner settings")
    }

    /// A multi-line text field (`axis: .vertical`) is labelled by its
    /// title, as a one-line field is.
    @Test func aMultiLineFieldIsLabelled() throws {
        let app = try launch("form")
        defer { app.quit() }
        let screen = try app.screen()
        let field = try #require(screen.element("Message"), "\(screen.elements)")
        #expect(field.role == "textField")
        try app.type("Message", "Hello")
        try app.wait(for: "message: Hello")
    }

    /// `dismiss` closes the topmost sheet, whatever closes it for a person:
    /// its Done, or only a swipe down.
    @Test func dismissClosesSheets() throws {
        let app = try launch("sheets")
        defer { app.quit() }
        var screen = try app.tap("Tool calls")
        #expect(screen.presented.count == 1, "\(screen.presented)")
        screen = try app.dismiss()
        #expect(screen.presented.isEmpty, "\(screen.presented)")
        #expect(screen.shows("Last: nothing yet"))
        screen = try app.tap("Question")
        #expect(screen.shows("Which model?"))
        screen = try app.dismiss()
        #expect(screen.presented.isEmpty, "\(screen.presented)")
        // As a swipe closes it: the sheet's onDismiss runs.
        try app.wait(for: "Last: question closed")
    }

    /// A sheet presented from a sheet is on the screen once the tap that
    /// presents it answers.
    @Test func aSheetOverASheetIsThereWhenTheTapAnswers() throws {
        let app = try launch("sheets")
        defer { app.quit() }
        try app.tap("Settings…")
        let screen = try app.tap("add-computer")
        #expect(screen.shows("Inner sheet"), "\(screen.texts)")
        #expect(screen.presented.count == 2, "\(screen.presented)")
        _ = try app.dismiss()
        #expect(try app.screen().shows("Outer sheet"))
    }

    /// The app's own arguments (`-key value`: UserDefaults' argument
    /// domain) reach it.
    @Test func launchArgumentsReachTheApp() throws {
        let app = try launch("form", arguments: ["-probe.argument", "hello"])
        defer { app.quit() }
        try app.wait(for: "Argument: hello")
    }

    /// A launch starts fresh (the app's defaults and files from before
    /// gone), unless the test asks to keep them.
    @Test func aLaunchStartsFreshUnlessAskedToKeep() throws {
        // Headless, the app's defaults are the building machine's: what
        // lasts there is not the launcher's to clear.
        guard headful else { return }
        for (fresh, launches) in [(true, 1), (false, 2), (true, 1)] {
            let app = try launch("form", fresh: fresh)
            defer { app.quit() }
            try app.wait(for: "Launches: \(launches)")
        }
    }

    /// `scene` moves the app's scene phase as leaving it and coming back
    /// does: its `.onChange(of: scenePhase)` sees each step, and what it
    /// opens on coming back (a sign-in prompt, once the phase is active
    /// again) is there.
    @Test func sceneLeavesAndComesBack() throws {
        let app = try launch("scene")
        defer { app.quit() }
        try app.wait(for: "Phase: active")
        try app.scene(.background)
        // Through inactive, as the platform goes (the launcher's or the
        // driver's way alike).
        try app.scene(.active)
        let screen = try app.wait(for: "Welcome back")
        #expect(screen.shows("Phase: active"), "\(screen.texts)")
        #expect(screen.texts.contains { $0.hasPrefix("Changes: ") && $0.contains("background") && $0.hasSuffix("active") },
                "\(screen.texts)")
        #expect(screen.element("sign-in") != nil, "\(screen.elements)")
        try app.tap("sign-in")
        // Inactive alone (a notification's banner pulled down, the app
        // switcher) is no return from the background.
        try app.scene(.inactive)
        try app.wait(for: "Phase: inactive")
        try app.scene(.active)
        let back = try app.wait(for: "Phase: active")
        #expect(!back.shows("Welcome back"), "\(back.texts)")
    }

    /// An app that opens a page in another app (Safari, on the iPhone, which
    /// suspends the app behind it): `scene(.active)` brings it back through
    /// the launcher, the same process, and it answers again. (The Mac's
    /// would open the page in its browser, over the tests after it: not
    /// there.)
    @Test func comingBackFromAnotherApp() throws {
        let app = try launch("scene")
        defer { app.quit() }
        var screen = try app.wait(for: "Phase: active")
        guard try app.info().platform != "macOS" else { return }
        let process = screen.texts.first { $0.hasPrefix("Process: ") }
        try app.tap("Open Page")
        screen = try app.scene(.active)
        screen = try app.wait(for: "Opened: 1")
        #expect(screen.shows("Phase: active"), "\(screen.texts)")
        #expect(screen.texts.first { $0.hasPrefix("Process: ") } == process, "\(screen.texts)")
        if headful {
            // Back from the background, as the app sees it.
            try app.wait(for: "Welcome back")
            try app.tap("sign-in")
        }
        try app.tap("Note")
        try app.wait(for: "notes: 1")
        // And home and back, the launcher's way on the iPhone: the phase
        // active again (iOS can leave a scene brought back from the home
        // screen inactive, after a trip to another app: the driver finishes
        // the step), and what the app opens then is there.
        try app.scene(.background)
        try app.scene(.active)
        screen = try app.wait(for: "Welcome back")
        #expect(screen.shows("Phase: active"), "\(screen.texts)")
        screen = try app.tap("Note")
        try app.wait(for: "notes: 2")
        #expect(screen.texts.first { $0.hasPrefix("Process: ") } == process, "\(screen.texts)")
        // The page again, and a command at once, with no `scene`: an app iOS
        // suspended meanwhile is brought back as the command waits (the
        // launcher's `wake`), and answers.
        try app.tap("Open Page")
        try app.tap("Note")
        screen = try app.wait(for: "notes: 3")
        #expect(screen.texts.first { $0.hasPrefix("Process: ") } == process, "\(screen.texts)")
    }

    /// A command the app never answers (its process stopped, as iOS
    /// suspends an app) fails within the command's timeout, naming it, and
    /// every command after it fails at once.
    @Test func anUnansweredCommandFailsInItsTime() throws {
        let app = try launch("scene")
        defer { app.quit() }
        let screen = try app.wait(for: "Phase: active")
        let pid = try #require(screen.texts.first { $0.hasPrefix("Process: ") }.flatMap { Int32($0.dropFirst(9)) },
                               "\(screen.texts)")
        app.commandTimeout = 3
        #expect(kill(pid, SIGSTOP) == 0)
        defer { kill(pid, SIGCONT) }
        let started = Date()
        let error = #expect(throws: HeadlessError.self) { try app.tap("Note") }
        let waited = Date().timeIntervalSince(started)
        #expect(waited >= 3 && waited < 20, "waited \(waited) s")
        #expect(error?.message.contains("no answer to tap Note in 3 s") == true, "\(String(describing: error))")
        let after = #expect(throws: HeadlessError.self) { try app.screen() }
        #expect(after?.message.contains("not sent") == true, "\(String(describing: after))")
    }

    /// An iPhone app that turns itself to landscape on an upright phone:
    /// taps reach its rows, its info says how it stands, and its pictures
    /// are turned as a person sees them.
    @Test func anAppTurnedToLandscape() throws {
        guard let bundle = ProcessInfo.processInfo.environment["ISOMER_LANDSCAPE_BUNDLE_ID"], headful else { return }
        let app = try launch("form", bundle: bundle)
        defer { app.quit() }
        let info = try app.info()
        #expect(info.width > info.height, "\(info)")
        #expect(info.orientation.hasPrefix("landscape"), "\(info)")
        try app.tap("add-computer")
        try app.wait(for: "Last: add computer")
        try app.tap("Runner")
        try app.wait(for: "Runner settings")
        try app.back()
        let id = try #require(try app.picture("form"))
        #expect(id.hasSuffix("/phone-landscape/form"))
        let environment = ProcessInfo.processInfo.environment
        let proof = environment["ISOMER_PROOF"] ?? "\(environment["TEST_UNDECLARED_OUTPUTS_DIR"] ?? NSTemporaryDirectory())/proof"
        let png = try Data(contentsOf: URL(fileURLWithPath: "\(proof)/screens/\(id).png"))
        // The PNG's IHDR: width, then height, big-endian, from byte 16.
        func number(_ at: Int) -> Int { png[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
        #expect(number(16) > number(20), "the picture stands on its side: \(number(16))×\(number(20))")
    }

    /// A selection list's rows take no activation of their own: the tap
    /// lands where the row stands, in a window the app turned to landscape
    /// on an upright phone as in one upright.
    @Test func aRowTakesATapInAnAppTurnedToLandscape() throws {
        guard let bundle = ProcessInfo.processInfo.environment["ISOMER_LANDSCAPE_BUNDLE_ID"], headful else { return }
        let app = try launch("list", bundle: bundle)
        defer { app.quit() }
        try app.tap("server-gamma")
        try app.wait(for: "Selected: gamma")
        try app.tap("Beta")
        try app.wait(for: "Selected: beta")
    }
}
