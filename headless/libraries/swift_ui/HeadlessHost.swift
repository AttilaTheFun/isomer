// The headless host (headless/libraries/swift_ui): an app's SwiftUI run on
// the building machine (macOS, or Linux in a container) with nothing drawn,
// served to whatever drives it or draws it (docs/drive_plan.md). `App.main()`
// runs `HeadlessApp` (`iso_process_host_run`), an `IsomerServer`:
//
// - `drive` (shared/wire/headless.proto): IsomerDriver reads the screen and
//   uses it, a command at a time;
// - `connect` (shared/wire/session.proto): a head draws the app, its events in
//   and frames out (RemoteSession.swift).
//
// How it's reached, by its environment:
//
//   (nothing)                     JSON lines on standard input and output, a
//                                 command and its answer a line, for a terminal:
//                                 {"cmd": "tap", "target": "Send"}
//   ISO_HEADLESS_PROTOCOL=binary  one call on standard input and output
//                                 (IsomerProcessTransport: a client that
//                                 started the app, IsomerHeadless's)
//   ISO_DRIVE_LISTEN=<addresses>  listening, space-separated: grpc://host:port,
//                                 ws://host:port (with ISO_DRIVE_SITE, a
//                                 directory served beside it: the web's thin
//                                 client), unix:/path. With
//                                 ISO_HEADLESS_PROTOCOL=serve, nothing on
//                                 standard input. A listener on an address
//                                 other than the loopback needs a token
//                                 (ISO_DRIVE_TOKEN or ISO_DRIVE_TOKEN_FILE).
//   ISO_DRIVER=<url>              dialling out to a hub or a test host and
//                                 driven over that connection (Driver.Attach),
//                                 as a headful app is; ISO_DRIVER_TOKEN its token
//   ISO_HEADLESS_WIDTH/HEIGHT     the window (390 by 844), until a head says its own
//   ISO_DARK                      the dark appearance

#if !canImport(WASILibc)

internal import IsomerDriver
internal import IsomerGRPCTransport
internal import IsomerProcessTransport
internal import IsomerRemote
internal import IsomerServing
internal import IsomerSwiftUI
internal import IsomerWebSocketTransport
internal import IsomerWire
internal import SwiftProtobuf
internal import SwiftUI
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The services half with nothing to draw: text measured as a fixed-width
/// estimate, every image ready. What the app asks of the platform goes to a
/// head drawing it, if one is (RemoteSession).
final class HeadlessHostBridge: HostBridge {
    func measureText(_ text: String, fontSize: Double, weight: Int, wrapWidth: Double?) -> CGSize {
        let width = fontSize * 0.55 * Double(text.count)
        if let wrapWidth, wrapWidth > 0, width > wrapWidth {
            let lines = (width / wrapWidth).rounded(.up)
            return CGSize(width: wrapWidth, height: fontSize * 1.3 * lines)
        }
        return CGSize(width: width, height: fontSize * 1.3)
    }

    func imageInfo(_ source: String, isRemote: Bool) -> ImageStatus { .ready(CGSize(width: 1, height: 1)) }
    func syncHostViews(_ viewsJSON: String) {}
    func beginTextInput(_ text: String, in rect: CGRect, fontSize: Double) {
        RemoteSession.send {
            $0.textInput = Wire_TextInputRequest.with {
                $0.text = text
                $0.x = rect.origin.x
                $0.y = rect.origin.y
                $0.width = rect.size.width
                $0.height = rect.size.height
                $0.fontSize = fontSize
            }
        }
    }
    func endTextInput() { RemoteSession.send { $0.endTextInput = Wire_Empty() } }
    func scheduleRender() { HeadlessApp.needsFrame = true }
    func log(_ message: String) {
        HeadlessApp.logLine("[iso] \(message)")
        RemoteSession.send { $0.log = message }
    }
    func openURL(_ url: String) {
        HeadlessApp.logLine("[iso] openURL \(url)")
        RemoteSession.send { $0.openURL = url }
    }
    func setColorScheme(dark: Bool) { RemoteSession.send { $0.dark = dark } }
    func platformCommand(_ key: String, _ value: String) {
        RemoteSession.send {
            $0.command = Wire_PlatformCommand.with {
                $0.key = key
                $0.value = value
            }
        }
    }
    func registerImage(_ source: String, bytes: [UInt8]) {
        RemoteSession.send {
            $0.image = Wire_Image.with {
                $0.source = source
                $0.bytes = Data(bytes)
            }
        }
    }
    func now() -> Double { Date().timeIntervalSince1970 }
}

