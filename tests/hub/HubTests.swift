// IsomerHub's apps coming and going, with an app of the test's own: its
// answers a stream the test writes, its commands a stream the test reads.

import IsomerServing
import IsomerWire
import XCTest

final class HubTests: XCTestCase {
    /// What the hub reported (attached, detached).
    final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    /// An app attached to `hub` as `name`, answering each command with its
    /// name in `error` while `answers` (its stream's writer) is open.
    func attach(_ name: String, to hub: IsomerHub, answering: Bool = true)
        -> (call: Task<Void, any Error>, answers: AsyncThrowingStream<Wire_Answer, any Error>.Continuation, app: Task<Void, Never>)
    {
        let (answers, writer) = AsyncThrowingStream<Wire_Answer, any Error>.makeStream()
        let (commands, commandWriter) = AsyncStream<Wire_Command>.makeStream()
        let call = Task {
            try await hub.attach(answers, IsomerOutbound { commandWriter.yield($0) },
                                 context: IsomerCallContext(metadata: ["iso-target": name]))
        }
        var hello = Wire_Answer()
        hello.info.name = name
        writer.yield(hello)
        let app = Task {
            for await command in commands where answering {
                var answer = Wire_Answer()
                answer.ok = true
                answer.error = command.cmd
                writer.yield(answer)
            }
        }
        return (call, writer, app)
    }

    func testAnAppThatGoesIsDetachedAtOnce() async throws {
        let reports = Reports()
        let hub = IsomerHub(report: { reports.add($0) })
        let (call, answers, app) = attach("app", to: hub)
        defer { app.cancel() }
        let attached = await hub.waitUntilAttached("app", timeout: 5)
        XCTAssertTrue(attached)
        var ls = Wire_Command()
        ls.cmd = "ls"
        let answer = try await hub.send(ls, to: "app")
        XCTAssertEqual(answer.error, "ls")
        // The app goes, and nothing is sent it: it is detached anyway.
        answers.finish()
        try await call.value
        let names = await hub.names
        XCTAssertEqual(names, [])
        XCTAssertEqual(reports.all.last, "detached: app")
        do {
            _ = try await hub.send(ls, to: "app")
            XCTFail("a command to an app that went")
        } catch {}
    }

    func testACommandWaitingFailsWhenTheAppGoes() async throws {
        let hub = IsomerHub()
        let (call, answers, app) = attach("quiet", to: hub, answering: false)
        defer { app.cancel() }
        let attached = await hub.waitUntilAttached("quiet", timeout: 5)
        XCTAssertTrue(attached)
        var ls = Wire_Command()
        ls.cmd = "ls"
        let sent = Task { try await hub.send(ls, to: "quiet") }
        try await Task.sleep(nanoseconds: 200_000_000)
        answers.finish()
        do {
            _ = try await sent.value
            XCTFail("an answer from an app that went")
        } catch let error as IsomerCallError {
            XCTAssertEqual(error.code, .unavailable)
        }
        try await call.value
    }

    func testAnAppAttachingAgainReplacesTheOneBefore() async throws {
        let hub = IsomerHub()
        let first = attach("app", to: hub)
        let firstAttached = await hub.waitUntilAttached("app", timeout: 5)
        XCTAssertTrue(firstAttached)
        let second = attach("app", to: hub)
        defer { first.app.cancel(); second.app.cancel() }
        // The first's connection ending later detaches nothing.
        try await Task.sleep(nanoseconds: 200_000_000)
        first.answers.finish()
        try await first.call.value
        var ls = Wire_Command()
        ls.cmd = "ls"
        let answer = try await hub.send(ls, to: "app")
        XCTAssertEqual(answer.error, "ls")
        let names = await hub.names
        XCTAssertEqual(names, ["app"])
        second.answers.finish()
        try await second.call.value
    }

    /// `apps`, sent to the hub with no target, answers with every app
    /// attached by name (the iso CLI's `iso apps`, and what `--all` drives);
    /// with several attached, a command with no target names none.
    func testAppsAnswersWithEveryAppAttached() async throws {
        let hub = IsomerHub()
        let ios = attach("ios", to: hub)
        let web = attach("web", to: hub)
        defer { ios.app.cancel(); web.app.cancel() }
        let iosAttached = await hub.waitUntilAttached("ios", timeout: 5)
        let webAttached = await hub.waitUntilAttached("web", timeout: 5)
        XCTAssertTrue(iosAttached && webAttached)
        let (commands, commandWriter) = AsyncThrowingStream<Wire_Command, any Error>.makeStream()
        let (answers, answerWriter) = AsyncThrowingStream<Wire_Answer, any Error>.makeStream()
        let drive = Task {
            try await hub.drive(commands, IsomerOutbound { answerWriter.yield($0) }, context: IsomerCallContext())
        }
        var apps = Wire_Command()
        apps.cmd = "apps"
        commandWriter.yield(apps)
        var iterator = answers.makeAsyncIterator()
        let answer = try await iterator.next()
        XCTAssertEqual(answer?.apps.map(\.name), ["ios", "web"])
        XCTAssertEqual(answer?.apps.map(\.info.name), ["ios", "web"])
        var ls = Wire_Command()
        ls.cmd = "ls"
        commandWriter.yield(ls)
        do {
            try await drive.value
            XCTFail("a command with no target went somewhere with two apps attached")
        } catch {
            XCTAssertTrue("\(error)".contains("several apps attached"), "\(error)")
        }
    }
}
