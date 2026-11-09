// The app's own driver, answered in its own process and synchronously: what
// a test bundle hosted in the app drives it with (HeadlessApp.hosted), no
// network and no thread hop, as XCUITest's calls are synchronous. A headful
// build's driver registers itself here when its host starts
// (HeadfulDriver.swift, drive/apple), whether or not it also dials out to a
// hub; remote drivers reach it asynchronously through the transports
// (IsomerGRPCServer, IsomerWebSocketServer, a hub) as before.

import Foundation
import IsomerWire

@MainActor
public final class IsomerLocalServer {
    /// The app's own, once its host has started its driver.
    public private(set) static var current: IsomerLocalServer?

    private let handle: @MainActor (Wire_Command) async -> Wire_Answer

    public init(_ handle: @escaping @MainActor (Wire_Command) async -> Wire_Answer) {
        self.handle = handle
    }

    /// Makes `server` the app's own (a host's driver, as it starts).
    public static func register(_ server: IsomerLocalServer) {
        current = server
    }

    /// One command and its answer, on the main thread, where the caller is:
    /// the driver runs as the main actor's work does while this turns the
    /// main run loop, as XCUITest's waits do, so the app keeps drawing and
    /// its tasks keep running meanwhile.
    public func send(_ command: Wire_Command) -> Wire_Answer {
        let answer = Answer()
        let handle = handle
        Task { @MainActor in answer.value = await handle(command) }
        while answer.value == nil {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return answer.value!
    }

    /// The app's own driver, waiting up to `timeout` seconds (turning the
    /// main run loop) for its host to start it.
    public static func waitForCurrent(timeout: Double) -> IsomerLocalServer? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while current == nil, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        return current
    }

    private final class Answer {
        var value: Wire_Answer?
    }
}
