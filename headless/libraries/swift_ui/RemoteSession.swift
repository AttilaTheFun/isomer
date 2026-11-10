// A head drawing the headless app (shared/wire/session.proto's Session.Connect,
// over whichever transport the app is served on): the head (a browser's React,
// an Android phone's Compose: nothing of the app but its renderer) sends what
// the person does; the app answers with each frame as a tree.proto Patch, the
// same patches the component-system renderers take in process, and what it
// asks of the platform. One head at a time; the driver keeps working while it
// draws, on the same screen.
//
// The app lays nothing out by the head's fonts: text is measured as the
// headless host measures it (a fixed-width estimate), and every image is
// ready. The head's renderer lays out the tree as it would in process; what
// the app itself computes from a measurement (a GeometryReader of text) is
// approximate.

#if !canImport(WASILibc)

internal import IsomerServing
internal import IsomerSwiftUI
internal import IsomerWire
internal import SwiftUI
import Foundation

enum RemoteSession {
    /// The renderer drawing the app: a head's, or none.
    nonisolated(unsafe) static var rendererName = "None"
    /// Where the head's messages go, while one is drawing.
    nonisolated(unsafe) static var sink: AsyncStream<Wire_ServerMessage>.Continuation?

    /// One message to the head drawing the app, if one is.
    static func send(_ build: (inout Wire_ServerMessage) -> Void) {
        guard let sink else { return }
        var message = Wire_ServerMessage()
        build(&message)
        sink.yield(message)
    }

    /// No head: frames go through the headless head (HeadlessHead.swift),
    /// which lays each out as the self-drawing renderer does, draws nothing,
    /// and keeps the layout for tests.
    @MainActor
    static func bindIdle() {
        let head = HeadlessHead()
        HeadlessHead.current = head
        Renderer.bind(head)
        rendererName = "None"
    }

    /// A head's session: its `start`, then its events until it goes.
    static func serve(_ messages: IsomerInbound<Wire_ClientMessage>, _ frames: IsomerOutbound<Wire_ServerMessage>) async throws {
        var incoming = messages.makeAsyncIterator()
        guard let first = try await incoming.next(), case .start(let start)? = first.message else {
            throw IsomerCallError(.invalidArgument, "a session's first message is its start")
        }
        let (outgoing, continuation) = AsyncStream<Wire_ServerMessage>.makeStream()
        try await MainActor.run {
            guard sink == nil else { throw IsomerCallError(.unavailable, "a head is drawing this app already") }
            sink = continuation
            begin(start)
        }
        let forwarding = Task {
            for await message in outgoing { try? await frames.write(message) }
        }
        do {
            while let message = try await incoming.next() {
                await MainActor.run { receive(message) }
            }
        } catch {
            // The head went: its session is over either way.
        }
        await MainActor.run {
            sink = nil
            continuation.finish()
            bindIdle()
        }
        await forwarding.value
    }

    /// The head's renderer bound (a new one: its first frame is the whole
    /// tree), at the head's size and appearance.
    @MainActor
    static func begin(_ start: Wire_Start) {
        let compose = start.renderer == "compose"
        rendererName = compose ? "Compose" : "React"
        HeadlessHead.current = nil
        let send: ([UInt8]) -> Void = { patch in RemoteSession.send { $0.patch = Data(patch) } }
        Renderer.bind(compose ? JetpackComposeRenderer(send: send) : ReactRenderer(send: send))
        let runtime = Runtime.shared
        runtime.setSystemColorScheme(dark: start.dark)
        if start.displayScale > 0 { runtime.displayScale = CGFloat(start.displayScale) }
        if start.hasSize, start.size.width > 0, start.size.height > 0 {
            runtime.resize(width: start.size.width, height: start.size.height)
        }
        runtime.setNeedsRender()
        HeadlessApp.renderIfNeeded()
    }

    /// One of the head's messages, as the in-process hosts' entry points
    /// take it (wasm/libraries/swift_ui/WebBridge.swift's `iso…` exports).
    @MainActor
    static func receive(_ message: Wire_ClientMessage) {
        let runtime = Runtime.shared
        switch message.message {
        case .start, nil:
            break
        case .resize(let size):
            runtime.resize(width: size.width, height: size.height)
        case .event(let event):
            runtime.hostViewEvent(id: event.id, value: event.value)
        case .key(let event):
            _ = runtime.keyPressEvent(id: event.id, value: event.value)
        case .pointer(let pointer):
            runtime.pointerEvent(kind: pointer.phase.rawValue, x: pointer.x, y: pointer.y)
        case .wheel(let wheel):
            runtime.wheelEvent(x: wheel.x, y: wheel.y, deltaX: wheel.deltaX, deltaY: wheel.deltaY)
        case .text(let input):
            switch input.change {
            case .edited, .UNRECOGNIZED: runtime.textChanged(input.text)
            case .submitted: runtime.textSubmitted()
            case .ended: runtime.textInputEnded()
            }
        case .dark(let dark):
            runtime.setSystemColorScheme(dark: dark)
        case .displayScale(let scale):
            runtime.displayScale = CGFloat(scale)
        case .scenePhase(let phase):
            switch phase {
            case .background: runtime.setScenePhase(.background)
            case .inactive: runtime.setScenePhase(.inactive)
            case .active, .UNRECOGNIZED: runtime.setScenePhase(.active)
            }
        case .openURL(let url):
            runtime.openURL(external: url)
        case .back:
            _ = runtime.handleBackButton()
        }
        // What the message changed renders in the next frame (the app asks for
        // it); a frame now answers the person sooner.
        HeadlessApp.renderIfNeeded()
    }
}

#endif
