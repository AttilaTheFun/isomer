// A head's session with an app whose SwiftUI runs elsewhere (docs/modes.md,
// docs/remote_sessions.md): built headless on a server, compiled or as wasm.
// It opens the app's `Session.Connect` over whatever the URL names
// (IsomerRemote: ws, grpc, unix), says the head's size, scale, appearance and
// renderer ("swiftui": the tree renderer), applies each frame's patch to the
// tree it holds, and sends back what the person does. The web's
// `connectIsomer` and Android's `IsomerRemote` are its peers.

import Foundation
import IsomerRemote
import IsomerServing
import IsomerTree
import IsomerWire
import Observation

@MainActor
@Observable
public final class IsomerRemoteSession {
    /// The tree the app drew last, as the tree renderer takes it.
    public private(set) var tree: PatchedNode?
    /// Why the session isn't drawing: connecting, or what ended it.
    public private(set) var status: String = "Connecting…"
    /// The app's resolved color scheme, its override or the system's.
    public private(set) var appDark: Bool?
    /// The app's own `.preferredColorScheme`, nil when it sets none: what the
    /// head applies to its window, so the system's scheme still reaches the
    /// app once the app lets go of its own.
    public private(set) var appPreferredDark: Bool?

    /// Where the app is: a URL (IsomerRemote's), or a connection of the
    /// host's own (a page in a web view, apple/libraries/webview_head).
    private let url: String?
    private let connection: (any IsomerConnection)?
    private let token: String?
    private let environment: [String: String]
    private var call: IsomerCall<Wire_ClientMessage, Wire_ServerMessage>?
    private var reading: Task<Void, Never>?
    private var started = false
    /// What the app asks of the platform (a window's title, the clipboard,
    /// a URL to open): the host's to act on.
    public var onCommand: (String, String) -> Void = { _, _ in }
    public var onOpenURL: (URL) -> Void = { _ in }

    /// `url` names the app (ws://host:port, grpc://host:port/target,
    /// unix:/path); `environment` its launch hooks (ISO_ only).
    public init(url: String, token: String? = nil, environment: [String: String] = [:]) {
        self.url = url
        self.connection = nil
        self.token = token
        self.environment = environment
    }

    /// The app over a connection the host made: a page in a web view the
    /// app owns (web-view mode, docs/modes.md: IsomerWebViewConnection), or
    /// any other transport. `environment` is the app's launch hooks (ISO_
    /// only), sent with the session's start.
    public init(connection: any IsomerConnection, environment: [String: String] = [:]) {
        self.url = nil
        self.connection = connection
        self.token = nil
        self.environment = environment
    }

    /// Opens the session at the head's size and appearance; again after it
    /// ends, a new session (the app's first frame is its whole tree).
    public func start(width: Double, height: Double, displayScale: Double, dark: Bool) {
        guard !started else { return }
        started = true
        status = "Connecting…"
        reading = Task { [url, connection, token, environment] in
            do {
                let call: IsomerCall<Wire_ClientMessage, Wire_ServerMessage>
                if let connection {
                    call = try await connection.connect()
                } else {
                    let endpoint = try IsomerRemote.endpoint(url ?? "")
                    call = try await endpoint.connection.connect(context: endpoint.context(token: token))
                }
                self.call = call
                var start = Wire_Start()
                start.size.width = width
                start.size.height = height
                start.displayScale = displayScale
                start.dark = dark
                start.renderer = "swiftui"
                start.environment = environment
                try await call.write(.with { $0.start = start })
                for try await message in call.inbound {
                    self.handle(message)
                }
                self.ended("The app ended the session.")
            } catch {
                self.ended("Not connected: \(error)")
            }
        }
    }

    private func ended(_ why: String) {
        status = why
        call = nil
        started = false
    }

    private func handle(_ message: Wire_ServerMessage) {
        switch message.message {
        case .patch(let bytes):
            tree = FlatPatchTree.apply(patch: [UInt8](bytes), to: tree)
            status = ""
        case .image(let image):
            IsomerTreeImages.register(source: image.source, data: image.bytes)
        case .command(let command) where command.key == "preferredColorScheme":
            appPreferredDark = command.value.isEmpty ? nil : command.value == "dark"
        case .command(let command):
            onCommand(command.key, command.value)
        case .openURL(let link):
            if let url = URL(string: link) { onOpenURL(url) }
        case .dark(let dark):
            appDark = dark
        case .log(let line):
            // The app's log (its Swift's `print` in a web view's page, a
            // server's) on the head's standard error, unbuffered.
            FileHandle.standardError.write(Data("[swiftui] \(line)\n".utf8))
        case .textInput, .endTextInput, nil:
            // Text input is a self-drawing head's; the tree renderer's
            // fields are the system's own.
            break
        }
    }

    // MARK: What the person does

    /// A tree node's event, as `IsomerTreeView` reports it.
    public func send(id: String, value: String) {
        write(.with { $0.event = .with { $0.id = id; $0.value = value } })
    }

    public func resize(width: Double, height: Double) {
        write(.with { $0.resize = .with { $0.width = width; $0.height = height } })
    }

    public func setDark(_ dark: Bool) {
        write(.with { $0.dark = dark })
    }

    public func setScenePhase(active: Bool, background: Bool) {
        write(.with { $0.scenePhase = background ? .background : active ? .active : .inactive })
    }

    public func open(_ url: URL) {
        write(.with { $0.openURL = url.absoluteString })
    }

    public func back() {
        write(.with { $0.back = Wire_Empty() })
    }

    /// In order: each write waits for the one before.
    private var writing: Task<Void, Never>?
    private func write(_ message: Wire_ClientMessage) {
        guard let call else { return }
        let previous = writing
        writing = Task {
            await previous?.value
            try? await call.write(message)
        }
    }

    public func close() {
        reading?.cancel()
        let call = self.call
        Task { await call?.finish() }
        ended("Closed.")
    }
}
