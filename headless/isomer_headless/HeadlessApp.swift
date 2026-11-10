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
//
// The same test drives a headful app (drawn by its platform's renderer, its
// driver built in with --@isomer//drive:headful) through a launcher: a
// program that starts the app dialling out to the test's own hub and ends it
// when stopped (`HeadlessApp(launcher:environment:)`).

import Foundation
// Not on Windows: the process transport (Unix sockets, POSIX descriptors)
// and IsomerRemote (its gRPC brings swift-nio-ssl, which has no Windows).
// A test there drives a headful app through a launcher alone.
#if !os(Windows)
import IsomerProcessTransport
import IsomerRemote
#endif
import IsomerServing
import IsomerWebSocketTransport
import IsomerWire

/// The screen as the app's runtime shows it: no pixels, what a person sees
/// and can do.
/// An app's layout, from its IsomerLayoutServer (`HeadlessApp.layout()`):
/// each view a test looks for and where it was laid out, in the window's
/// points, a parent before what it holds and the presented layers after the
/// window's.
public struct HeadlessLayout: Sendable {
    /// A view's frame in the window, in points.
    public struct Frame: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
        public var minX: Double { x }
        public var minY: Double { y }
        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
    }

    public struct Item: Sendable {
        /// text, button, textField, image, scroll, slider, progress, view, or
        /// a host view's kind (toggle, picker, …).
        public let kind: String
        public let label: String
        public let identifier: String
        public let frame: Frame
        public let depth: Int
        /// 0 the window's own; 1 the first presented layer, …
        public let layer: Int
    }

    public let width: Double
    public let height: Double
    public let items: [Item]

    init(_ layout: Wire_Layout) {
        width = layout.width
        height = layout.height
        items = layout.items.map {
            Item(kind: $0.kind, label: $0.label, identifier: $0.identifier,
                 frame: Frame(x: $0.x, y: $0.y, width: $0.width, height: $0.height),
                 depth: Int($0.depth), layer: Int($0.layer))
        }
    }

    /// The last item with this label or identifier (of `kind`, if given): the
    /// topmost, as the presented layers come last.
    public func item(_ target: String, kind: String? = nil) -> Item? {
        items.last { ($0.label == target || $0.identifier == target) && (kind == nil || $0.kind == kind) }
    }

    /// Its frame, if there is one by that label or identifier.
    public func frame(of target: String, kind: String? = nil) -> Frame? {
        item(target, kind: kind)?.frame
    }
}

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
        /// Its name on the screen: its role and its place among that role's,
        /// from 1 (`button-3`), which any command takes as its target.
        public let name: String
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
                    options: $0.options, name: $0.name)
        }
        presented = screen.presented.map { Presentation(style: $0.style, title: $0.title, message: $0.message) }
    }

    /// Whether a text on the screen is, or holds, `text`.
    public func shows(_ text: String) -> Bool {
        texts.contains { $0 == text || $0.contains(text) }
    }

    /// The element a target names: its name (`button-3`), its identifier,
    /// its label, or the last whose label holds it (the app's own lookup).
    public func element(_ target: String) -> Element? {
        elements.first { $0.name == target } ?? elements.first { $0.id == target } ?? elements.last { $0.label == target }
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
#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
/// Foundation has no Process here (a test drives the app it is hosted in):
/// a stand-in, never launched.
private final class Process {
    var isRunning: Bool { false }
    var processIdentifier: Int32 { 0 }
    func terminate() {}
}
#endif

public final class HeadlessApp: @unchecked Sendable {
    /// The call a remote or another process's app answers on; nil for the
    /// app this test is hosted in (`local`).
    private let call: IsomerCall<Wire_Command, Wire_Answer>?
    private var answers: IsomerInbound<Wire_Answer>.AsyncIterator?
    /// The app this test bundle is hosted in: its own driver, answered
    /// synchronously on the main thread (IsomerLocalServer).
    private let local: IsomerLocalServer?
    /// What ends a headful app's launcher, when one started the app.
    private var launched: Process?
    /// Where `picture` asks the launcher for a picture (its
    /// ISOMER_LAUNCHER_REQUESTS).
    private var requests: URL?
    /// How many pictures this app has had asked of it.
    private var asked = 0
    /// Where the app answers calls other than the driver's (its layout):
    /// nil for the app this test is hosted in.
    private let connection: (any IsomerConnection)?
    private let context: IsomerCallContext
    /// The socket an app this object started listens on, removed when it goes.
    private var socket: String?

    /// Starts `executable` (an app built with --@isomer//headless), listening
    /// on a Unix socket of its own (ISO_DRIVE_LISTEN), so the driver's call
    /// and its layout's (`layout()`) reach the same app. `environment` adds to
    /// the process's own: the app's launch hooks (ISO_STORYBOOK_STORY…),
    /// ISO_HEADLESS_WIDTH and ISO_HEADLESS_HEIGHT (the window, 390 by 844 by
    /// default: a lazy list builds the rows that fit).
    #if !os(Windows) && !(os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
    public convenience init(executable: String, environment: [String: String] = [:]) throws {
        // In /tmp: a test's own temporary folder is too deep for a socket's
        // path (about a hundred bytes at most).
        let socket = "/tmp/isomer-headless-\(UUID().uuidString.prefix(8)).sock"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.environment = ProcessInfo.processInfo.environment
            .merging(environment) { $1 }
            .merging(["ISO_DRIVE_LISTEN": "unix:" + socket, "ISO_HEADLESS_PROTOCOL": "serve"]) { $1 }
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: socket) {
            guard process.isRunning else {
                throw HeadlessError(message: "\(executable) ended before it listened", screen: nil)
            }
            guard Date() < deadline else {
                process.terminate()
                throw HeadlessError(message: "\(executable) didn't listen on \(socket) in 30 s", screen: nil)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        try self.init(connection: IsomerProcessConnection(.unixSocket(socket)))
        launched = process
        self.socket = socket
    }
    #endif

    #if !os(Windows)

    /// An app served at `url` (IsomerRemote's: grpc://, grpcs://, ws://,
    /// unix:, exec:), with its token if it needs one.
    public convenience init(url: String, token: String? = nil, metadata: [String: String] = [:]) throws {
        let endpoint = try IsomerRemote.endpoint(url)
        try self.init(connection: endpoint.connection, context: endpoint.context(token: token, metadata: metadata))
    }
    #endif

    /// An app reached through any connection: one in this process
    /// (`IsomerLocalConnection`), a transport's.
    public init(connection: any IsomerConnection, context: IsomerCallContext = .init()) throws {
        let opened = try Self.blocking { try await connection.drive(context: context) }
        call = opened
        answers = opened.inbound.makeAsyncIterator()
        local = nil
        self.connection = connection
        self.context = context
    }

    private init(local: IsomerLocalServer) {
        call = nil
        answers = nil
        self.local = local
        connection = nil
        context = IsomerCallContext()
    }

    /// The app this test bundle is hosted in, when it is one with a driver
    /// (a test bundle in an app built with --@isomer//drive:headful); nil
    /// otherwise, at once outside an app (a test binary of its own), so the
    /// same tests run hosted or launch their app.
    public static func hostedIfAny(timeout: Double = 30) -> HeadlessApp? {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
        return try? hosted(timeout: timeout)
    }

    /// The app this test bundle is hosted in (its host built with
    /// --@isomer//drive:headful): driven in its own process with no network,
    /// as an XCUITest drives its app. From the main thread (an XCTest method)
    /// synchronously, the main run loop turned while the driver works; from
    /// another (a Swift Testing test) with a hop to the main actor. Waits up
    /// to `timeout` seconds for the app's host to have started its driver.
    public static func hosted(timeout: Double = 30) throws -> HeadlessApp {
        let server: IsomerLocalServer?
        #if !os(WASI) && !os(Android)
        if Thread.isMainThread {
            server = MainActor.assumeIsolated { IsomerLocalServer.waitForCurrent(timeout: timeout) }
        } else {
            server = try blocking { try await waitForLocal(timeout: timeout) }
        }
        #else
        server = try blocking { try await waitForLocal(timeout: timeout) }
        #endif
        guard let server else {
            throw HeadlessError(message: "no driver in this process in \(Int(timeout)) s: is the host app built with --@isomer//drive:headful?", screen: nil)
        }
        return HeadlessApp(local: server)
    }

    /// The app's own driver, once its host has started it, from off the
    /// main thread.
    private static func waitForLocal(timeout: Double) async throws -> IsomerLocalServer? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            if let current = await MainActor.run(body: { IsomerLocalServer.current }) { return current }
            if Date() > deadline { return nil }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    #if !(os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
    /// A headful app, started by `launcher` and driven through a hub in this
    /// process (a WebSocket on the loopback address, its port the system's
    /// choice). The launcher is run as
    ///
    ///     <launcher> <the hub's ws:// URL> <the app's name> [KEY=VALUE…]
    ///
    /// with `environment` as its KEY=VALUE arguments (the app's launch hooks:
    /// ISO_STORYBOOK_STORY, ISO_HEADLESS_WIDTH and ISO_HEADLESS_HEIGHT for
    /// its window), and must start the app with ISO_DRIVER set to the URL and
    /// ISO_DRIVER_NAME to the name (a web page's ISO_ query, an Android
    /// intent's extras), then run until it is stopped (SIGTERM), when it ends
    /// the app. `quit()` stops it. The app has `timeout` seconds to attach.
    public convenience init(launcher: String, environment: [String: String] = [:], timeout: Double = 120) throws {
        let hub = try HeadfulHub.shared()
        let name = HeadfulHub.nextName()
        let process = Process()
        let arguments = [hub.url, name] + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        #if os(Windows)
        // A launcher script through Git's bash (ISOMER_BASH, else Git for
        // Windows' own), as Windows runs no script by its #! line.
        let bash = ProcessInfo.processInfo.environment["ISOMER_BASH"] ?? #"C:\Program Files\Git\bin\bash.exe"#
        process.executableURL = URL(fileURLWithPath: bash)
        process.arguments = [Self.resolve(launcher)] + arguments
        #else
        process.executableURL = URL(fileURLWithPath: Self.resolve(launcher))
        process.arguments = arguments
        #endif
        // Where the test asks the launcher for pictures (`picture`).
        let requests = FileManager.default.temporaryDirectory.appendingPathComponent("isomer-requests-\(name)")
        try? FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        process.environment = ProcessInfo.processInfo.environment.merging(["ISOMER_LAUNCHER_REQUESTS": requests.path]) { $1 }
        try process.run()
        let attached = try Self.blocking { () async -> Bool in
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if await hub.hub.waitUntilAttached(name, timeout: 1) { return true }
                if !process.isRunning { return false }
            }
            return false
        }
        guard attached else {
            if process.isRunning { process.terminate() }
            throw HeadlessError(message: process.isRunning || process.terminationReason == .uncaughtSignal
                ? "the app \(launcher) launched didn't attach in \(Int(timeout)) s"
                : "\(launcher) ended (\(process.terminationStatus)) before its app attached", screen: nil)
        }
        try self.init(connection: IsomerLocalConnection(hub.hub), context: IsomerCallContext(metadata: ["iso-target": name]))
        launched = process
        self.requests = requests
    }
    #endif

    deinit {
        if let call { Task { await call.finish() } }
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

    /// One element or text in full (`inspect`): its kind, actions,
    /// parameters, the texts in it, a text's font and colour.
    public func inspect(_ target: String) throws -> Wire_Inspection {
        let answer = try exchange("inspect") { $0.target = target }
        guard answer.ok, answer.hasInspection else {
            throw HeadlessError(message: answer.hasError ? answer.error : "nothing inspected",
                                screen: answer.hasScreen ? HeadlessScreen(answer.screen) : nil)
        }
        return answer.inspection
    }

    /// A launcher's path as a test names it: a relative one (a Bazel test's
    /// `$(rootpath …)`, `../<repository>/…` for another module's) against
    /// its runfiles' workspace, collapsed in the text, as `..` through the
    /// runfiles' symlinks would land elsewhere.
    static func resolve(_ path: String) -> String {
        let environment = ProcessInfo.processInfo.environment
        guard !path.hasPrefix("/"), let runfiles = environment["TEST_SRCDIR"] else { return path }
        let workspace = environment["TEST_WORKSPACE"] ?? "_main"
        return (URL(fileURLWithPath: runfiles).appendingPathComponent(workspace).appendingPathComponent(path)).standardized.path
    }

    /// A picture of the screen as it stands once settled, kept as a proof's
    /// screen (docs/drive.md, "Pictures"): its id is
    /// `<platform>/<device>/<name>` (`ios/phone/chat`), the platform the
    /// app's, the device `device` or the platform's own (ios: phone, or
    /// phone-landscape in a landscape window; macos, linux, windows: window;
    /// android: phone; web: desktop). The launcher takes it (simctl, the
    /// Mac's window, adb, Chrome) into ISOMER_PROOF (else the test's
    /// outputs' proof folder), screens/<id>.png. An app built headless has
    /// nothing to picture, nor has a launcher that takes no pictures (it
    /// answers the request with none): nil.
    @discardableResult
    public func picture(_ name: String, device: String? = nil) throws -> String? {
        guard let requests, let launched, launched.isRunning else { return nil }
        let info = try self.info()
        let platform = info.platform.lowercased()
        let landscape = info.width > info.height
        let device = device ?? {
            switch platform {
            case "ios": landscape ? "phone-landscape" : "phone"
            case "android": "phone"
            case "web": "desktop"
            default: "window"
            }
        }()
        let id = "\(platform)/\(device)/\(name)"
        guard id.allSatisfy({ $0.isLowercase || $0.isNumber || "-./".contains($0) }) else {
            throw HeadlessError(message: "\(id): a picture's id is lowercase letters, digits, - . and /", screen: nil)
        }
        let environment = ProcessInfo.processInfo.environment
        let proof = environment["ISOMER_PROOF"].map(URL.init(fileURLWithPath:))
            ?? environment["TEST_UNDECLARED_OUTPUTS_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("proof") }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("isomer-proof")
        let file = proof.appendingPathComponent("screens/\(id).png")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file)
        // The screen settled first; then the launcher's picture (a request
        // naming the file, which it writes).
        _ = try screen()
        asked += 1
        let request = requests.appendingPathComponent("\(asked).request")
        try Data(file.path.utf8).write(to: request.appendingPathExtension("part"))
        try FileManager.default.moveItem(at: request.appendingPathExtension("part"), to: request)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            // Answered: the request gone, with its picture, or without one
            // (a launcher that can't picture its platform: nil).
            if !FileManager.default.fileExists(atPath: request.path) {
                return FileManager.default.fileExists(atPath: file.path) ? id : nil
            }
            if !launched.isRunning { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw HeadlessError(message: "the launcher took no picture of \(id)", screen: nil)
    }

    /// Taps a button, found by its name, identifier, label or the text in it.
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

    /// Ends the call (and an app built headless, or a headful app's
    /// launcher, which ends the app).
    public func quit() {
        // The app a test is hosted in runs on: there is nothing to end.
        guard local == nil else { return }
        _ = try? exchange("quit")
        if let call { try? Self.blocking { await call.finish() } }
        if let launched, launched.isRunning {
            // A `stop` file beside the picture requests first: a launcher on
            // Windows, which has no SIGTERM to trap, ends its app on seeing it.
            if let requests { try? Data().write(to: requests.appendingPathComponent("stop")) }
            var deadline = Date().addingTimeInterval(10)
            while launched.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if launched.isRunning { launched.terminate() }
            deadline = Date().addingTimeInterval(10)
            while launched.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            #if !os(Windows)
            if launched.isRunning { kill(launched.processIdentifier, SIGKILL) }
            #endif
        }
        launched = nil
        if let socket { try? FileManager.default.removeItem(atPath: socket) }
        socket = nil
    }

    /// The app's layout, from its IsomerLayoutServer: where each view was
    /// laid out, in the window's points (an app built headless has one; the
    /// driver's commands stay frameless). It answers once the frame the app
    /// asked for is drawn.
    public func layout() throws -> HeadlessLayout {
        guard let connection else {
            throw HeadlessError(message: "the app this test is hosted in has no layout to ask for", screen: nil)
        }
        let context = context
        let layout = try Self.blocking { () -> Wire_Layout? in
            let call = try await connection.layout(context: context)
            try await call.write(Wire_LayoutRequest())
            var inbound = call.inbound.makeAsyncIterator()
            let layout = try await inbound.next()
            await call.finish()
            return layout
        }
        guard let layout else { throw HeadlessError(message: "the app ended without its layout", screen: nil) }
        return HeadlessLayout(layout)
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
        let sent = command
        let answer: Wire_Answer?
        if let local {
            #if !os(WASI) && !os(Android)
            if Thread.isMainThread {
                answer = MainActor.assumeIsolated { local.send(sent) }
            } else {
                answer = try Self.blocking { await local.answer(sent) }
            }
            #else
            answer = try Self.blocking { await local.answer(sent) }
            #endif
        } else if let call {
            answer = try Self.blocking { [self] in
                try await call.write(sent)
                return try await self.answers?.next()
            }
        } else {
            answer = nil
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

/// The hub headful apps a test launches dial out to: one a process, started
/// at the first launch and served until the process ends.
private final class HeadfulHub: @unchecked Sendable {
    let hub: IsomerHub
    let url: String

    private static let lock = NSLock()
    nonisolated(unsafe) private static var started: HeadfulHub?
    nonisolated(unsafe) private static var launches = 0

    static func shared() throws -> HeadfulHub {
        lock.lock()
        defer { lock.unlock() }
        if let started { return started }
        guard #available(macOS 14, iOS 17, *) else {
            throw HeadlessError(message: "a headful app's hub needs macOS 14 (the WebSocket transport)", screen: nil)
        }
        let hub = IsomerHub()
        let listening = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var port = 0
        nonisolated(unsafe) var failure: (any Error)?
        Task.detached {
            do {
                try await IsomerWebSocketServer(hub, host: "127.0.0.1", port: 0).run { bound in
                    port = bound
                    listening.signal()
                }
            } catch {
                failure = error
                listening.signal()
            }
        }
        listening.wait()
        if let failure { throw failure }
        let made = HeadfulHub(hub: hub, url: "ws://127.0.0.1:\(port)")
        started = made
        return made
    }

    private init(hub: IsomerHub, url: String) {
        self.hub = hub
        self.url = url
    }

    /// A name no other launch of this process has.
    static func nextName() -> String {
        lock.lock()
        defer { lock.unlock() }
        launches += 1
        return "headful-\(ProcessInfo.processInfo.processIdentifier)-\(launches)"
    }
}
