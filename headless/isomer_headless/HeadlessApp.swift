// IsomerHeadless: a test's (or an agent's) client for an Isomer app, the
// same test source whatever the app is and wherever it runs
// (docs/drive_plan.md): an app built headless that the test starts (its
// standard input and output), one served at a URL (grpc://, ws://, unix:), a
// headful app attached to a hub, or a server in the test's own process. Each
// call sends one command (shared/wire/headless.proto) and returns the screen
// once the UI has settled, or throws with the screen as it was, or throws
// when the app hasn't answered in `commandTimeout` seconds (60, or
// ISOMER_COMMAND_TIMEOUT), so a hung or suspended app fails the test rather
// than holding it.
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
        /// Listed, but takes no input (`.disabled(true)`): a tap on it fails.
        public let disabled: Bool
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
                    options: $0.options, name: $0.name, disabled: $0.disabled)
        }
        presented = screen.presented.map { Presentation(style: $0.style, title: $0.title, message: $0.message) }
    }

    /// Whether a text on the screen is, or holds, `text`.
    public func shows(_ text: String) -> Bool {
        texts.contains { $0 == text || $0.contains(text) }
    }

    /// The element a target names: its name (`button-3`), its identifier,
    /// its label, or the last whose label holds it (the app's own lookup;
    /// a static text's label only whole).
    public func element(_ target: String) -> Element? {
        elements.first { $0.name == target } ?? elements.first { $0.id == target } ?? elements.last { $0.label == target }
            ?? elements.last { $0.role != "staticText" && $0.label.contains(target) }
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
    /// The interface's orientation where the platform turns it apart from
    /// the device (iOS: portrait, landscape-left, …), else empty.
    public let orientation: String
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

    /// How long a command may wait for the app's answer, in seconds (a
    /// `wait`'s own timeout on top), before it throws, naming the command
    /// and the time waited: the app is hung, or suspended (an iPhone app
    /// another app was opened over), or gone. Every command after one left
    /// unanswered throws at once, as an answer that comes late would answer
    /// the wrong command. `defaultCommandTimeout` to begin with.
    public var commandTimeout: Double = HeadlessApp.defaultCommandTimeout

    /// ISOMER_COMMAND_TIMEOUT (seconds), else 60: an app's command answers
    /// once its UI has settled, in a few seconds at most.
    public static var defaultCommandTimeout: Double {
        ProcessInfo.processInfo.environment["ISOMER_COMMAND_TIMEOUT"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 60
    }

    /// How long a command waits before the launcher is asked to wake the app
    /// (`wake`, requests.sh: the iPhone's brings back an app iOS suspended),
    /// and again as often while it waits.
    private static let wakeAfter: Double = 5

    /// The command left unanswered, after which the call is out of step.
    private var unanswered: String?

    /// Starts `executable` (an app built with --@isomer//headless), listening
    /// on a Unix socket of its own (ISO_DRIVE_LISTEN), so the driver's call
    /// and its layout's (`layout()`) reach the same app. `environment` adds to
    /// the process's own: the app's launch hooks (ISO_STORYBOOK_STORY…),
    /// ISO_HEADLESS_WIDTH and ISO_HEADLESS_HEIGHT (the window, 390 by 844 by
    /// default: a lazy list builds the rows that fit). `arguments` are its
    /// launch arguments: `-key value` pairs are UserDefaults' argument domain,
    /// as on Apple's platforms (`["-fixture", "YES"]`), so an app's fixtures
    /// opened by arguments open the same way here.
    #if !os(Windows) && !(os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
    public convenience init(executable: String, environment: [String: String] = [:], arguments: [String] = []) throws {
        // In /tmp: a test's own temporary folder is too deep for a socket's
        // path (about a hundred bytes at most).
        let socket = "/tmp/isomer-headless-\(UUID().uuidString.prefix(8)).sock"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
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
        let timeout = Self.defaultCommandTimeout
        guard let opened = try Self.blocking(within: timeout, { try await connection.drive(context: context) }) else {
            throw HeadlessError(message: "the app's driver didn't take the call in \(Self.seconds(timeout))", screen: nil)
        }
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
    ///     <launcher> <the hub's ws:// URL> <the app's name> [KEY=VALUE…] [-- <argument>…]
    ///
    /// with `environment` as its KEY=VALUE arguments (the app's launch hooks:
    /// ISO_STORYBOOK_STORY, ISO_HEADLESS_WIDTH and ISO_HEADLESS_HEIGHT for
    /// its window) and `arguments` after `--` (the app's command line: a
    /// UserDefaults `-key value`), and must start the app with ISO_DRIVER set
    /// to the URL and ISO_DRIVER_NAME to the name (a web page's ISO_ query,
    /// an Android intent's extras), then run until it is stopped (SIGTERM,
    /// or a file named `stop` among its requests), when it ends the app.
    /// `quit()` stops it. The app has `timeout` seconds to attach: half on
    /// its first launch, all of it on the one try more. A job whose machines
    /// start apps slowly raises the first launch's time with
    /// ISO_DRIVE_ATTACH_SECONDS in the test's environment (an iPhone
    /// simulator freshly booted on Linux attaches in 80-90 s; the retry then
    /// has at least twice it).
    ///
    /// `fresh` (the default) starts the app with none of its data from
    /// before, as an app built headless always starts: the launcher's
    /// ISOMER_FRESH (the iPhone's: its defaults, files, app groups and the
    /// simulator's keychain cleared; Android's `pm clear`; the Mac's a new
    /// home; the web's a new browser profile, whatever this says). A test of
    /// what lasts between launches passes `fresh: false` for the second.
    public convenience init(launcher: String, environment: [String: String] = [:], arguments: [String] = [],
                            fresh: Bool = true, timeout: Double = 120) throws {
        let hub = try HeadfulHub.shared()
        // A launch that never attaches is tried once more: a simulator now
        // and then loses a launch made just as the app before it quits. The
        // first try has half the time.
        var failure: HeadlessError?
        let first = ProcessInfo.processInfo.environment["ISO_DRIVE_ATTACH_SECONDS"].flatMap(Double.init)
            .map { max($0, 1) } ?? timeout / 2
        for (attempt, wait) in [first, max(timeout, first * 2)].enumerated() {
            let name = HeadfulHub.nextName()
            let (process, requests) = try Self.startLauncher(launcher, hub: hub.url, name: name, environment: environment,
                                                             arguments: arguments, fresh: fresh)
            let attached = try Self.blocking { () async -> Bool in
                let deadline = Date().addingTimeInterval(wait)
                while Date() < deadline {
                    if await hub.hub.waitUntilAttached(name, timeout: 1) { return true }
                    if !process.isRunning { return false }
                }
                return false
            }
            if attached {
                try self.init(connection: IsomerLocalConnection(hub.hub), context: IsomerCallContext(metadata: ["iso-target": name]))
                launched = process
                self.requests = requests
                return
            }
            let running = process.isRunning
            if running {
                process.terminate()
                let stopped = Date().addingTimeInterval(10)
                while process.isRunning, Date() < stopped { Thread.sleep(forTimeInterval: 0.1) }
            }
            failure = HeadlessError(message: running || process.terminationReason == .uncaughtSignal
                ? "the app \(launcher) launched didn't attach in \(Int(wait)) s"
                : "\(launcher) ended (\(process.terminationStatus)) before its app attached", screen: nil)
            if attempt == 0 { print("[headless] \(failure!.message): launching again") }
        }
        throw failure!
    }

    /// The launcher run for one launch: the hub's URL, the app's name and
    /// `environment` as its arguments, and where the test asks it for
    /// pictures (`picture`).
    private static func startLauncher(_ launcher: String, hub: String, name: String, environment: [String: String],
                                      arguments appArguments: [String], fresh: Bool) throws -> (Process, URL) {
        let process = Process()
        let arguments = [hub, name] + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            + (appArguments.isEmpty ? [] : ["--"] + appArguments)
        #if os(Windows)
        // A launcher script through Git's bash (ISOMER_BASH, else Git for
        // Windows' own), as Windows runs no script by its #! line.
        let bash = ProcessInfo.processInfo.environment["ISOMER_BASH"] ?? #"C:\Program Files\Git\bin\bash.exe"#
        process.executableURL = URL(fileURLWithPath: bash)
        process.arguments = [resolve(launcher)] + arguments
        #else
        process.executableURL = URL(fileURLWithPath: resolve(launcher))
        process.arguments = arguments
        #endif
        let requests = FileManager.default.temporaryDirectory.appendingPathComponent("isomer-requests-\(name)")
        try? FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["ISOMER_LAUNCHER_REQUESTS": requests.path, "ISOMER_FRESH": fresh ? "1" : "0"]) { $1 }
        try process.run()
        return (process, requests)
    }
    #endif

    deinit {
        if let call { Task { await call.finish() } }
        // A headful app's launcher a test left running (it threw before its
        // `quit`): stopped, so it doesn't outlive the test with its app.
        #if !(os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
        if let launched, launched.isRunning {
            if let requests { try? Data().write(to: requests.appendingPathComponent("stop")) }
            launched.terminate()
        }
        #endif
    }

    /// The screen as it is.
    @discardableResult
    public func screen() throws -> HeadlessScreen { try send("ls") }

    /// What the app is: its name, platform, renderer and window.
    public func info() throws -> HeadlessInfo {
        let answer = try exchange("info")
        let info = answer.info
        return HeadlessInfo(name: info.name, bundleIdentifier: info.bundleIdentifier, version: info.version,
                            platform: info.platform, renderer: info.renderer, width: info.width, height: info.height,
                            orientation: info.orientation)
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

    /// Told of each picture a hosted test takes (its id and its PNG): a test
    /// records it where its run's results keep it, such as a Swift Testing
    /// attachment, which an XCTest run's result bundle carries home:
    /// `HeadlessApp.onPicture = { id, png in Attachment.record(png, named: id.replacingOccurrences(of: "/", with: "~") + ".png") }`.
    /// (This library doesn't import Testing: a library that isn't testonly
    /// can't, on Apple's platforms.)
    nonisolated(unsafe) public static var onPicture: ((_ id: String, _ png: [UInt8]) -> Void)?

    /// A picture of the screen as it stands once settled, kept as a proof's
    /// screen (docs/drive.md, "Pictures"): its id is
    /// `<platform>/<device>/<name>` (`ios/phone/chat`), the platform the
    /// app's, the device `device` or the platform's own (ios and android:
    /// phone, or phone-landscape in a landscape window; macos, linux,
    /// windows: window; web: desktop). The launcher takes it (simctl, the
    /// Mac's window, adb, Chrome) into ISOMER_PROOF (else the test's
    /// outputs' proof folder), screens/<id>.png; a test hosted in its app
    /// draws the app's own window there (HostedPicture.swift) and hands it
    /// to `onPicture`. An app built headless has nothing to picture, nor
    /// has a launcher that takes no pictures (it answers the request with
    /// none): nil.
    @discardableResult
    public func picture(_ name: String, device: String? = nil) throws -> String? {
        let hosted = local != nil
        guard hosted || (requests != nil && launched?.isRunning == true) else { return nil }
        let info = try self.info()
        let platform = info.platform.lowercased()
        let landscape = info.width > info.height
        let device = device ?? {
            switch platform {
            case "ios", "android": landscape ? "phone-landscape" : "phone"
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
        // The screen settled first (the driver settles before it answers
        // `info`, above).
        if hosted {
            // A test hosted in its app: the app's own window, drawn here.
            let png = Thread.isMainThread
                ? MainActor.assumeIsolated { hostedWindowPNG() }
                : try Self.blocking { await MainActor.run { hostedWindowPNG() } }
            guard let png else { return nil }
            try png.write(to: file)
            Self.onPicture?(id, Array(png))
            return id
        }
        guard let requests, let launched else { return nil }
        // The launcher's picture: a request naming the file, which it writes.
        asked += 1
        let request = requests.appendingPathComponent("\(asked).request")
        // The picture's path, then what the launcher may need to take it as
        // the app stands (requests.sh).
        let text = file.path + "\n" + (info.orientation.isEmpty ? "" : "orientation=\(info.orientation)\n")
        try Data(text.utf8).write(to: request.appendingPathExtension("part"))
        try FileManager.default.moveItem(at: request.appendingPathExtension("part"), to: request)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            // Answered: the request gone, with its picture, or without one
            // (a launcher that can't picture its platform: nil).
            if !FileManager.default.fileExists(atPath: request.path) {
                return FileManager.default.fileExists(atPath: file.path) ? id : nil
            }
            if !launched.isRunning { break }
            Thread.sleep(forTimeInterval: 0.02)
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

    /// Swipes a list row's `.swipeActions` into sight (left: its trailing
    /// ones, right: its leading ones), listed as buttons to `tap` until one
    /// is; with `action`, performs that one (by its title) as the swipe
    /// reveals it. Else drags across a view that takes a drag (the innermost
    /// on the screen with no target): up, down, left or right.
    @discardableResult
    public func swipe(_ target: String = "", _ direction: String, action: String? = nil) throws -> HeadlessScreen {
        try send("swipe") {
            $0.target = target
            $0.direction = direction
            if let action { $0.value = action }
        }
    }

    /// Presses a view long: its `.contextMenu` opens, its items the screen's
    /// buttons (and nothing else, as a person sees an open menu) until one is
    /// tapped (`dismiss` closes it); else its `onLongPressGesture` fires.
    @discardableResult
    public func longPress(_ target: String) throws -> HeadlessScreen {
        try send("longpress") { $0.target = target }
    }

    @discardableResult
    public func back() throws -> HeadlessScreen { try send("back") }

    @discardableResult
    public func dismiss() throws -> HeadlessScreen { try send("dismiss") }

    /// A scene's phase, as SwiftUI's `ScenePhase` has them.
    public enum ScenePhase: String, Sendable {
        case active, inactive, background
    }

    /// Moves the app's scene phase as leaving the app and coming back does,
    /// so what it does then (`.onChange(of: scenePhase)`) runs: `background`
    /// then `active` is a trip to the home screen and back. The launcher's
    /// way first, where the platform's own moves it (Android's: the app sent
    /// home and brought back, its activity stopped and resumed); else the
    /// app's driver's (headless.proto's `scene`: Isomer's runtime's phase,
    /// SwiftUI's scene delegate told on iOS, the app hidden or its windows
    /// in the Dock on the Mac). The screen once it settles; empty when the
    /// launcher sent the app where it answers nothing (the iPhone's home
    /// screen: iOS suspends it there until `scene(.active)` brings it back,
    /// the same process with its state). An app the launcher brought back
    /// is then made active by its driver too, which moves nothing where the
    /// phase is active already: iOS can leave a scene brought back from the
    /// home screen inactive (a simulator no Simulator.app shows).
    @discardableResult
    public func scene(_ phase: ScenePhase) throws -> HeadlessScreen {
        if local == nil, let requests, let launched, launched.isRunning {
            asked += 1
            let request = requests.appendingPathComponent("\(asked).request")
            let answer = requests.appendingPathComponent("\(asked).answer")
            try Data("scene:\(phase.rawValue)\n".utf8).write(to: request.appendingPathExtension("part"))
            try FileManager.default.moveItem(at: request.appendingPathExtension("part"), to: request)
            // Answered (requests.sh): `ok` in <n>.answer when the launcher
            // moved it (`ok away`: to where the app answers nothing until
            // it is back, the iPhone's home screen, so nothing is asked of
            // it: an empty screen); why not, or nothing, when it didn't.
            // Five minutes: the iPhone's launcher gives each simctl call a
            // minute, and a second if the first was ended, as a slow Mac
            // runner needs.
            let deadline = Date().addingTimeInterval(300)
            while FileManager.default.fileExists(atPath: request.path), Date() < deadline, launched.isRunning {
                Thread.sleep(forTimeInterval: 0.02)
            }
            try? FileManager.default.removeItem(at: request)
            let said = (try? String(contentsOf: answer, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: answer)
            if said == "ok" {
                guard phase == .active else { return try screen() }
                return try send("scene") { $0.value = phase.rawValue }
            }
            if said?.hasPrefix("ok ") == true { return HeadlessScreen(Wire_Screen()) }
        }
        return try send("scene") { $0.value = phase.rawValue }
    }

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
        // (Nothing more is asked of an app that left a command unanswered.)
        if unanswered == nil { _ = try? exchange("quit") }
        if let call { _ = try? Self.blocking(within: 10, { await call.finish() }) }
        if let launched, launched.isRunning {
            // A `stop` file beside the picture requests, which every launcher
            // of isomer's watches (requests.sh): on Windows, which has no
            // SIGTERM to trap, it is how the launcher ends its app.
            if let requests { try? Data().write(to: requests.appendingPathComponent("stop")) }
            #if os(Windows)
            var deadline = Date().addingTimeInterval(10)
            while launched.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if launched.isRunning { launched.terminate() }
            #else
            // Elsewhere SIGTERM at once too: a launcher that doesn't watch
            // for the file (an app's own) isn't waited for.
            launched.terminate()
            var deadline = Date()
            #endif
            deadline = Date().addingTimeInterval(10)
            while launched.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
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
        let timeout = commandTimeout
        guard let answered = try Self.blocking(within: timeout, { () -> Wire_Layout? in
            let call = try await connection.layout(context: context)
            try await call.write(Wire_LayoutRequest())
            var inbound = call.inbound.makeAsyncIterator()
            let layout = try await inbound.next()
            await call.finish()
            return layout
        }) else {
            throw HeadlessError(message: "no answer to layout in \(Self.seconds(timeout)) (HeadlessApp.commandTimeout, ISOMER_COMMAND_TIMEOUT)", screen: nil)
        }
        guard let layout = answered else { throw HeadlessError(message: "the app ended without its layout", screen: nil) }
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
        let what = command.target.isEmpty ? cmd : "\(cmd) \(command.target)"
        if let unanswered {
            throw HeadlessError(message: "\(what): not sent, as \(unanswered) went unanswered (the call is out of step: launch the app again)",
                                screen: nil)
        }
        let sent = command
        // The command's own time (a `wait`'s) on top of the answer's.
        let timeout = commandTimeout + (cmd == "wait" ? (command.timeout > 0 ? command.timeout : 5) : 0)
        let answer: Wire_Answer?
        if let local {
            #if !os(WASI) && !os(Android)
            if Thread.isMainThread {
                guard let answered = MainActor.assumeIsolated({ local.send(sent, timeout: timeout) }) else {
                    throw unansweredError(what, timeout)
                }
                answer = answered
            } else {
                guard let answered = try Self.blocking(within: timeout, { await local.answer(sent) }) else {
                    throw unansweredError(what, timeout)
                }
                answer = answered
            }
            #else
            guard let answered = try Self.blocking(within: timeout, { await local.answer(sent) }) else {
                throw unansweredError(what, timeout)
            }
            answer = answered
            #endif
        } else if let call {
            // Waiting, the launcher is asked now and then to wake the app
            // (an iPhone app iOS suspended, brought back to the front).
            guard let answered = try Self.blocking(within: timeout, every: Self.wakeAfter, waiting: { self.askToWake() }, { [self] in
                try await call.write(sent)
                return try await self.answers?.next()
            }) else {
                throw unansweredError(what, timeout)
            }
            answer = answered
        } else {
            answer = nil
        }
        guard let answer else {
            throw HeadlessError(message: "the app ended without answering \(what)", screen: nil)
        }
        return answer
    }

    /// A command that had no answer in `timeout` seconds: the error, and the
    /// call marked out of step.
    private func unansweredError(_ what: String, _ timeout: Double) -> HeadlessError {
        unanswered = what
        return HeadlessError(message: "no answer to \(what) in \(Self.seconds(timeout)) (HeadlessApp.commandTimeout, "
            + "ISOMER_COMMAND_TIMEOUT): the app is hung, suspended or gone", screen: nil)
    }

    /// Asks a headful app's launcher to bring the app back if its platform
    /// suspended it (requests.sh's `wake`, in a file of its own, <n>.wake,
    /// which launchers that don't know it never see), and doesn't wait.
    private func askToWake() {
        guard let requests, let launched, launched.isRunning else { return }
        asked += 1
        let wake = requests.appendingPathComponent("\(asked).wake")
        try? Data("wake\n".utf8).write(to: wake.appendingPathExtension("part"))
        try? FileManager.default.moveItem(at: wake.appendingPathExtension("part"), to: wake)
    }

    static func seconds(_ time: Double) -> String {
        time == time.rounded() ? "\(Int(time)) s" : String(format: "%.1f s", time)
    }

    /// Runs `body` and waits for it: the tests' API is synchronous, and no
    /// client work needs the caller's thread.
    private static func blocking<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        try blocking(within: .infinity, body)!
    }

    /// The same, giving up after `timeout` seconds: nil then (the work is
    /// cancelled, and what it ends with dropped). `waiting` runs every
    /// `interval` seconds while it waits.
    private static func blocking<T>(within timeout: Double, every interval: Double = .infinity, waiting: () -> Void = {},
                                    _ body: @escaping @Sendable () async throws -> T) throws -> T? {
        let done = DispatchSemaphore(value: 0)
        let result = Outcome<T>()
        let task = Task {
            let outcome: Result<T, any Error>
            do { outcome = .success(try await body()) } catch { outcome = .failure(error) }
            result.set(outcome)
            done.signal()
        }
        guard timeout.isFinite else {
            done.wait()
            return try result.get()!.get()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 {
                task.cancel()
                return nil
            }
            if done.wait(timeout: .now() + min(left, interval)) == .success { return try result.get()!.get() }
            if deadline.timeIntervalSinceNow > 0 { waiting() }
        }
    }

    /// What a blocking call's work ended with, set on the work's thread and
    /// read on the caller's.
    private final class Outcome<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<T, any Error>?
        func set(_ value: Result<T, any Error>) {
            lock.lock()
            defer { lock.unlock() }
            self.value = value
        }
        func get() -> Result<T, any Error>? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
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
        guard listening.wait(timeout: .now() + 30) == .success else {
            throw HeadlessError(message: "the hub for headful apps didn't listen in 30 s", screen: nil)
        }
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
