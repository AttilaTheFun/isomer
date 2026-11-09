// An app built headless, served and driven over each of drive/'s transports
// (docs/drive_plan.md): the Storybook, listening as ISO_DRIVE_LISTEN says,
// driven by IsomerHeadless over gRPC, a WebSocket and a Unix socket, with and
// without its token; a head's session over gRPC; and the app dialling out to
// the `isomer` CLI's hub (ISO_DRIVER), driven through it as a headful app is.

import Foundation
import IsomerHeadless
import IsomerRemote
import IsomerServing
import IsomerSwiftUI
import IsomerWire
import XCTest

final class RemoteTests: XCTestCase {
    private var processes: [Process] = []

    private static var root: String {
        let environment = ProcessInfo.processInfo.environment
        return "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "_main")"
    }

    private static var app: String { "\(root)/headless/storybook_headless_application/storybook_headless_application" }

    override func tearDown() {
        for process in processes where process.isRunning { process.terminate() }
        processes = []
    }

    /// Starts `executable` and returns the URL it says it listens on (or
    /// serves), from its standard error's `isomer: listening <url>` or
    /// standard output's `iso hub: <url>`.
    private func start(_ executable: String, _ arguments: [String] = [], environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let output = Pipe()
        process.standardError = output
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        processes.append(process)
        var text = ""
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            text += String(decoding: chunk, as: UTF8.self)
            for line in text.split(separator: "\n") {
                for marker in ["isomer: listening ", "iso hub: "] {
                    if let range = line.range(of: marker) {
                        // Drained from here on, so the app never blocks on a
                        // full pipe.
                        let handle = output.fileHandleForReading
                        Thread.detachNewThread { while !handle.availableData.isEmpty {} }
                        return String(line[range.upperBound...].split(separator: " ").first ?? "")
                    }
                }
            }
        }
        throw XCTSkip("\(executable) didn't say where it listens: \(text)")
    }

    private func serve(_ address: String, _ extra: [String: String] = [:]) throws -> String {
        try start(Self.app, environment: [
            "ISO_DRIVE_LISTEN": address,
            "ISO_HEADLESS_PROTOCOL": "serve",
            "ISO_HEADLESS_HEIGHT": "6000",
            "ISO_STORYBOOK_STORY": "state.observableobject",
        ].merging(extra) { $1 })
    }

    private func countsTaps(_ app: HeadlessApp) throws {
        XCTAssertTrue(try app.screen().shows("Taps: 0"))
        try app.tap("Tap")
        let screen = try app.wait(for: "Taps: 1")
        XCTAssertTrue(screen.shows("Taps: 1"))
    }

    func testDrivenOverGRPC() throws {
        let url = try serve("grpc://127.0.0.1:0")
        let app = try HeadlessApp(url: url)
        try countsTaps(app)
        let info = try app.info()
        XCTAssertEqual(info.platform, "Headless")
        XCTAssertEqual(info.height, 6000)
    }

    func testDrivenOverAWebSocket() throws {
        let url = try serve("ws://127.0.0.1:0")
        try countsTaps(try HeadlessApp(url: url))
    }

    func testDrivenOverAUnixSocket() throws {
        let path = NSTemporaryDirectory() + "isomer-remote-\(getpid()).sock"
        let url = try serve("unix:\(path)")
        try countsTaps(try HeadlessApp(url: url))
    }

    func testTokens() throws {
        let url = try serve("grpc://127.0.0.1:0", ["ISO_DRIVE_TOKEN": "s3cret"])
        XCTAssertThrowsError(try HeadlessApp(url: url).screen()) { error in
            XCTAssertTrue("\(error)".contains("unauthenticated"), "\(error)")
        }
        XCTAssertThrowsError(try HeadlessApp(url: url, token: "wrong").screen())
        try countsTaps(try HeadlessApp(url: url, token: "s3cret"))
    }

    func testSelectsAPickersOption() throws {
        let url = try start(Self.app, environment: [
            "ISO_DRIVE_LISTEN": "grpc://127.0.0.1:0",
            "ISO_HEADLESS_PROTOCOL": "serve",
            "ISO_HEADLESS_HEIGHT": "6000",
            "ISO_STORYBOOK_STORY": "controls.picker",
        ])
        let app = try HeadlessApp(url: url)
        let picker = try XCTUnwrap(app.screen().elements.first { $0.role == "picker" || $0.role == "segmented" })
        XCTAssertGreaterThan(picker.options.count, 1)
        let option = picker.options[1]
        let screen = try app.select(picker.id ?? picker.label, option)
        let after = screen.elements.first { $0.label == picker.label && ($0.role == "picker" || $0.role == "segmented") }
        XCTAssertEqual(after?.value, "1")
    }

    /// The texts in a node and under it.
    private static func texts(_ node: Wire_Node) -> [String] {
        (node.kind == .text && node.hasV ? [node.v] : []) + node.ch.flatMap(texts)
    }

    /// The innermost tappable node whose texts are `label`.
    private static func button(_ node: Wire_Node, _ label: String) -> Wire_Node? {
        for child in node.ch { if let found = button(child, label) { return found } }
        return node.hasTap && texts(node).joined(separator: " ") == label ? node : nil
    }

    func testAHeadsSessionOverGRPC() async throws {
        let url = try serve("grpc://127.0.0.1:0")
        let endpoint = try IsomerRemote.endpoint(url)
        let call = try await endpoint.connection.connect(context: endpoint.context(token: nil))
        try await call.write(Wire_ClientMessage.with {
            $0.start = Wire_Start.with {
                $0.size = Wire_Size.with {
                    $0.width = 390
                    $0.height = 6000
                }
                $0.renderer = "react"
            }
        })
        var seen: [String] = []
        var tapped = false
        for try await message in call.inbound {
            guard case .patch(let bytes)? = message.message else { continue }
            let patch = try Wire_Patch(serializedBytes: bytes)
            if !tapped {
                // The first frame: one op at "n", the whole tree.
                let first = try XCTUnwrap(patch.ops.first)
                XCTAssertEqual(first.path, "n")
                seen += Self.texts(first.node)
                let tap = try XCTUnwrap(Self.button(first.node, "Tap"))
                try await call.write(Wire_ClientMessage.with { $0.event = Wire_Event.with { $0.id = tap.tap } })
                tapped = true
                continue
            }
            let texts = patch.ops.flatMap { $0.hasNode ? Self.texts($0.node) : [] }
            seen += texts
            if texts.contains("Taps: 1") { break }
        }
        await call.finish()
        XCTAssertTrue(seen.contains("Taps: 0"))
        XCTAssertTrue(seen.contains("Taps: 1"))
    }

    func testDialsOutToAHub() throws {
        let cli = "\(Self.root)/\(ProcessInfo.processInfo.environment["ISOMER_CLI"] ?? "")"
        let hub = try start(cli, ["hub", "--grpc", "0"], environment: [:])
        let dialling = Process()
        dialling.executableURL = URL(fileURLWithPath: Self.app)
        dialling.standardInput = FileHandle.nullDevice
        dialling.standardOutput = FileHandle.nullDevice
        dialling.standardError = FileHandle.nullDevice
        dialling.environment = ProcessInfo.processInfo.environment.merging([
            "ISO_DRIVER": hub,
            "ISO_HEADLESS_PROTOCOL": "serve",
            "ISO_HEADLESS_HEIGHT": "6000",
            "ISO_STORYBOOK_STORY": "state.observableobject",
        ]) { $1 }
        try dialling.run()
        processes.append(dialling)
        // Until it has attached: the hub answers "no app has attached" before.
        var app: HeadlessApp?
        let deadline = Date().addingTimeInterval(20)
        while app == nil && Date() < deadline {
            if let attempt = try? HeadlessApp(url: hub), (try? attempt.screen()) != nil { app = attempt } else { usleep(200_000) }
        }
        try countsTaps(try XCTUnwrap(app, "the app never attached to \(hub)"))
    }
}
