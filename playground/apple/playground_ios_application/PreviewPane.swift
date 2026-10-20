// Everything the chat page presents modally: the code editor sheet (cancel /
// save / share), the "Compiling…" overlay + build-failure sheet, the web run
// (the in-app server + SFSafariViewController full screen) and the native run
// (WasmView full screen, dismissed with a shake — the SwiftUI in the project
// is meant to feel like the entire app, so there is no chrome).

import SwiftUI
import IsomerWasmView
#if os(iOS)
import UIKit
#endif

/// The single source file every project has (agent-authored apps are one
/// file: this is a prototyping tool).
let projectMainFile = "App.swift"

// MARK: - Building

/// Compiles the project's source off the main thread and records the
/// outcome on the session (the agent's own build tool does the same).
enum ProjectBuilder {
    @MainActor static func build(session: AgentSession, projects: ProjectStore) async -> Result<Data, BuildFailure> {
        // The sources are copied first and compiled from the copy (the
        // output lands beside them), so a write that arrives during the
        // compile — the agent's while the user plays, or vice versa — is
        // picked up by the NEXT build instead of tearing this one.
        let snapshot = projects.snapshotForRun(session.projectID)
        guard !snapshot.files.isEmpty else { return .failure(BuildFailure(diagnostics: "error: no files to build")) }
        if let unavailable = ToolchainCompiler.availability { return .failure(BuildFailure(diagnostics: "error: \(unavailable)")) }
        let current = projects.read(projectMainFile, in: session.projectID)
        let result = await Task.detached(priority: .userInitiated) {
            Result { try ToolchainCompiler.compile(files: snapshot.files) }
        }.value
        switch result {
        case .success(let wasm):
            try? wasm.write(to: snapshot.wasmURL)
            session.buildProduct = wasm
            session.buildCount += 1
            // Current only if nothing was written while the compile ran.
            session.buildIsCurrent = projects.read(projectMainFile, in: session.projectID) == current
            session.lastDiagnostics = nil
            projects.saveBuild(wasm, in: session.projectID)
            return .success(wasm)
        case .failure(let error):
            let text = (error as? CompileError)?.diagnostics ?? String(describing: error)
            session.lastDiagnostics = text
            return .failure(BuildFailure(diagnostics: text))
        }
    }
}

struct BuildFailure: Error, Identifiable {
    let diagnostics: String
    var id: String { diagnostics }
}

/// The blocking "Compiling…" panel shown over the chat while a run builds.
struct CompilingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Compiling…").font(.headline)
            }
            .padding(.horizontal, 36).padding(.vertical, 28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .transition(.opacity)
    }
}

/// Build failure: the compiler output, wrapped and selectable, with a copy
/// button — dismiss to go fix it (or let the agent).
struct BuildFailureSheet: View {
    let diagnostics: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Group {
                #if os(iOS)
                ReadOnlyCodeText(text: diagnostics)
                #else
                ScrollView {
                    Text(diagnostics).font(.system(size: 12, design: .monospaced)).foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12).textSelection(.enabled)
                }
                #endif
            }
            .navigationTitle("Build Failed")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(copied ? "Copied" : "Copy") {
                        #if os(iOS)
                        UIPasteboard.general.string = diagnostics
                        #else
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostics, forType: .string)
                        #endif
                        copied = true
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Editor sheet

/// The project's App.swift in the code editor. Edits live in the sheet
/// until Save writes them (and invalidates the last build); Cancel discards
/// them; Share hands the .swift file to the system share sheet.
struct EditorSheet: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject private var projects: ProjectStore

    var body: some View {
        ProjectEditorSheet(
            fileName: projectMainFile,
            load: {
                if projects.read(projectMainFile, in: session.projectID) == nil {
                    projects.write(projectMainFile, contents: PlaygroundStore.sample, in: session.projectID)
                }
                return projects.read(projectMainFile, in: session.projectID) ?? ""
            },
            save: { text in
                projects.write(projectMainFile, contents: text, in: session.projectID)
                session.buildIsCurrent = false
                session.fileVersion += 1
            },
            editor: { text in
                #if os(iOS)
                CodeEditor(text: text, fileName: projectMainFile)
                #else
                TextEditor(text: text).font(.system(size: 14, design: .monospaced))
                #endif
            },
            extraItems: {
                if let file = projects.fileURLs(in: session.projectID).first(where: { $0.lastPathComponent == projectMainFile }) {
                    ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                }
            })
    }
}

