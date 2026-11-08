// The headless host serving its app to a remote client
// (ISO_HEADLESS_PROTOCOL=session): shared/wire/session.proto on standard
// input and output, length-delimited. The client (a browser's React, an
// Android phone's Compose: nothing of the app but its renderer) sends what
// the person does; the app answers with each frame as a tree.proto Patch,
// the same patches the component-system renderers take in process, and what
// it asks of the platform. One process is one session: a server (the
// examples' //remote:gateway) starts one for each connection.
//
// The app lays nothing out by the client's fonts: text is measured as the
// headless host measures it (a fixed-width estimate), and every image is
// ready. The client's renderer lays out the tree as it would in process; what
// the app itself computes from a measurement (a GeometryReader of text) is
// approximate.

#if !canImport(WASILibc)

internal import IsomerSwiftUI
internal import IsomerWire
internal import SwiftUI
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum RemoteSession {
    nonisolated(unsafe) static var needsFrame = true
    nonisolated(unsafe) static var rendererName = "React"

    /// One message to the client.
    static func send(_ message: Wire_ServerMessage) {
        guard let framed = try? WireDelimited.frame(message) else { return }
        FileHandle.standardOutput.write(framed)
    }

    static func send(_ build: (inout Wire_ServerMessage) -> Void) {
        var message = Wire_ServerMessage()
        build(&message)
        send(message)
    }

    /// Waits for the client's `start`, starts the app at its size, then
    /// takes the client's messages on the main actor in order, and renders a
    /// frame whenever the app asked for one, until the input ends.
    @MainActor
    static func run() {
        var start: Wire_Start?
        while start == nil {
            guard let bytes = WireDelimited.read(from: 0) else { exit(0) }
            if let message = try? Wire_ClientMessage(serializedBytes: bytes), case .start(let first)? = message.message {
                start = first
            }
        }
        guard let start else { exit(0) }
        for (key, value) in start.environment where key.hasPrefix("ISO_") {
            setenv(key, value, 1)
        }
        let compose = start.renderer == "compose"
        rendererName = compose ? "Compose" : "React"
        PlatformBridges.current = RemotePlatformBridge()
        if start.dark { Runtime.shared.setSystemColorScheme(dark: true) }
        if start.displayScale > 0 { Runtime.shared.displayScale = CGFloat(start.displayScale) }
        let send: ([UInt8]) -> Void = { patch in RemoteSession.send { $0.patch = Data(patch) } }
        Renderer.bind(compose ? JetpackComposeRenderer(send: send) : ReactRenderer(send: send))
        let width = start.hasSize && start.size.width > 0 ? start.size.width : 390
        let height = start.hasSize && start.size.height > 0 ? start.size.height : 844
        Runtime.shared.start(host: RemoteHostBridge(), width: width, height: height)

        // A frame when the app asked for one, at most one a display frame.
        let frames = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { renderIfNeeded() }
        }
        RunLoop.main.add(frames, forMode: .default)
        renderIfNeeded()

        Thread.detachNewThread {
            while let bytes = WireDelimited.read(from: 0) {
                guard let message = try? Wire_ClientMessage(serializedBytes: bytes) else { continue }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { receive(message) }
                }
            }
            // The client went away: the session is over.
            exit(0)
        }
        HeadlessApp.runMainLoop()
    }

    @MainActor
    static func renderIfNeeded() {
        guard needsFrame else { return }
        needsFrame = false
        Runtime.shared.renderFrame()
    }

    /// One of the client's messages, as the in-process hosts' entry points
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
        renderIfNeeded()
    }
}

/// The services half for a remote client: measurement as the headless
/// host's, and what the app asks of the platform sent to the client.
final class RemoteHostBridge: HostBridge {
    private let measuring = HeadlessHostBridge()

    func measureText(_ text: String, fontSize: Double, weight: Int, wrapWidth: Double?) -> CGSize {
        measuring.measureText(text, fontSize: fontSize, weight: weight, wrapWidth: wrapWidth)
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
    func scheduleRender() { RemoteSession.needsFrame = true }
    func log(_ message: String) { RemoteSession.send { $0.log = message } }
    func openURL(_ url: String) { RemoteSession.send { $0.openURL = url } }
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

/// The Isomer module's `Bridge` in a remote session: the client's renderer,
/// the log and URLs sent to the client.
struct RemotePlatformBridge: PlatformBridge {
    var platformName: String { "Remote" }
    var rendererName: String { RemoteSession.rendererName }
    func log(_ message: String) { RemoteSession.send { $0.log = message } }
    func epochMilliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    func openURL(_ url: String) { RemoteSession.send { $0.openURL = url } }
}

#endif
