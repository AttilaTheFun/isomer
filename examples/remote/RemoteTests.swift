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
        try await headsSession(renderer: "dom")
    }

    /// Apple's tree renderer as the head (apple/libraries/remote_head):
    /// the app binds its SwiftUI renderer, whose patches are the same tree.
    func testASwiftUIHeadsSession() async throws {
        try await headsSession(renderer: "swiftui")
    }

    /// A head's session: its first frame the whole tree, a tap on its
    /// button, and the frame that tap made.
    private func headsSession(renderer: String) async throws {
        let url = try serve("grpc://127.0.0.1:0")
        let endpoint = try IsomerRemote.endpoint(url)
        let call = try await endpoint.connection.connect(context: endpoint.context(token: nil))
        try await call.write(Wire_ClientMessage.with {
            $0.start = Wire_Start.with {
                $0.size = Wire_Size.with {
                    $0.width = 390
                    $0.height = 6000
                }
                $0.renderer = renderer
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

    // MARK: A compact split view's Back, as Apple's head sends it

    /// The tree a head holds, each frame's patch applied as the tree
    /// renderer applies it (apple/libraries/swift_ui_tree/FlatPatchTree.swift):
    /// read by the test while a task applies the frames.
    private final class HeadTree: @unchecked Sendable {
        private let lock = NSLock()
        private var root: Wire_Node?

        var current: Wire_Node? {
            lock.lock()
            defer { lock.unlock() }
            return root
        }

        func apply(_ patch: Wire_Patch) {
            lock.lock()
            defer { lock.unlock() }
            for op in patch.ops { root = Self.apply(op, to: root) }
        }

        private static func apply(_ op: Wire_PatchOp, to root: Wire_Node?) -> Wire_Node? {
            let segments = op.path.split(separator: ".").dropFirst().compactMap { Int($0) }
            func edit(_ node: inout Wire_Node, _ rest: ArraySlice<Int>) {
                if let index = rest.first {
                    guard index < node.ch.count else { return }
                    edit(&node.ch[index], rest.dropFirst())
                } else if op.reorder || !op.order.isEmpty {
                    // Kept children by their old index, -1 the next insert.
                    let old = node.ch
                    var inserted = 0
                    node.ch = op.order.compactMap { index in
                        if index >= 0, Int(index) < old.count { return old[Int(index)] }
                        defer { inserted += 1 }
                        return inserted < op.inserts.count ? op.inserts[inserted] : nil
                    }
                } else if op.attrsOnly {
                    let children = node.ch
                    node = op.node
                    node.ch = children
                } else {
                    node = op.node
                }
            }
            guard var node = root else { return segments.isEmpty ? op.node : nil }
            edit(&node, segments[...])
            return node
        }
    }

    private static func param(_ node: Wire_Node, _ key: String) -> String? {
        node.params.first { $0.key == key }?.value
    }

    /// The first node, in document order, that `matches`.
    private static func find(_ node: Wire_Node, _ matches: (Wire_Node) -> Bool) -> Wire_Node? {
        if matches(node) { return node }
        for child in node.ch { if let found = find(child, matches) { return found } }
        return nil
    }

    private static func isHostView(_ node: Wire_Node, _ kind: String) -> Bool {
        node.kind == .hostView && node.hasView && node.view == kind
    }

    /// A head's session at a phone's size under Apple's tree renderer
    /// ("swiftui": navigation as `navsplit`/`navstack` nodes, the head's own
    /// NavigationSplitView choosing the column), its frames applied to a
    /// tree as they come.
    private func phoneHeadSession(story: String?) async throws
        -> (call: IsomerCall<Wire_ClientMessage, Wire_ServerMessage>, tree: HeadTree, reading: Task<Void, Never>) {
        let url = try serve("grpc://127.0.0.1:0", ["ISO_STORYBOOK_STORY": story ?? ""])
        let endpoint = try IsomerRemote.endpoint(url)
        let call = try await endpoint.connection.connect(context: endpoint.context(token: nil))
        try await call.write(Wire_ClientMessage.with {
            $0.start = Wire_Start.with {
                $0.size = Wire_Size.with {
                    // A phone's width, and tall enough that the list
                    // builds every row (its window is the rows on screen).
                    $0.width = 390
                    $0.height = 6000
                }
                $0.renderer = "swiftui"
            }
        })
        let tree = HeadTree()
        let reading = Task {
            do {
                for try await message in call.inbound {
                    guard case .patch(let bytes)? = message.message,
                          let patch = try? Wire_Patch(serializedBytes: bytes) else { continue }
                    tree.apply(patch)
                }
            } catch {}
        }
        return (call, tree, reading)
    }

    /// The split view's node once `condition` holds of it (and the tree it
    /// is in), within a few seconds.
    private func waitForSplit(_ tree: HeadTree, _ what: String,
                       until condition: (Wire_Node, Wire_Node) -> Bool) async throws -> Wire_Node {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let root = tree.current, let split = Self.find(root, { Self.isHostView($0, "navsplit") }),
               condition(split, root) {
                return split
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let split = tree.current.flatMap { Self.find($0, { Self.isHostView($0, "navsplit") }) }
        XCTFail("\(what): never; the split's params: \(split.map { $0.params.map { "\($0.key)=\($0.value)" } } ?? [])")
        throw CancellationError()
    }

    /// The column a split view shows on a phone, as its params ask the head.
    private static func compactColumn(_ split: Wire_Node) -> String {
        param(split, "compact") ?? "sidebar"
    }

    /// The detail column's own navigation stack (the Storybook's), whose
    /// bar the head draws: its title.
    private static func detailTitle(_ split: Wire_Node) -> String? {
        guard let detail = split.ch.last,
              let stack = find(detail, { isHostView($0, "navstack") }) else { return nil }
        return param(stack, "title")
    }

    /// A row the sidebar's list shows selected.
    private static func selectedRow(_ split: Wire_Node) -> Wire_Node? {
        guard let sidebar = split.ch.first else { return nil }
        return find(sidebar) { param($0, "selected") == "1" }
    }

    /// The head's Back on a phone (its NavigationSplitView's back button, or
    /// the edge swipe: NavSplitNativeBody's "compact:sidebar:back"), and what
    /// the app answers: the list again, asked of the head with a new
    /// request (`compactTick`), its selection cleared, and a detail column
    /// with neither the story nor the story's title in its bar.
    private func goesBackToTheList(_ call: IsomerCall<Wire_ClientMessage, Wire_ServerMessage>, _ tree: HeadTree,
                                   from split: Wire_Node) async throws {
        let tickBefore = Self.param(split, "compactTick")
        try await call.write(Wire_ClientMessage.with {
            $0.event = Wire_Event.with {
                $0.id = split.edit
                $0.value = "compact:sidebar:back"
            }
        })
        let back = try await waitForSplit(tree, "the list after Back") { split, _ in
            Self.compactColumn(split) == "sidebar" && Self.selectedRow(split) == nil
        }
        XCTAssertNotEqual(Self.param(back, "compactTick"), tickBefore, "Back asks the head again")
        XCTAssertFalse(Self.texts(back.ch.last ?? Wire_Node()).contains("Taps: 0"))
        // The detail, unseen on a phone now, has no story: its bar no title
        // (SwiftUI's title is the shown content's, and the placeholder sets
        // none), not the story's left from before.
        XCTAssertEqual(Self.detailTitle(back) ?? "", "", "the detail's title after Back")
        // And it stays there: nothing in the next frames moves the head on.
        try await Task.sleep(for: .milliseconds(500))
        let settled = try XCTUnwrap(tree.current.flatMap { Self.find($0, { Self.isHostView($0, "navsplit") }) })
        XCTAssertEqual(Self.compactColumn(settled), "sidebar")
        XCTAssertEqual(Self.param(settled, "compactTick"), Self.param(back, "compactTick"))
    }

    /// A story opened at launch (ISO_STORYBOOK_STORY) under Apple's head:
    /// the split view starts on its detail, and Back goes to the list.
    func testASwiftUIHeadsBackFromAStoryOpenedAtLaunch() async throws {
        let (call, tree, reading) = try await phoneHeadSession(story: "state.observableobject")
        defer { reading.cancel() }
        let split = try await waitForSplit(tree, "the story at launch") { split, root in
            Self.compactColumn(split) == "detail" && Self.texts(root).contains("Taps: 0")
        }
        XCTAssertEqual(Self.detailTitle(split), "ObservableObject")
        try await goesBackToTheList(call, tree, from: split)
        await call.finish()
    }

    /// The same story picked from the list, then Back: what the launch's
    /// case must match.
    func testASwiftUIHeadsBackFromAStoryPickedFromTheList() async throws {
        let (call, tree, reading) = try await phoneHeadSession(story: nil)
        defer { reading.cancel() }
        let list = try await waitForSplit(tree, "the list at launch") { split, root in
            Self.compactColumn(split) == "sidebar" && Self.button(root, "ObservableObject") != nil
        }
        let root = try XCTUnwrap(tree.current)
        let row = try XCTUnwrap(Self.button(root, "ObservableObject"))
        XCTAssertNil(Self.selectedRow(list))
        // The native list's selection sends the row's tap (ListBody).
        try await call.write(Wire_ClientMessage.with { $0.event = Wire_Event.with { $0.id = row.tap } })
        let split = try await waitForSplit(tree, "the story picked") { split, root in
            Self.compactColumn(split) == "detail" && Self.texts(root).contains("Taps: 0")
        }
        XCTAssertEqual(Self.detailTitle(split), "ObservableObject")
        try await goesBackToTheList(call, tree, from: split)
        await call.finish()
    }

    /// The app's own `.preferredColorScheme` reaches a head apart from the
    /// scheme it resolves to (platform command "preferredColorScheme"), and
    /// "" when the app lets go of it: what Apple's head applies to its
    /// window, so the system's appearance reaches the app again.
    func testReportsThePreferredColorScheme() async throws {
        let url = try serve("grpc://127.0.0.1:0", ["ISO_STORYBOOK_STORY": "state.preferredcolorscheme"])
        let endpoint = try IsomerRemote.endpoint(url)
        let call = try await endpoint.connection.connect(context: endpoint.context(token: nil))
        try await call.write(Wire_ClientMessage.with {
            $0.start = Wire_Start.with {
                $0.size = Wire_Size.with {
                    $0.width = 390
                    $0.height = 6000
                }
                $0.renderer = "swiftui"
            }
        })
        var taps: [String: String] = [:]
        var reported: [String] = []
        for try await message in call.inbound {
            switch message.message {
            case .patch(let bytes) where taps.isEmpty:
                let first = try XCTUnwrap(try Wire_Patch(serializedBytes: bytes).ops.first)
                for label in ["System", "Dark"] { taps[label] = try XCTUnwrap(Self.button(first.node, label)).tap }
                try await call.write(Wire_ClientMessage.with { $0.event = Wire_Event.with { $0.id = taps["Dark"]! } })
            case .command(let command) where command.key == "preferredColorScheme":
                reported.append(command.value)
                if command.value == "dark" {
                    try await call.write(Wire_ClientMessage.with { $0.event = Wire_Event.with { $0.id = taps["System"]! } })
                }
            default:
                break
            }
            if reported.last == "" { break }
        }
        await call.finish()
        XCTAssertEqual(reported, ["dark", ""])
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
