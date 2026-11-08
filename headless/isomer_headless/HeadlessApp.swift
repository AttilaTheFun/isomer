// IsomerHeadless: a test's (or an agent's) client for an Isomer app built
// headless (--@isomer//headless, headless/libraries/swift_ui). It launches
// the app's binary and speaks its protocol (HeadlessHost.swift): each call
// sends one command and returns the screen once the UI has settled, or
// throws with the screen as it was.
//
//   let app = try HeadlessApp(executable: path, environment: ["ISO_STORYBOOK_STORY": "state.observableobject"])
//   try app.tap("Tap")
//   try app.wait(for: "Taps: 1")
//   XCTAssertEqual(try app.screen().element("Title")?.value, "Taps")

import Foundation

/// The screen as the app's runtime shows it: no pixels, what a person sees
/// and can do.
public struct HeadlessScreen: Sendable {
    public struct Element: Sendable {
        /// button, textField, toggle, picker, slider, …
        public let role: String
        public let label: String
        /// Its `accessibilityIdentifier`.
        public let id: String?
        public let value: String?
    }

    public struct Presentation: Sendable {
        /// sheet, popover or alert.
        public let style: String
        public let title: String
        public let message: String
    }

    public let texts: [String]
    public let elements: [Element]
    public let presented: [Presentation]

    init(_ json: [String: Any]) {
        texts = json["texts"] as? [String] ?? []
        elements = (json["elements"] as? [[String: Any]] ?? []).map {
            Element(role: $0["role"] as? String ?? "", label: $0["label"] as? String ?? "",
                    id: $0["id"] as? String, value: $0["value"] as? String)
        }
        presented = (json["presented"] as? [[String: Any]] ?? []).map {
            Presentation(style: $0["style"] as? String ?? "", title: $0["title"] as? String ?? "",
                         message: $0["message"] as? String ?? "")
        }
    }

    /// Whether a text on the screen is, or holds, `text`.
    public func shows(_ text: String) -> Bool {
        texts.contains { $0 == text || $0.contains(text) }
    }

    /// The element a target names: its identifier, its label, or the last
    /// whose label holds it (the app's own lookup).
    public func element(_ target: String) -> Element? {
        elements.first { $0.id == target } ?? elements.last { $0.label == target }
            ?? elements.last { $0.label.contains(target) }
    }
}

public struct HeadlessError: LocalizedError, CustomStringConvertible {
    public let message: String
    public let screen: HeadlessScreen?
    public var description: String {
        guard let screen else { return message }
        return "\(message); the screen shows: \(screen.texts.prefix(40).joined(separator: " | "))"
    }
    public var errorDescription: String? { description }
}

/// An app running headless, driven a command at a time.
public final class HeadlessApp {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffered = Data()

    /// Launches `executable` (an app built with --@isomer//headless).
    /// `environment` adds to the process's own: the app's launch hooks
    /// (ISO_STORYBOOK_STORY…), ISO_HEADLESS_WIDTH and ISO_HEADLESS_HEIGHT
    /// (the window, 390 by 844 by default: a lazy list builds the rows
    /// that fit).
    public init(executable: String, environment: [String: String] = [:]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardInput = input
        process.standardOutput = output
        try process.run()
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    /// The screen as it is.
    @discardableResult
    public func screen() throws -> HeadlessScreen { try send(["cmd": "ls"]) }

    /// Taps a button, found by identifier, label or the text in it.
    @discardableResult
    public func tap(_ target: String) throws -> HeadlessScreen { try send(["cmd": "tap", "target": target]) }

    /// Sets a text field's text.
    @discardableResult
    public func type(_ target: String, _ text: String) throws -> HeadlessScreen {
        try send(["cmd": "type", "target": target, "text": text])
    }

    /// Sets a control's value: a toggle's "1" or "0", a picker's index.
    @discardableResult
    public func set(_ target: String, _ value: String) throws -> HeadlessScreen {
        try send(["cmd": "set", "target": target, "value": value])
    }

    @discardableResult
    public func back() throws -> HeadlessScreen { try send(["cmd": "back"]) }

    @discardableResult
    public func dismiss() throws -> HeadlessScreen { try send(["cmd": "dismiss"]) }

    /// Waits until a text shows (or a control's label or value holds it).
    @discardableResult
    public func wait(for text: String, timeout: Double = 5) throws -> HeadlessScreen {
        try send(["cmd": "wait", "text": text, "timeout": timeout])
    }

    /// Ends the app.
    public func quit() {
        _ = try? send(["cmd": "quit"])
        process.waitUntilExit()
    }

    private func send(_ command: [String: Any]) throws -> HeadlessScreen {
        var line = try JSONSerialization.data(withJSONObject: command)
        line.append(0x0A)
        input.fileHandleForWriting.write(line)
        guard let answerLine = readLine(),
              let answer = try JSONSerialization.jsonObject(with: answerLine) as? [String: Any] else {
            throw HeadlessError(message: "the app ended without answering \(command)", screen: nil)
        }
        let screen = (answer["screen"] as? [String: Any]).map(HeadlessScreen.init)
        if answer["ok"] as? Bool != true {
            throw HeadlessError(message: answer["error"] as? String ?? "failed", screen: screen)
        }
        return screen ?? HeadlessScreen([:])
    }

    /// One line of the app's output.
    private func readLine() -> Data? {
        while true {
            if let newline = buffered.firstIndex(of: 0x0A) {
                let line = buffered[buffered.startIndex..<newline]
                buffered.removeSubrange(buffered.startIndex...newline)
                return Data(line)
            }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            buffered.append(chunk)
        }
    }
}
