// The Playground's host on Linux and Windows, set as `PlaygroundHost.service`
// before the app starts. The app is drawn by its own renderer (OpenGL on
// Linux, Direct3D on Windows); a project's build runs in a window of its
// own: the platform's WasmKit loader (playground_wasm_loader, beside the
// app) as a child process. A project compiles with the compiler the app
// carries beside it (playground_toolchain: swift-frontend and wasm-ld, run
// as processes; shared/compiler) against the Playground SDK beside it
// (playground_sdk).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation
import SwiftUI

final class DesktopHost: PlaygroundHostService, @unchecked Sendable {
    /// The last successful build, for `run`.
    private var lastBuild: Data?

    func capabilities() -> String { DesktopCompiler.toolchain == nil ? "" : "projects" }

    func compile(source: String) async throws -> String {
        guard let toolchain = DesktopCompiler.toolchain else { return DesktopCompiler.status }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("playground-source-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appendingPathComponent("App.swift")
        try Data(source.utf8).write(to: file)
        let result = await Task.detached {
            Result { try toolchain.compile(files: [file], sdk: try DesktopCompiler.sdk(), run: DesktopCompiler.run) }
        }.value
        switch result {
        case .success(let wasm):
            lastBuild = wasm
            print("[playground] compiled \(wasm.count) bytes")
            return ""
        case .failure(let error):
            return (error as? CompileError)?.diagnostics ?? "\(error)"
        }
    }

    func toolchainStatus() -> String { DesktopCompiler.status }

    /// A build in the loader's window: its bytes in a file of their own.
    private func start(_ bytes: Data, project: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("playground-runs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(project.filter { $0.isLetter || $0.isNumber || $0 == "-" } + ".wasm")
        try bytes.write(to: file)
        try await MainActor.run { try DesktopRun.shared.start(reactor: file, environment: [:]) }
    }

    func run(project: String) async throws -> String {
        guard let lastBuild else { throw HostError("nothing built yet") }
        try await start(lastBuild, project: project)
        return "running in its own window"
    }

    func stop() { MainActor.assumeIsolated { DesktopRun.shared.stop() } }
    func logs() -> String { MainActor.assumeIsolated { DesktopRun.shared.log } }

    func appVersion() -> String { DesktopFiles.version }

    // What the desktop doesn't do yet (no agent).
    func signIn() async throws -> String { throw HostError("no sign-in here") }
    func canRunOnWeb() -> Bool { false }
    func runOnWeb() async throws -> String { throw HostError("no web run here") }
    func chat(body: String) async throws -> String { throw HostError("no agent here") }
    func hasKey() -> Bool { false }
    func setKey(key: String) {}
    func requestedTemplate() -> String { "" }
    func legacyFiles() -> String { "{}" }
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
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.39.0"
    }
}

/// The compiler beside the app, and how its tools run.
enum DesktopCompiler {
    static let toolchain = DesktopFiles.resource("playground_toolchain").flatMap(BundledToolchain.at)

    static var status: String {
        toolchain == nil
            ? "none: playground_toolchain is not beside the app"
            : "Swift toolchain beside the app (swift-frontend and wasm-ld)"
    }

    static func sdk() throws -> CompilerSDK {
        guard let root = DesktopFiles.resource("playground_sdk") else {
            throw CompileError(diagnostics: "playground_sdk is not beside the app")
        }
        return try CompilerSDK.load(root: root)
    }

    /// A tool as a child process, in the app's environment (on Linux its
    /// LD_LIBRARY_PATH: the Swift runtime the frontend loads) with
    /// `environment` over it; its output and errors together.
    static func run(_ tool: String, _ arguments: [String], _ environment: [String: String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(tool): \(error)") }
        // Read before waiting: a full pipe would block the tool.
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
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
        let loaderName = "playground_wasm_loader.exe"
        #else
        let loaderName = "playground_wasm_loader"
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