// MARK: - Runs

/// A WasmView over a build with the Playground's services injected
/// (network + per-project file sandbox); the model is owned here so async
/// service completions can reach the running feature.
struct ServicedWasmView: View {
    let wasm: Data
    let label: String
    let projectID: String
    /// Feed status and logs to `RunMonitor` (the agent's offscreen run);
    /// the user's own runs only log.
    var monitored = false
    /// Owned by the presenter (`HeadlessRun`, `PlayFullScreen`), which shuts
    /// it down gracefully before the view goes away.
    @ObservedObject var model: WasmViewModel
    @EnvironmentObject private var projects: ProjectStore
    /// The crash recorder's marker for this run (see `CrashRecorder`); a
    /// reference so the status closure sees the id set in onAppear.
    @StateObject private var marker = RunMarker()

    var body: some View {
        // Closures stored on the model must not capture `self`: the view
        // struct carries the model's StateObject wrapper, so an implicit
        // self-capture would make model → closure → view → model a cycle and
        // the engine instance would never be released. Capture values only.
        let marker = marker
        let projectID = projectID
        let monitored = monitored
        let owner: CrashRecord.Owner = monitored ? .agent : .user
        WasmView(
            model: model,
            provider: BuildBundleProvider(wasm: wasm, label: label),
            ffiModulePrefix: playgroundFFIPrefix,
            dependencies: playgroundDependencies(projectID: projectID, projects: projects, model: model),
            // Settings' renderer applies to the user's runs; the agent's
            // offscreen runs stay on SwiftUI (the GPU view is one-at-a-time).
            renderer: !monitored && (RendererPreference.isGPU || ProcessInfo.processInfo.environment["ISO_PLAYGROUND_RENDERER"] == "gpu") ? .gpu : .swiftUI
        ) { status in
            NSLog("[playground] preview status: %@", status)
            if status.hasPrefix("Loaded") {
                // Settle a moment, then record the footprint with this run up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MemoryFootprint.log("loaded (\(monitored ? "agent" : "user") run)") }
            }
            CrashRecorder.shared.append("[status] " + status, run: marker.ensure(projectID: projectID, owner: owner))
            if monitored { RunMonitor.shared.record(status: status) }
        }
        .onAppear { [model] in
            MemoryFootprint.log("before \(monitored ? "agent" : "user") run")
            _ = marker.ensure(projectID: projectID, owner: owner)
            model.onLog = { line in
                NSLog("[playground] guest: %@", line)
                CrashRecorder.shared.append(line, run: marker.ensure(projectID: projectID, owner: owner))
                if monitored { RunMonitor.shared.append(line) }
            }
        }
        .onDisappear { marker.end() }
    }
}

/// The crash recorder's marker for one run view, started on first use (a
/// load status can arrive before the view's onAppear).
@MainActor
final class RunMarker: ObservableObject {
    private var id: String?
    func ensure(projectID: String, owner: CrashRecord.Owner) -> String {
        if let id { return id }
        let started = CrashRecorder.shared.runStarted(projectID: projectID, owner: owner, snapshotDir: nil)
        id = started
        return started
    }
    func end() {
        if let id { CrashRecorder.shared.runEnded(id) }
        id = nil
    }
}

