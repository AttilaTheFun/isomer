// IsomerHeadless: a test's (or an agent's) client for an Isomer app, the
// same test source whatever the app is and wherever it runs
// (docs/drive_plan.md): an app built headless that the test starts (its
// standard input and output), one served at a URL (grpc://, ws://, unix:), a
// headful app attached to a hub, or a server in the test's own process. Each
// call sends one command (shared/wire/headless.proto) and returns the screen
// once the UI has settled, or throws with the screen as it was.
//
//   let app = try HeadlessApp(executable: path, environment: ["ISO_STORYBOOK_STORY": "state.observableobject"])
//   try app.tap("Tap")
//   try app.wait(for: "Taps: 1")
//   XCTAssertEqual(try app.screen().element("Title")?.value, "Taps")

import Foundation
import IsomerProcessTransport
import IsomerRemote
import IsomerServing
import IsomerWire

/// The screen as the app's runtime shows it: no pixels, what a person sees
/// and can do.
public struct HeadlessScreen: Sendable {
    public struct Element: Sendable {
        /// button, textField, toggle, picker, segmented, slider, …
        public let role: String
        public let label: String
        /// Its `accessibilityIdentifier`.
        public let id: String?
        public let value: String?
        /// A picker's or a segmented control's options.
        public let options: [String]
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

    init(_ screen: Wire_Screen) {
        texts = screen.texts
        elements = screen.elements.map {
            Element(role: $0.role, label: $0.label, id: $0.hasID ? $0.id : nil, value: $0.hasValue ? $0.value : nil,
                    options: $0.options)
        }
        presented = screen.presented.map { Presentation(style: $0.style, title: $0.title, message: $0.message) }
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

/// What the app is (`info`).
public struct HeadlessInfo: Sendable {
    public let name: String
    public let bundleIdentifier: String
    public let version: String
    public let platform: String
    public let renderer: String
    public let width: Double
    public let height: Double
}

/// An app driven a command at a time, over one call that lasts as long as
/// this object.
public final class HeadlessApp: @unchecked Sendable {
    private let call: IsomerCall<Wire_Command, Wire_Answer>
    private var answers: IsomerInbound<Wire_Answer>.AsyncIterator

    /// Starts `executable` (an app built with --@isomer//headless), the call
    /// on its standard input and output. `environment` adds to the process's
    /// own: the app's launch hooks (ISO_STORYBOOK_STORY…), ISO_HEADLESS_WIDTH
    /// and ISO_HEADLESS_HEIGHT (the window, 390 by 844 by default: a lazy
    /// list builds the rows that fit).
    public convenience init(executable: String, environment: [String: String] = [:]) throws {
        try self.init(connection: IsomerProcessConnection(.executable(executable, arguments: [], environment: environment)))
    }

    /// An app served at `url` (IsomerRemote's: grpc://, grpcs://, ws://,
    /// unix:, exec:), with its token if it needs one.
    public convenience init(url: String, token: String? = nil, metadata: [String: String] = [:]) throws {
        let endpoint = try IsomerRemote.endpoint(url)
        try self.init(connection: endpoint.connection, context: endpoint.context(token: token, metadata: metadata))
    }

    /// An app reached through any connection: one in this process
    /// (`IsomerLocalConnection`), a transport's.
    public init(connection: any IsomerConnection, context: IsomerCallContext = .init()) throws {
        let opened = try Self.blocking { try await connection.drive(context: context) }
        call = opened
        answers = opened.inbound.makeAsyncIterator()
    }

    deinit {
        let call = call
        Task { await call.finish() }
    }

    /// The screen as it is.
    @discardableResult
    public func screen() throws -> HeadlessScreen { try send("ls") }

    /// What the app is: its name, platform, renderer and window.
    public func info() throws -> HeadlessInfo {
        let answer = try exchange("info")
        let info = answer.info
        return HeadlessInfo(name: info.name, bundleIdentifier: info.bundleIdentifier, version: info.version,
                            platform: info.platform, renderer: info.renderer, width: info.width, height: info.height)
    }

    /// Taps a button, found by identifier, label or the text in it.
    @discardableResult
    public func tap(_ target: String) throws -> HeadlessScreen { try send("tap") { $0.target = target } }

    /// Sets a text field's text.
    @discardableResult
    public func type(_ target: String, _ text: String) throws -> HeadlessScreen {
        try send("type") {
            $0.target = target
            $0.text = text
        }
    }

    /// Sets a control's value: a toggle's "1" or "0", a picker's index.
    @discardableResult
    public func set(_ target: String, _ value: String) throws -> HeadlessScreen {
        try send("set") {
            $0.target = target
            $0.value = value
        }
    }

    /// Chooses a picker's or segmented control's option, by its label.
    @discardableResult
    public func select(_ target: String, _ option: String) throws -> HeadlessScreen {
        try send("select") {
            $0.target = target
            $0.value = option
        }
    }

    /// Drags across a view that takes a drag (the innermost on the screen
    /// with no target): up, down, left or right.
    @discardableResult
    public func swipe(_ target: String = "", _ direction: String) throws -> HeadlessScreen {
        try send("swipe") {
            $0.target = target
            $0.direction = direction
        }
    }

    @discardableResult
    public func back() throws -> HeadlessScreen { try send("back") }

    @discardableResult
    public func dismiss() throws -> HeadlessScreen { try send("dismiss") }

    /// Waits until a text shows (or a control's label or value holds it).
    @discardableResult
    public func wait(for text: String, timeout: Double = 5) throws -> HeadlessScreen {
        try send("wait") {
            $0.text = text
            $0.timeout = timeout
        }
    }

    /// Ends the call (and an app built headless).
    public func quit() {
        _ = try? exchange("quit")
        let call = call
        try? Self.blocking { await call.finish() }
    }

    private func send(_ cmd: String, _ fill: (inout Wire_Command) -> Void = { _ in }) throws -> HeadlessScreen {
        let answer = try exchange(cmd, fill)
        let screen = answer.hasScreen ? HeadlessScreen(answer.screen) : nil
        if !answer.ok {
            throw HeadlessError(message: answer.hasError ? answer.error : "failed", screen: screen)
        }
        return screen ?? HeadlessScreen(Wire_Screen())
    }

    private func exchange(_ cmd: String, _ fill: (inout Wire_Command) -> Void = { _ in }) throws -> Wire_Answer {
        var command = Wire_Command()
        command.cmd = cmd
        fill(&command)
        let call = call
        let sent = command
        let answer: Wire_Answer? = try Self.blocking { [self] in
            try await call.write(sent)
            return try await self.answers.next()
        }
        guard let answer else {
            throw HeadlessError(message: "the app ended without answering \(cmd) \(command.target)", screen: nil)
        }
        return answer
    }

    /// Runs `body` and waits for it: the tests' API is synchronous, and no
    /// client work needs the caller's thread.
    private static func blocking<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, any Error>?
        Task {
            do { result = .success(try await body()) } catch { result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try result!.get()
    }
}
