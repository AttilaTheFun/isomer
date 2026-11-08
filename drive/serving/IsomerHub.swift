// A hub headful apps dial out to (session_service.proto's Driver.Attach),
// driven by name (Headless.Drive with `iso-target`, or the only one
// attached). The `isomer hub` command serves one on a transport; a test
// driving headful apps holds one in its own process (IsomerHeadless).

import Foundation
import IsomerWire

/// Apps that dialled out, each driven a command at a time.
public actor IsomerHub: IsomerServer {
    struct Attached {
        let commands: IsomerOutbound<Wire_Command>
        var answers: IsomerInbound<Wire_Answer>.AsyncIterator
    }

    public let authorization: IsomerAuthorization
    /// Told of each app that attaches or goes ("attached: <name> (<platform>,
    /// <renderer>)", "detached: <name>").
    private let report: @Sendable (String) -> Void
    var attached: [String: Attached] = [:]
    var holding: [String: CheckedContinuation<Void, Never>] = [:]

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
        await register(name, Attached(commands: commands, answers: iterator), hello.info)
        // Held open until the app goes: the call ends when its answers do.
        await held(name)
    }

    func register(_ name: String, _ app: Attached, _ info: Wire_Info) {
        attached[name] = app
        report("attached: \(name) (\(info.platform), \(info.renderer))")
    }

    func held(_ name: String) async {
        await withCheckedContinuation { holding[name] = $0 }
    }

    func release(_ name: String) {
        attached[name] = nil
        holding.removeValue(forKey: name)?.resume()
        report("detached: \(name)")
    }

    /// One command to an attached app, and its answer.
    public func send(_ command: Wire_Command, to name: String) async throws -> Wire_Answer {
        guard var app = attached[name] else { throw IsomerCallError(.notFound, "no app attached as \(name)") }
        try await app.commands.write(command)
        let answer: Wire_Answer?
        do {
            answer = try await app.answers.next()
        } catch {
            release(name)
            throw error
        }
        guard let answer else {
            release(name)
            throw IsomerCallError(.unavailable, "\(name) has gone")
        }
        attached[name] = app
        return answer
    }

    func target(for context: IsomerCallContext) throws -> String {
        if let target = context.target { return target }
        guard attached.count == 1, let only = attached.keys.first else {
            throw IsomerCallError(.notFound, attached.isEmpty
                ? "no app has attached" : "several apps attached (\(attached.keys.sorted().joined(separator: ", "))): name one")
        }
        return only
    }

    public nonisolated func drive(_ commands: IsomerInbound<Wire_Command>, _ answers: IsomerOutbound<Wire_Answer>, context: IsomerCallContext) async throws {
        try authorization.check(context)
        let name = try await target(for: context)
        for try await command in commands {
            try await answers.write(try await send(command, to: name))
            if command.cmd == "quit" { return }
        }
    }
}
