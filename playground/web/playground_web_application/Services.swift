// The browser host's services for the web Playground, injected by index.html
// (docs/wasm_di.md): compiling runs in a Web Worker (swift-frontend.wasm +
// wasm-ld.wasm when the toolchain bundle is present; a dev compile server
// otherwise), running mounts the build in an overlay through hot_host.js,
// and chat proxies OpenRouter with the key the page keeps in localStorage.
// The Android Playground's Kotlin implements the same interface.

import IsomerFFI

@ExportedEnum
public enum PlaygroundHostKey: String {
    case host
}

@ExportedInterface(namespace: "playground_web")
public protocol PlaygroundHostService {
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
