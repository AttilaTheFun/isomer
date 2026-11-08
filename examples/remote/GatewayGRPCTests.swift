// The gateway's gRPC services end to end (session_service.proto): the
// headless Storybook behind //remote:gateway, driven by Headless.Drive and
// held as a remote session by Session.Connect, over plaintext HTTP/2 on a
// loopback port.

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import RemoteServiceClient
import RemoteWire
import XCTest

final class GatewayGRPCTests: XCTestCase {
    private var gateway: Process?
    private var port = 0

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        let root = "\(environment["TEST_SRCDIR"] ?? "")/\(environment["TEST_WORKSPACE"] ?? "_main")"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "\(root)/remote/gateway")
        process.arguments = [
            "--app", "\(root)/headless/storybook_headless_application/storybook_headless_application",
            "--port", "0", "--grpc-port", "0",
        ]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        gateway = process
        // "gateway: ws://127.0.0.1:<port>/session grpc 127.0.0.1:<port>"
        var line = Data()
        while !line.contains(0x0A) {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            line.append(chunk)
        }
        let text = String(decoding: line, as: UTF8.self)
        port = Int(text.split(separator: ":").last?.prefix { $0.isNumber } ?? "") ?? 0
        XCTAssertNotEqual(port, 0, "the gateway said: \(text)")
    }

    override func tearDown() {
        gateway?.terminate()
        gateway?.waitUntilExit()
    }

    private func withClient<Result: Sendable>(_ body: (GRPCClient<HTTP2ClientTransport.Posix>) async throws -> Result) async throws -> Result {
        try await withGRPCClient(
            transport: .http2NIOPosix(target: .ipv4(address: "127.0.0.1", port: port), transportSecurity: .plaintext)
        ) { client in
            try await body(client)
        }
    }

    private static func command(_ cmd: String, target: String = "", text: String = "") -> Wire_Command {
        Wire_Command.with {
            $0.cmd = cmd
            $0.target = target
            $0.text = text
        }
    }

    func testHeadlessDrive() async throws {
        let answers = try await withClient { client in
            try await Wire_Headless.Client(wrapping: client).drive(
                metadata: ["iso_storybook_story": "state.observableobject", "iso_headless_height": "6000"],
                requestProducer: { writer in
                    try await writer.write(Self.command("ls"))
                    try await writer.write(Self.command("tap", target: "Tap"))
                    try await writer.write(Self.command("wait", text: "Taps: 1"))
                    try await writer.write(Self.command("tap", target: "No such button"))
                    try await writer.write(Self.command("quit"))
                },
                onResponse: { response in
                    var answers: [Wire_Answer] = []
                    for try await answer in response.messages { answers.append(answer) }
                    return answers
                }
            )
        }
        XCTAssertEqual(answers.count, 5)
        guard answers.count == 5 else { return }
        XCTAssertTrue(answers[0].ok)
        XCTAssertTrue(answers[0].screen.texts.contains("Taps: 0"))
        XCTAssertTrue(answers[2].ok, answers[2].error)
        XCTAssertTrue(answers[2].screen.texts.contains("Taps: 1"))
        XCTAssertFalse(answers[3].ok)
        XCTAssertEqual(answers[3].error, "no button No such button")
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

    func testSessionConnect() async throws {
        let (outbox, mail) = AsyncStream<Wire_ClientMessage>.makeStream()
        let seen = try await withClient { client in
            try await Wire_Session.Client(wrapping: client).connect(
                requestProducer: { writer in
                    for await message in outbox { try await writer.write(message) }
                },
                onResponse: { response in
                    mail.yield(Wire_ClientMessage.with {
                        $0.start = Wire_Start.with {
                            $0.size = Wire_Size.with {
                                $0.width = 390
                                $0.height = 6000
                            }
                            $0.environment = ["ISO_STORYBOOK_STORY": "state.observableobject"]
                        }
                    })
                    var seen: [String] = []
                    for try await message in response.messages {
                        guard case .patch(let bytes)? = message.message else { continue }
                        let patch = try Wire_Patch(serializedBytes: bytes)
                        if seen.isEmpty {
                            // The first frame: one op at "n", the whole tree.
                            guard let first = patch.ops.first, first.path == "n", first.hasNode else { break }
                            seen.append(contentsOf: Self.texts(first.node))
                            guard let tap = Self.button(first.node, "Tap") else { break }
                            mail.yield(Wire_ClientMessage.with {
                                $0.event = Wire_Event.with { $0.id = tap.tap }
                            })
                            continue
                        }
                        // Later frames change what the tap changed.
                        let texts = patch.ops.flatMap { $0.hasNode ? Self.texts($0.node) : [] }
                        seen.append(contentsOf: texts)
                        if texts.contains("Taps: 1") { break }
                    }
                    mail.finish()
                    return seen
                }
            )
        }
        XCTAssertTrue(seen.contains("Taps: 0"), "the first frame: \(seen.prefix(40))")
        XCTAssertTrue(seen.contains("Taps: 1"), "after the tap: \(seen.suffix(40))")
    }
}
