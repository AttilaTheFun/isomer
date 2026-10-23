// What the Isomer app asks of its host: compiling, running a reactor, the
// chat's network, the renderer choice. The web page implements it in
// index.html (docs/wasm_di.md): compiling runs in a Web Worker
// (swift-frontend.wasm + wasm-ld.wasm when the toolchain bundle is present;
// a dev compile server otherwise), running mounts the build in an overlay
// through hot_host.js, and chat proxies OpenRouter with the key the page
// keeps in localStorage. Android's Kotlin implements it through the
// generated binding; the native hosts (iOS, macOS, Linux, Windows) in Swift,
// setting `PlaygroundHost.service` before the app starts.

import IsomerFFI

@ExportedEnum
public enum PlaygroundHostKey: String {
    case host
}

@ExportedInterface(namespace: "playground_web")
public protocol PlaygroundHostService {
    /// What this host can do, comma-separated: "projects" (it compiles),
    /// "reactors" (it runs a reactor from a URL: hot reloaders),
    /// "gallery-wasm" (it carries the Gallery's reactor, `bundle:gallery.wasm`),
    /// "sign-in" (it links an OpenRouter account: `signIn`).
    func capabilities() -> String
    /// Signs in to OpenRouter in the system's web sign-in (PKCE) and keeps
    /// the key it returns; returns a status line.
    func signIn() async throws -> String
    /// Runs the wasm reactor at `url` full screen, as `run` runs a build:
    /// http(s), or `bundle:<name>` for one the app carries. `project` names
    /// its home; `environment` is KEY=VALUE lines for the guest.
    func runReactor(url: String, project: String, environment: String) async throws -> String
    /// The renderers a run (or the app) can be drawn with, "Native,GPU"
    /// (the component system's, the self-drawing one's), "" when one.
    func rendererNames() -> String
    /// When a change of renderer applies, for Settings.
    func rendererFooter() -> String
    /// The app's version, as the release shows it ("0.38.4").
    func appVersion() -> String
    /// Compiles one App.swift; "" on success, else the diagnostics.
    func compile(source: String) async throws -> String
    /// Mounts the last successful build full screen; returns a status line.
    /// `project` names the build's home: each project's files and
    /// UserDefaults are its own.
    func run(project: String) async throws -> String
    func stop()
    /// Whether the host can also run the build in the platform's browser
    /// (a native app serving the page, as the iOS Playground does).
    func canRunOnWeb() -> Bool
    /// Opens the last successful build in the browser; returns a status line.
    func runOnWeb() async throws -> String
    /// The running build's log lines (load status, print() output).
    func logs() -> String
    /// POSTs an OpenRouter chat-completions body (JSON, no key) and returns the response JSON.
    func chat(body: String) async throws -> String
    func hasKey() -> Bool
    func setKey(key: String)
    /// "wasm" (in-browser toolchain), "dev" (compile server), or "none: <why>".
    func toolchainStatus() -> String
    /// The page's `?template=<name>` query, "" when absent.
    func requestedTemplate() -> String
    /// The projects as the Playground kept them before 0.31, in the host's
    /// storage (the page's localStorage, the Android app's old sandbox): a
    /// JSON object of path → base64 contents under `playground/`, "{}" when
    /// there are none. Read once, when the Playground's own store is empty.
    func legacyFiles() -> String
    /// The renderer choice ("native" or "gpu"), which the host reads before
    /// the app starts.
    func renderer() -> String
    func setRenderer(value: String)
    /// Driving the running build (the agent's ui_tree/tap/type_text/submit/swipe).
    func uiTree() -> String
    func tap(target: String) async throws -> String
    func typeText(target: String, text: String) async throws -> String
    func submit(target: String) async throws -> String
    func swipe(target: String, dx: Double, dy: Double) async throws -> String
}

/// A native host hands its service over before the runtime starts (the
/// Android app's Kotlin, through the generated binding); the web page puts
/// its own in the dependency dictionary directly.
@ExportedFunction(namespace: "playground_web")
public func installPlaygroundHost(host: any PlaygroundHostService) {
    installDependencies([PlaygroundHostKey.host: Lazy<any PlaygroundHostService> { host }])
}

public enum PlaygroundHost {
    public nonisolated(unsafe) static var service: (any PlaygroundHostService)? = {
        (dependencies[PlaygroundHostKey.host] as? Lazy<any PlaygroundHostService>)?.value
            ?? dependencies[PlaygroundHostKey.host] as? any PlaygroundHostService
    }()
}

extension PlaygroundHostService {
    func supports(_ capability: String) -> Bool {
        capabilities().split(separator: ",").contains { $0 == capability }
    }

    func supportsProjects() -> Bool { supports("projects") }
    func supportsReactors() -> Bool { supports("reactors") }
}