/// The user's native run: the build is the whole screen (no chrome — the
/// project's SwiftUI IS the app). Shake the device for the way out. The
/// agent's runs are offscreen instead (`HeadlessRun`), so this can stay up
/// while the agent works on the next version.
struct PlayFullScreen: View {
    let wasm: Data
    let projectID: String
    @Environment(\.dismiss) private var dismiss
    /// The run's engine, held here so leaving can shut it down first.
    @StateObject private var model = WasmViewModel.playground()

    var body: some View {
        // The project's SwiftUI owns the whole screen, but as an APP ROOT: the
        // tree is laid out inside the safe area (status bar, home indicator,
        // keyboard) exactly as a real app's root view is, and only the
        // project's own `.ignoresSafeArea()` views extend under the edges.
        // (Applying ignoresSafeArea here would zero the guest's insets — a
        // header would sit under the clock and a bottom text field under the
        // keyboard.)
        ShakeToLeave(leaveTitle: "Dismiss", onLeave: {
            // Graceful first (view tasks unwind), forced after 1s.
            Task { @MainActor in
                let outcome = await model.shutdown(timeout: 1)
                NSLog("[playground] user run shutdown: %@", String(describing: outcome))
                dismiss()
            }
        }) {
            ServicedWasmView(wasm: wasm, label: "run", projectID: projectID, model: model)
        }
    }
}

extension WasmViewModel {
    /// The Playground's model: the engine comes from the registry (WAMR's
    /// interpreter, the Apple host's default, unless the app registers
    /// another) — injected here so the presenter, not the view, owns the
    /// runtime's lifetime.
    static func playground() -> WasmViewModel {
        WasmViewModel(runtime: { WasmRuntimeRegistry.make(for: $0) })
    }
}

/// The process's physical footprint (what Xcode's memory gauge shows).
enum MemoryFootprint {
    static var bytes: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
    static func log(_ label: String) {
        NSLog("[playground] footprint %@: %.1f MB", label, Double(bytes) / 1_048_576)
    }
}

#if os(iOS)
/// The web run: SFSafariViewController over the whole screen (its own Done
/// button, or the same shake-to-leave alert as the native run).
struct WebFullScreen: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ShakeToLeave(title: "Leave the web app?", leaveTitle: "Dismiss", onLeave: { dismiss() }) {
            SafariView(url: url, onDone: { dismiss() })
                .ignoresSafeArea()
        }
    }
}
#endif

/// The deep-linked full-screen run (`iso-playground://project/<id>`): the
/// project's last build, or a fresh build when it was never built (an
/// out-of-the-box sample opened straight from a link). Same shake-to-leave.
struct FullScreenRun: View {
    let projectID: String
    @EnvironmentObject private var projects: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var build: Data?
    @State private var failure: String?

    var body: some View {
        Group {
            if let wasm = build {
                PlayFullScreen(wasm: wasm, projectID: projectID)
            } else if let failure {
                BuildFailureSheet(diagnostics: failure)
            } else {
                CompilingOverlay()
            }
        }
        .onAppear {
            if let saved = projects.loadBuild(projectID) {
                build = saved
            } else {
                let files = projects.fileURLs(in: projectID)
                Task.detached(priority: .userInitiated) {
                    let result = Result { try ToolchainCompiler.compile(files: files) }
                    await MainActor.run {
                        switch result {
                        case .success(let wasm):
                            projects.saveBuild(wasm, in: projectID)
                            build = wasm
                        case .failure(let error):
                            failure = (error as? CompileError)?.diagnostics ?? String(describing: error)
                        }
                    }
                }
            }
        }
    }
}

/// A provider over in-memory bytes: the just-compiled reactor, no updates.
struct BuildBundleProvider: BundleProvider {
    let wasm: Data
    let label: String

    func initialBundle() -> WasmServiceBundle? {
        WasmServiceBundle(label: label, wasm: [UInt8](wasm))
    }

    func bundleUpdates() -> AsyncStream<WasmServiceBundle> {
        AsyncStream { $0.finish() }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}

extension String: Identifiable {
    public var id: String { self }
}

