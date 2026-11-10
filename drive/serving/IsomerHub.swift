// A hub headful apps dial out to (session_service.proto's Driver.Attach),
// driven by name (Headless.Drive with `iso-target`, or the only one
// attached). `apps`, sent to the hub with no target, answers with the apps
// attached (Answer.apps). The `iso hub` command serves one on a transport; a test
// driving headful apps holds one in its own process (IsomerHeadless).

import Foundation
import IsomerWire

/// Apps that dialled out, each driven a command at a time. Each app's
/// answers are read as they come, so an app that goes (quit, crashed, its
/// connection dropped) is detached then, not at the next command sent it.
public actor IsomerHub: IsomerServer {
    struct Attached {
        /// Which attachment under the name this is (an app relaunched under
        /// it is a newer one).
        let id: Int
        let commands: IsomerOutbound<Wire_Command>
        /// What the app said it is when it attached.
        let info: Wire_Info
        /// Commands sent, waiting for their answers, in order.
        var waiting: [CheckedContinuation<Wire_Answer, any Error>] = []
        /// Answers come before a command was waiting for them.
        var pending: [Wire_Answer] = []
    }

    public let authorization: IsomerAuthorization
    /// Told of each app that attaches or goes ("attached: <name> (<platform>,
    /// <renderer>)", "detached: <name>").
    private let report: @Sendable (String) -> Void
    var attached: [String: Attached] = [:]
    var attachments = 0

    public init(authorization: IsomerAuthorization = .init(), report: @escaping @Sendable (String) -> Void = { _ in }) {
        self.authorization = authorization
        self.report = report
    }

    /// The names of the apps attached now.
    public var names: [String] { attached.keys.sorted() }

    /// Waits until an app named `name` has attached, for up to `timeout`
    /// seconds; whether it did.
    public func waitUntilAttached(_ name: String, timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while attached[name] == nil {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    public nonisolated func attach(_ answers: IsomerInbound<Wire_Answer>, _ commands: IsomerOutbound<Wire_Command>, context: IsomerCallContext) async throws {
        try authorization.check(context)
        var iterator = answers.makeAsyncIterator()
        guard let hello = try await iterator.next(), hello.hasInfo else {
            throw IsomerCallError(.invalidArgument, "an app attaching says who it is first")
        }
        let name = context.target ?? hello.info.name
        let id = await register(name, commands, hello.info)
        // The call lasts as long as the app's answers do, each handed to the
        // command waiting for it; when they end the app is detached.
        do {
            while let answer = try await iterator.next() { await deliver(answer, to: name, id) }
            await gone(name, id, nil)
        } catch {
            await gone(name, id, error)
        }
    }

    func register(_ name: String, _ commands: IsomerOutbound<Wire_Command>, _ info: Wire_Info) -> Int {
        // An app attaching again under its name (relaunched) replaces the
        // one before: commands go to the new one, and the old one's call
        // ends with its connection, detaching nothing.
        attachments += 1
        if let old = attached[name] { fail(old, "\(name) attached again") }
        attached[name] = Attached(id: attachments, commands: commands, info: info)
        report("attached: \(name) (\(info.platform), \(info.renderer))")
        return attachments
    }

    func deliver(_ answer: Wire_Answer, to name: String, _ id: Int) {
        guard var app = attached[name], app.id == id else { return }
        if app.waiting.isEmpty {
            app.pending.append(answer)
        } else {
            app.waiting.removeFirst().resume(returning: answer)
        }
        attached[name] = app
    }

    func gone(_ name: String, _ id: Int, _ error: (any Error)?) {
        guard let app = attached[name], app.id == id else { return }
        attached[name] = nil
        fail(app, "\(name) has gone" + (error.map { ": \($0)" } ?? ""))
        report("detached: \(name)")
    }

    private func fail(_ app: Attached, _ message: String) {
        for waiting in app.waiting { waiting.resume(throwing: IsomerCallError(.unavailable, message)) }
    }

    /// One command to an attached app, and its answer.
    public func send(_ command: Wire_Command, to name: String) async throws -> Wire_Answer {
        guard let app = attached[name] else { throw IsomerCallError(.notFound, "no app attached as \(name)") }
        try await app.commands.write(command)
        // The app may have gone, or answered, while the command was sent.
        guard var current = attached[name], current.id == app.id else {
            throw IsomerCallError(.unavailable, "\(name) has gone")
        }
        if !current.pending.isEmpty {
            let answer = current.pending.removeFirst()
            attached[name] = current
            return answer
        }
        return try await withCheckedThrowingContinuation { continuation in
            attached[name]?.waiting.append(continuation)
        }
    }

    func target(for context: IsomerCallContext) throws -> String {
        if let target = context.target { return target }
        guard attached.count == 1, let only = attached.keys.first else {
            throw IsomerCallError(.notFound, attached.isEmpty
                ? "no app has attached" : "several apps attached (\(attached.keys.sorted().joined(separator: ", "))): name one")
        }
        return only
    }

    /// The hub's own answer to `apps`: every app attached, by name.
    public func apps() -> Wire_Answer {
        var answer = Wire_Answer()
        answer.ok = true
        answer.apps = attached.keys.sorted().map { name in
            var attachment = Wire_Attachment()
            attachment.name = name
            attachment.info = attached[name]!.info
            return attachment
        }
        return answer
    }

    public nonisolated func drive(_ commands: IsomerInbound<Wire_Command>, _ answers: IsomerOutbound<Wire_Answer>, context: IsomerCallContext) async throws {
        try authorization.check(context)
        // The app is named once a command needs one: `apps` asks the hub.
        var name: String?
        for try await command in commands {
            if command.cmd == "apps", context.target == nil {
                try await answers.write(await apps())
                continue
            }
            if name == nil { name = try await target(for: context) }
            try await answers.write(try await send(command, to: name!))
            if command.cmd == "quit" { return }
        }
    }
}
