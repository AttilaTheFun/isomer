// The driver against views shaped as an app's are (DriverProbe.swift), as an
// app's UI tests found them wanting: each finds an element by the identifier
// or label SwiftUI gives it, and uses it, as XCUITest would on Apple's
// SwiftUI.

import Foundation
import IsomerHeadless
import Testing

@Suite(.serialized)
struct DriverProbeTests {
    private func launch(_ screen: String = "") throws -> HeadlessApp {
        let environment = ProcessInfo.processInfo.environment
        let root = "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "_main")"
        return try HeadlessApp(executable: "\(root)/headless/driver_probe/driver_probe",
                               environment: ["PROBE_SCREEN": screen])
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
        #expect(back.label == "Settings")
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

    /// A long press fires a view's `onLongPressGesture`.
    @Test func aLongPressFiresTheGesture() throws {
        let app = try launch()
        defer { app.quit() }
        try app.longPress("Hold to pin")
        try app.wait(for: "Last: pinned")
        #expect(throws: (any Error).self) { try app.longPress("Mac Studio") }
    }
}