/// What the headless app serves: the driver's `drive`, a head's `connect`.
struct HeadlessServer: IsomerServer {
    let driving: IsomerDriverServer

    func drive(_ commands: IsomerInbound<Wire_Command>, _ answers: IsomerOutbound<Wire_Answer>, context: IsomerCallContext) async throws {
        try await driving.drive(commands, answers, context: context)
    }

    func connect(_ messages: IsomerInbound<Wire_ClientMessage>, _ frames: IsomerOutbound<Wire_ServerMessage>, context: IsomerCallContext) async throws {
        try await RemoteSession.serve(messages, frames)
    }
}

/// Not Apple's, so not public: `App.main()` calls it (`iso_process_host_run`, below).
enum HeadlessApp {
    nonisolated(unsafe) static var needsFrame = true

    static func logLine(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    @MainActor
    static func renderIfNeeded() {
        guard needsFrame else { return }
        needsFrame = false
        Runtime.shared.renderFrame()
    }

    /// Runs the installed app headless and serves it; returns never (the
    /// process ends at `quit`, at the end of its standard input when that is
    /// how it's driven, or when it's stopped).
    @MainActor
    static func run() {
        let environment = ProcessInfo.processInfo.environment
        if environment["ISO_DARK"] != nil {
            Runtime.shared.setSystemColorScheme(dark: true)
        }
        RemoteSession.bindIdle()
        let width = Double(environment["ISO_HEADLESS_WIDTH"] ?? "") ?? 390
        let height = Double(environment["ISO_HEADLESS_HEIGHT"] ?? "") ?? 844
        PlatformBridges.current = HeadlessPlatformBridge()
        Runtime.shared.start(host: HeadlessHostBridge(), width: width, height: height)

        // A frame when the app asked for one, at most one a display frame.
        let frames = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { renderIfNeeded() }
        }
        RunLoop.main.add(frames, forMode: .default)
        renderIfNeeded()

        let driver = IsomerAppDriver(
            info: IsomerAppDriver.bundleInfo(platform: "Headless", renderer: "None"),
            renderIfNeeded: { renderIfNeeded() }
        )
        let quit: @Sendable () -> Void = { exit(0) }
        let authorization = IsomerAuthorization.fromEnvironment(environment)
        let server = IsomerAuthorizedServer(HeadlessServer(driving: IsomerDriverServer(driver, onQuit: quit)), authorization: authorization)

        let protocolName = environment["ISO_HEADLESS_PROTOCOL"] ?? ""
        let listening = environment["ISO_DRIVE_LISTEN"].map { $0.split(separator: " ").map(String.init) } ?? []
        for address in listening {
            listen(address, server, authorization: authorization, site: environment["ISO_DRIVE_SITE"])
        }
        if let url = environment["ISO_DRIVER"] {
            Task { @MainActor in
                do {
                    let endpoint = try IsomerRemote.endpoint(url)
                    // ISO_DRIVER_NAME: the name the hub drives it by, as a headful app's.
                    try await driver.dialOut(endpoint.connection, context: endpoint.context(
                        token: environment["ISO_DRIVER_TOKEN"],
                        metadata: environment["ISO_DRIVER_NAME"].map { ["iso-target": $0] } ?? [:]))
                } catch {
                    logLine("isomer: dialling out to \(url): \(error)")
                }
                // The driver's end is the app's.
                exit(0)
            }
        }
        switch protocolName {
        case "binary":
            // One call on standard input and output; the app ends with it.
            Task.detached {
                do {
                    try await IsomerProcessServer.serveStandardIO(server)
                } catch {
                    logLine("isomer: \(error)")
                }
                exit(0)
            }
        case "serve":
            if listening.isEmpty && environment["ISO_DRIVER"] == nil {
                logLine("isomer: ISO_HEADLESS_PROTOCOL=serve, but nothing to serve on (ISO_DRIVE_LISTEN, ISO_DRIVER)")
                exit(2)
            }
        default:
            // JSON lines: a command a line, read on a thread of its own, run on
            // the main actor one at a time, so the app's tasks run between them.
            Thread.detachNewThread {
                var decoding = JSONDecodingOptions()
                decoding.ignoreUnknownFields = true
                while let line = readLine() {
                    if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                    let command = (try? Wire_Command(jsonString: line, options: decoding)) ?? Wire_Command.with { $0.cmd = line }
                    let finished = DispatchSemaphore(value: 0)
                    nonisolated(unsafe) var answer = Wire_Answer()
                    Task { @MainActor in
                        answer = await driver.handle(command)
                        finished.signal()
                    }
                    finished.wait()
                    print((try? answer.jsonString()) ?? #"{"ok": false}"#)
                    fflush(stdout)
                    if command.cmd == "quit" { exit(0) }
                }
                // The input's end ends the app, unless it's also served.
                if listening.isEmpty { exit(0) }
            }
        }
        runMainLoop()
    }

    /// Starts a listener on `address` (grpc://, ws://, unix:), printing
    /// `isomer: listening <url>` on standard error once it does (the port
    /// bound, for 0).
    @MainActor
    static func listen(_ address: String, _ server: any IsomerServer, authorization: IsomerAuthorization, site: String?) {
        if address.hasPrefix("unix:") {
            let path = String(address.dropFirst("unix:".count))
            do {
                try IsomerProcessServer.listen(unixSocket: path, server)
                logLine("isomer: listening unix:\(path)")
            } catch {
                logLine("isomer: \(error)")
                exit(2)
            }
            return
        }
        guard let components = URLComponents(string: address), let scheme = components.scheme else {
            logLine("isomer: can't listen on \(address) (grpc://host:port, ws://host:port or unix:/path)")
            exit(2)
        }
        let host = components.host ?? "127.0.0.1"
        let port = components.port ?? 0
        if !["127.0.0.1", "localhost", "::1"].contains(host) && !authorization.required {
            logLine("isomer: listening on \(host) needs a token (ISO_DRIVE_TOKEN or ISO_DRIVE_TOKEN_FILE)")
            exit(2)
        }
        Task.detached {
            do {
                switch scheme {
                case "grpc":
                    guard #available(macOS 15.0, *) else {
                        logLine("isomer: gRPC needs macOS 15")
                        exit(2)
                    }
                    try await IsomerGRPCServer(server, host: host, port: port).run { bound in
                        logLine("isomer: listening grpc://\(host):\(bound)")
                    }
                case "ws":
                    guard #available(macOS 14, *) else {
                        logLine("isomer: WebSockets need macOS 14")
                        exit(2)
                    }
                    try await IsomerWebSocketServer(server, host: host, port: port, site: site).run { bound in
                        logLine("isomer: listening ws://\(host):\(bound)")
                    }
                default:
                    logLine("isomer: no transport \(scheme) (grpc, ws or unix)")
                    exit(2)
                }
            } catch {
                logLine("isomer: \(address): \(error)")
                exit(2)
            }
        }
    }

    /// The main queue (and with it the main actor) runs on the main thread,
    /// whose stack a deep view tree needs (dispatchMain would hand it to a
    /// worker thread's 512 KB).
    static func runMainLoop() -> Never {
        while true {
            _ = RunLoop.main.run(mode: .default, before: .distantFuture)
        }
    }
}

#endif

/// The headless host's process (shared/swift_ui_core/App.swift): nothing drawn, the UI served until it ends.
@_silgen_name("iso_process_host_run")
func _isoHeadlessProcessHostRun() {
    MainActor.assumeIsolated { HeadlessApp.run() }
}

/// The Isomer module's `Bridge` headless (shared/isomer/Bridge.swift):
/// nothing to bridge to, so the log goes to standard error.
struct HeadlessPlatformBridge: PlatformBridge {
    var platformName: String { "Headless" }
    var rendererName: String { RemoteSession.rendererName }
    func log(_ message: String) { FileHandle.standardError.write(Data(("[iso] " + message + "\n").utf8)) }
    func epochMilliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    func openURL(_ url: String) { FileHandle.standardError.write(Data(("[iso] openURL " + url + "\n").utf8)) }
}
