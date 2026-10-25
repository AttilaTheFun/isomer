import XCTest

final class PokedexDetailProbe: XCTestCase {
    @MainActor
    func testDetailArtwork() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ISO_PLAYGROUND_OPENROUTER_KEY"] = "sk-or-headless"
        app.launchEnvironment["ISO_PLAYGROUND_OPEN_PROJECT"] = "Pokédex"
        app.launch()
        let outDir = "/private/tmp/iso_ui_probe"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        // Full-screen run builds the project first (embedded compiler), then
        // the list loads through the injected NetworkService.
        let row = app.staticTexts["Bulbasaur"].firstMatch
        if !row.waitForExistence(timeout: 180) {
                try? app.debugDescription.write(toFile: outDir + "/no_list.txt", atomically: true, encoding: .utf8)
            XCTFail("list never loaded")
            return
        }
        func pushed() -> Bool { app.staticTexts["Grass"].firstMatch.waitForExistence(timeout: 12) }
        var how = "none"
        row.tap()
        if pushed() { how = "element tap" } else {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if pushed() { how = "coordinate tap" } else {
                row.press(forDuration: 0.15)
                if pushed() { how = "press" } else {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.2)).tap()
                    if pushed() { how = "chevron tap" }
                }
            }
        }
        sleep(12)
        try? ("pushed via: " + how + "\n" + app.debugDescription).write(toFile: outDir + "/detail_tree.txt", atomically: true, encoding: .utf8)
    }

    /// The chat page's modal flow: play (build → full-screen run), edit
    /// (sheet with Cancel/Save/Share), web (build → Safari sheet).
    @MainActor
    func testChatFlow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ISO_PLAYGROUND_OPENROUTER_KEY"] = "sk-or-headless"
        app.launch()
        let outDir = "/private/tmp/iso_ui_probe"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        func dump(_ name: String) {
            try? app.debugDescription.write(toFile: outDir + "/\(name).txt", atomically: true, encoding: .utf8)
        }
        let play = app.buttons["Run"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "no play button")
        play.tap()
        _ = app.staticTexts["Compiling…"].firstMatch.waitForExistence(timeout: 5)
        let row = app.staticTexts["Bulbasaur"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 180), "native run never showed the list")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Grass"].firstMatch.waitForExistence(timeout: 15), "detail never pushed")
        sleep(3)
        dump("flow_native_detail")
        let back = app.navigationBars["Bulbasaur"].buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 3), "pushed screen has no back button")
        back.tap(); sleep(2); dump("flow_after_back")
        XCTAssertTrue(app.staticTexts["Ivysaur"].firstMatch.waitForExistence(timeout: 5), "back did not pop to the list")
        app.terminate()
        app.launch()
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        app.buttons["Edit"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 10), "no editor sheet")
        sleep(2)
        dump("flow_editor")
        app.buttons["Cancel"].firstMatch.tap()
        sleep(1)
        app.buttons["Run on the web"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Bulbasaur"].firstMatch.waitForExistence(timeout: 120), "web run never showed the list")
        sleep(3)
        dump("flow_web")
    }

    /// Opens `name`'s chat page: from another project's page, back to the
    /// list and tap it (the agent autorun selects its own new project; a
    /// previous test's selection persists across launches).
    @MainActor
    private func openProject(_ app: XCUIApplication, _ name: String) {
        if app.navigationBars[name].firstMatch.waitForExistence(timeout: 5) { return }
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        let row = app.staticTexts[name].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no \(name) in the project list")
        row.tap()
        XCTAssertTrue(app.navigationBars[name].firstMatch.waitForExistence(timeout: 10), "\(name) did not open")
    }

    /// Two runtimes at once: the user's full-screen run of the selected
    /// project while the (mock) agent builds and runs its own project
    /// offscreen. The list must stay up throughout; the agent's completion
    /// is checked in the simulator log afterwards.
    @MainActor
    func testCoexistingRuns() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ISO_PLAYGROUND_OPENROUTER_KEY"] = "sk-or-headless"
        app.launchEnvironment["ISO_PLAYGROUND_AUTORUN"] = "agent"
        app.launchEnvironment["ISO_PLAYGROUND_AGENT_MOCK"] = "1"
        app.launchEnvironment["ISO_PLAYGROUND_MOCK_KEEP_RUN"] = "1"  // both runtimes stay up together
        app.launch()
        sleep(3)  // the autorun creates + selects its own project
        openProject(app, "Pokédex")
        let play = app.buttons["Run"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "no play button")
        play.tap()
        let row = app.staticTexts["Bulbasaur"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 180), "native run never showed the list")
        // The agent's compile + offscreen run happen meanwhile.
        sleep(75)
        XCTAssertTrue(row.exists, "the user's run went away while the agent ran")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Grass"].firstMatch.waitForExistence(timeout: 15), "detail never pushed after the agent's run")
    }

    /// Crash attribution: kill the Playground while the user's full-screen
    /// run is up; the next launch must note the crash in that project's
    /// transcript (the agent's `crash_report` reads the same record).
    @MainActor
    func testCrashAttribution() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ISO_PLAYGROUND_OPENROUTER_KEY"] = "sk-or-headless"
        app.launch()
        openProject(app, "Pokédex")
        let play = app.buttons["Run"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "no play button")
        play.tap()
        let shown = app.staticTexts["Bulbasaur"].firstMatch.waitForExistence(timeout: 180)
        try? FileManager.default.createDirectory(atPath: "/private/tmp/iso_ui_probe", withIntermediateDirectories: true)
        try? app.debugDescription.write(toFile: "/private/tmp/iso_ui_probe/crash_run.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(shown, "native run never showed the list")
        sleep(2)
        app.terminate()  // SIGKILL: the run's marker stays behind
        app.launch()
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        openProject(app, "Pokédex")
        let note = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'crashed'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), "no crash note in the transcript after relaunch")
        try? app.debugDescription.write(toFile: "/private/tmp/iso_ui_probe/crash_note.txt", atomically: true, encoding: .utf8)
    }

    /// Keyboard avoidance in a full-screen run: the Counter project's source
    /// is replaced (from the shell, before launch) with the Snapchat mock,
    /// whose chat screen has a text field at the bottom. Focusing it must
    /// lift the input bar above the keyboard; the screenshot is written for
    /// inspection.
    @MainActor
    func testKeyboardAvoidance() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ISO_PLAYGROUND_OPENROUTER_KEY"] = "sk-or-headless"
        app.launch()
        openProject(app, "Counter")
        let play = app.buttons["Run"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "no play button")
        play.tap()
        XCTAssertTrue(app.staticTexts["Snapchat"].firstMatch.waitForExistence(timeout: 180), "the mock never showed")
        let row = app.staticTexts["Hao 👻"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no Hao row")
        row.tap()
        let field = app.textFields["Send a chat"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "chat screen never showed its field")
        let before = field.frame
        field.tap()
        sleep(3)
        let after = field.frame
        try? FileManager.default.createDirectory(atPath: "/private/tmp/iso_ui_probe", withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/private/tmp/iso_ui_probe/keyboard.png"))
        try? app.debugDescription.write(toFile: "/private/tmp/iso_ui_probe/keyboard.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(app.keyboards.count > 0, "keyboard did not appear")
        XCTAssertTrue(after.minY < before.minY - 100, "field did not rise above the keyboard (before y=\(before.minY), after y=\(after.minY))")
    }

    /// Hot reloader end to end against a local static site (the shell serves
    /// /private/tmp/iso_hot on :8787 with version 1 published): create the
    /// reloader through the UI, open it (intro alert → the app), publish
    /// version 2 by rewriting versions.json from this host process, expect
    /// the new-version alert, Reload, and see the second app.
    @MainActor
    func testHotReloader() throws {
        let site = "/private/tmp/iso_hot"
        let app = XCUIApplication()
        app.launchEnvironment["ISO_PLAYGROUND_OPENROUTER_KEY"] = "sk-or-headless"
        app.launch()
        // Back to the project list (the chat of the selected project opens).
        if !app.buttons["new-hot-reloader"].firstMatch.waitForExistence(timeout: 5) {
            app.navigationBars.firstMatch.buttons.firstMatch.tap()
        }
        let newRow = app.buttons["new-hot-reloader"].firstMatch
        XCTAssertTrue(newRow.waitForExistence(timeout: 10), "no New Hot Reloader row")
        XCTAssertTrue(app.buttons["new-project"].firstMatch.exists, "no New Project row")
        newRow.tap()
        let name = app.textFields["hot-name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10), "no hot reloader sheet")
        name.tap(); name.typeText("Probe App")
        let url = app.textFields["hot-url"].firstMatch
        url.tap(); url.typeText("http://localhost:8787/versions.json")
        app.buttons["Create"].firstMatch.tap()
        let row = app.buttons["hot-reloader-Probe App"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "reloader row missing")
        row.tap()
        let intro = app.alerts.firstMatch
        XCTAssertTrue(intro.waitForExistence(timeout: 60), "no intro alert")
        XCTAssertTrue(intro.staticTexts.element(boundBy: 0).label.contains("Running v1"), "intro names the wrong version: \(intro.staticTexts.element(boundBy: 0).label)")
        intro.buttons["OK"].tap()
        XCTAssertTrue(app.staticTexts["Tap me"].firstMatch.waitForExistence(timeout: 60), "version 1 (tap counter) never showed")
        // Publish version 2 (the hot demo) — newest first.
        let json = """
        [{"version": "v2", "url": "hot_demo.wasm"}, {"version": "v1", "url": "tap_counter.wasm"}]
        """
        try json.write(toFile: site + "/versions.json", atomically: true, encoding: .utf8)
        let update = app.alerts["New version available"].firstMatch
        XCTAssertTrue(update.waitForExistence(timeout: 40), "no new-version alert after publishing v2")
        update.buttons["Reload"].tap()
        sleep(4)
        try? FileManager.default.createDirectory(atPath: "/private/tmp/iso_ui_probe", withIntermediateDirectories: true)
        try? app.debugDescription.write(toFile: "/private/tmp/iso_ui_probe/hot_after_reload.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(app.staticTexts["Hot reload works."].firstMatch.waitForExistence(timeout: 30), "version 2 (hot demo) never showed after Reload")
    }

    /// The published web Playground in iOS Safari: open it, tap Run on the
    /// selected project (the in-browser compiler), and dump what happened
    /// (the page shows uncaught errors in an overlay).
    @MainActor
    func testSafariWebPlayground() throws {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        let url = ProcessInfo.processInfo.environment["ISO_WEB_PLAYGROUND_URL"] ?? "https://attilathefun.github.io/isomer/playground/"
        let bar = safari.textFields.firstMatch.exists ? safari.textFields.firstMatch : safari.otherElements["Address"].firstMatch
        if !bar.waitForExistence(timeout: 10) { safari.buttons["Address"].firstMatch.tap() }
        let field = safari.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no address field")
        field.tap(); field.typeText(url + "\n")
        // Phone width: the split view shows the sidebar first; open a project.
        let counter = safari.staticTexts["2048"].firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 90), "Playground did not render (no 2048 row)")
        sleep(2)
        counter.tap()
        let run = safari.staticTexts["Run"].firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 30), "project page did not show Run")
        sleep(2)
        run.tap()
        sleep(90)
        let outDir = "/private/tmp/iso_ui_probe"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: outDir + "/safari_run.png"))
        try? safari.debugDescription.write(toFile: outDir + "/safari_run.txt", atomically: true, encoding: .utf8)
    }

    /// Play the SELECTED project from the chat page and dump what rendered.
    @MainActor
    func testPlaySelected() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ISO_PLAYGROUND_OPENROUTER_KEY"] = "sk-or-headless"
        // `--test_env=ISO_PROBE_RENDERER=gpu` runs the selected project on
        // the Metal (SwiftGPU) renderer instead of SwiftUI.
        if let renderer = ProcessInfo.processInfo.environment["ISO_PROBE_RENDERER"] {
            app.launchEnvironment["ISO_PLAYGROUND_RENDERER"] = renderer
            app.launchEnvironment["ISO_GPU_TREE_DEBUG"] = "1"
        }
        app.launch()
        let outDir = "/private/tmp/iso_ui_probe"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let play = app.buttons["Run"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "no play button")
        play.tap()
        sleep(90)
        try? app.debugDescription.write(toFile: outDir + "/play_selected.txt", atomically: true, encoding: .utf8)
    }

    /// The 2048 sample full screen: swipe the board four ways (frames are
    /// captured from outside with `simctl io screenshot`).
    @MainActor
    func testSwipe2048() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ISO_PLAYGROUND_OPENROUTER_KEY"] = "sk-or-headless"
        app.launchEnvironment["ISO_PLAYGROUND_OPEN_PROJECT"] = "2048"
        app.launch()
        XCTAssertTrue(app.staticTexts["SCORE"].firstMatch.waitForExistence(timeout: 180), "game never showed")
        sleep(2)
        let board = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38))
        for (dx, dy) in [(-0.3, 0.0), (0.0, -0.3), (0.3, 0.0), (0.0, 0.3), (-0.3, 0.0), (0.0, -0.3)] {
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + dx, dy: 0.38 + dy))
            board.press(forDuration: 0.05, thenDragTo: end)
            usleep(900_000)
        }
        sleep(1)
        // A slow drag held short of release: the moving tiles follow, the
        // blocked ones stretch (screenshot it from outside during the hold).
        let held = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.38))
        board.press(forDuration: 0.1, thenDragTo: held, withVelocity: .slow, thenHoldForDuration: 4)
        sleep(1)
        let outDir = "/private/tmp/iso_ui_probe"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        try? app.debugDescription.write(toFile: outDir + "/swipe_2048.txt", atomically: true, encoding: .utf8)
    }

    /// The composer's model pill → Model sheet (Effort row pushes the list),
    /// then the web run full screen (2048 in SFSafariViewController).
    @MainActor
    func testModelSheet() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ISO_PLAYGROUND_OPENROUTER_KEY"] = "sk-or-headless"
        // No OPEN_PROJECT (that runs the project full screen); the Pokédex chat opens.
        app.launch()
        let outDir = "/private/tmp/iso_ui_probe"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        func dump(_ name: String) {
            try? app.debugDescription.write(toFile: outDir + "/\(name).txt", atomically: true, encoding: .utf8)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: outDir + "/\(name).png"))
        }
        XCTAssertTrue(app.buttons["Run"].firstMatch.waitForExistence(timeout: 30), "no play button")
        sleep(2)
        dump("composer")
        app.buttons["Model"].firstMatch.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10), "no model sheet")
        sleep(8)
        dump("model_sheet")
        app.buttons["Sort and filter"].firstMatch.tap()
        sleep(3)
        dump("model_filters")
        // Dismiss the menu by tapping the sheet's title area.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        sleep(1)
        app.buttons["Done"].firstMatch.tap()
        sleep(1)
        app.buttons["Effort"].firstMatch.tap()
        let high = app.buttons["High"].firstMatch
        XCTAssertTrue(high.waitForExistence(timeout: 10), "no effort sheet")
        sleep(2)
        dump("effort")
        high.tap()
        XCTAssertTrue(app.staticTexts["High"].firstMatch.waitForExistence(timeout: 10), "effort pill did not update")
        sleep(2)
        dump("composer_high")
        app.buttons["Run on the web"].firstMatch.tap()
        _ = app.staticTexts["Bulbasaur"].firstMatch.waitForExistence(timeout: 150)
        sleep(4)
        dump("web_run")
    }

    /// New Project: the sidebar's + opens the name + template sheet; picking
    /// the Counter template creates a project that opens in the chat.
    @MainActor
    func testNewProjectTemplate() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ISO_PLAYGROUND_OPENROUTER_KEY"] = "sk-or-headless"
        app.launch()
        let outDir = "/private/tmp/iso_ui_probe"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        func dump(_ name: String) {
            try? app.debugDescription.write(toFile: outDir + "/\(name).txt", atomically: true, encoding: .utf8)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: outDir + "/\(name).png"))
        }
        XCTAssertTrue(app.buttons["Run"].firstMatch.waitForExistence(timeout: 30), "no chat page")
        app.buttons["Playground"].firstMatch.tap()
        // The + moved into the Projects section as its first row.
        let plus = app.buttons["new-project"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "no New Project row in the sidebar")
        plus.tap()
        let counter = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Counter'")).firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 10), "no template list")
        sleep(1)
        dump("new_project")
        counter.tap()
        app.buttons["Create"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Counter"].firstMatch.waitForExistence(timeout: 10), "the new project did not open")
        sleep(1)
        dump("new_project_created")
    }

    /// Meme Creator: "Choose your own photo…" presents the system photo
    /// picker (the ImagePickerService); picking the first photo swaps the
    /// canvas background.
    @MainActor
    func testMemePicker() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ISO_PLAYGROUND_OPENROUTER_KEY"] = "sk-or-headless"
        app.launchEnvironment["ISO_PLAYGROUND_OPEN_PROJECT"] = "Meme Creator"
        app.launch()
        let outDir = "/private/tmp/iso_ui_probe"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        func dump(_ name: String) {
            try? app.debugDescription.write(toFile: outDir + "/\(name).txt", atomically: true, encoding: .utf8)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: outDir + "/\(name).png"))
        }
        // Plain buttons render as tappable text on this host.
        let choose = app.staticTexts["Choose your own photo…"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 180), "meme creator never showed")
        sleep(3)
        dump("meme_before")
        app.swipeUp()
        sleep(1)
        choose.tap()
        sleep(4)
        dump("meme_picker")
        // The photo picker is a remote view; its photo cells show up as images.
        let photos = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'"))
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 10), "the photo picker did not show photos")
        // The first cell can sit half off-screen; tap the first hittable one.
        if let photo = photos.allElementsBoundByIndex.first(where: { $0.isHittable }) {
            photo.tap()
        } else {
            photos.element(boundBy: 1).tap()
        }
        sleep(5)
        app.swipeDown()
        sleep(2)
        dump("meme_after")
    }

    /// The composer's + menu → "Import photos into project": the picked photo
    /// lands in the sandbox's imported/ folder and the transcript notes it.
    @MainActor
    func testImportPhoto() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ISO_PLAYGROUND_OPENROUTER_KEY"] = "sk-or-headless"
        app.launch()
        let outDir = "/private/tmp/iso_ui_probe"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        func dump(_ name: String) {
            try? app.debugDescription.write(toFile: outDir + "/\(name).txt", atomically: true, encoding: .utf8)
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: outDir + "/\(name).png"))
        }
        XCTAssertTrue(app.buttons["Run"].firstMatch.waitForExistence(timeout: 30), "no chat page")
        app.buttons["Attach"].firstMatch.tap()
        let importPhotos = app.buttons["Import photos into project"].firstMatch
        XCTAssertTrue(importPhotos.waitForExistence(timeout: 10), "no attach menu")
        sleep(1)
        dump("import_menu")
        importPhotos.tap()
        let photos = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'"))
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 20), "the photo picker did not show photos")
        sleep(2)
        if let photo = photos.allElementsBoundByIndex.first(where: { $0.isHittable }) { photo.tap() } else { photos.element(boundBy: 1).tap() }
        // Multi-selection pickers confirm with Add/Done.
        let add = app.buttons["Add"].firstMatch
        if add.waitForExistence(timeout: 5) { add.tap() }
        let note = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Imported into'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 30), "no import note in the transcript")
        sleep(1)
        dump("import_done")
    }

}
