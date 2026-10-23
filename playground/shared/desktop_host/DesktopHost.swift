// The Isomer app's host on Linux and Windows, set as `PlaygroundHost.service`
// before the app starts. The Gallery is drawn by the app's own renderer
// (OpenGL on Linux, Direct3D on Windows); a reactor (a hot reloader's
// version, the Gallery as wasm) runs in a window of its own: the platform's
// WasmKit loader (isomer_wasm_loader, beside the app) as a child process, its
// ISO_ variables forwarded to the guest. No Projects: no compiler here yet.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation
import SwiftUI

final class DesktopHost: PlaygroundHostService, @unchecked Sendable {
    func capabilities() -> String { "reactors,gallery-wasm" }

    func runReactor(url: String, project: String, environment: String) async throws -> String {
        let bytes: Data
        if url.hasPrefix("bundle:") {
            let name = String(url.dropFirst("bundle:".count))
            guard let file = DesktopFiles.resource(name) else { throw HostError("\(name) is not beside the app") }
            bytes = try Data(contentsOf: file)
        } else {
            guard let address = URL(string: url) else { throw HostError("not a URL: \(url)") }
            let (data, response) = try await URLSession.shared.data(from: address)
            if let status = (response as? HTTPURLResponse)?.statusCode, status >= 300 { throw HostError("\(url): HTTP \(status)") }
            bytes = data
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("isomer-runs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(project.filter { $0.isLetter || $0.isNumber || $0 == "-" } + ".wasm")
        try bytes.write(to: file)
        var variables: [String: String] = [:]
        for line in environment.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            variables[String(line[..<equals]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: equals)...])
        }
        try await MainActor.run { try DesktopRun.shared.start(reactor: file, environment: variables) }
        return "running in its own window"
    }

    func stop() { MainActor.assumeIsolated { DesktopRun.shared.stop() } }
    func logs() -> String { MainActor.assumeIsolated { DesktopRun.shared.log } }

    func rendererNames() -> String { "" }
    func rendererFooter() -> String { "" }
    func appVersion() -> String { DesktopFiles.version }

    // What the desktop doesn't do (no Projects).
    func signIn() async throws -> String { throw HostError("no sign-in here") }
    func compile(source: String) async throws -> String { "No compiler on this platform yet." }
    func run(project: String) async throws -> String { throw HostError("no builds here") }
    func canRunOnWeb() -> Bool { false }
    func runOnWeb() async throws -> String { throw HostError("no web run here") }
    func chat(body: String) async throws -> String { throw HostError("no agent here") }
    func hasKey() -> Bool { false }
    func setKey(key: String) {}
    func toolchainStatus() -> String { "none: no compiler on this platform yet" }
    func requestedTemplate() -> String { "" }
    func legacyFiles() -> String { "{}" }
    func renderer() -> String { "native" }
    func setRenderer(value: String) {}
    func uiTree() -> String { "the run is in its own window" }
    func tap(target: String) async throws -> String { "the run is in its own window" }
    func typeText(target: String, text: String) async throws -> String { "the run is in its own window" }
    func submit(target: String) async throws -> String { "the run is in its own window" }
    func swipe(target: String, dx: Double, dy: Double) async throws -> String { "the run is in its own window" }
}

struct HostError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Where the app's files are: beside its executable (a packaged app), or
/// in its Bazel runfiles (`bazel run`).
enum DesktopFiles {
    static var executableDirectory: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    }

    /// `name` beside the executable, else anywhere under RUNFILES_DIR's
    /// _main tree.
    static func resource(_ name: String) -> URL? {
        let beside = executableDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: beside.path) { return beside }
        guard let runfiles = ProcessInfo.processInfo.environment["RUNFILES_DIR"] else { return nil }
        let root = URL(fileURLWithPath: runfiles).appendingPathComponent("_main")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.lastPathComponent == name { return url }
        return nil
    }

    /// The release's version: version.txt beside the app (written when it
    /// is packaged), else the version this source was committed at.
    static var version: String {
        resource("version.txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.38.0"
    }
}

/// The reactor's window: the loader as a child process, one at a time.
@MainActor @Observable
final class DesktopRun {
    static let shared = DesktopRun()

    private(set) var running = false
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private(set) var log = ""

    func start(reactor: URL, environment: [String: String]) throws {
        stop()
        #if os(Windows)
        let loaderName = "isomer_wasm_loader.exe"
        #else
        let loaderName = "isomer_wasm_loader"
        #endif
        guard let loader = DesktopFiles.resource(loaderName) else { throw HostError("\(loaderName) is not beside the app") }
        let process = Process()
        process.executableURL = loader
        process.arguments = [reactor.path]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                guard let self, self.process === finished else { return }
                self.log += "[status] the run's window closed (\(status))\n"
                self.process = nil
                self.running = false
            }
        }
        try process.run()
        log = "[status] running \(reactor.lastPathComponent) in its own window\n"
        self.process = process
        running = true
    }

    func stop() {
        process?.terminate()
        process = nil
        running = false
    }
}

/// The run cover on the desktop: the reactor draws in its own window; this
/// says so, offers Stop, and comes down when that window closes.
struct DesktopRunSurface: View {
    let onStopped: () -> Void
    private var run = DesktopRun.shared

    init(onStopped: @escaping () -> Void) { self.onStopped = onStopped }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "macwindow.on.rectangle").font(.system(size: 40)).foregroundColor(.secondary)
            Text("Running in its own window").font(.title2)
            Text("Close that window, or stop it here.").foregroundColor(.secondary)
            Button("Stop") { run.stop() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("stop-run")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: run.running) { running in
            if !running { onStopped() }
        }
    }
}
