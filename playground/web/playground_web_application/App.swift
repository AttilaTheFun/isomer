// The web Playground: the same shape as the iOS app — projects in a sidebar,
// an agent chat per project, a code editor, and Run/Stop — written in
// Isomer's SwiftUI and compiled to wasm like everything it builds.
// "This website is written in SwiftUI. You can edit it and re-compile the
// code without leaving the page."

import AgentUI
import Foundation
import SwiftUI
import Isomer

@main
struct PlaygroundWebApp: App {
    init() {
        // The host keeps the renderer choice: it picks the renderer before
        // the app starts.
        RendererPreference.hostStore = (
            get: { PlaygroundHost.service?.renderer() ?? "" },
            set: { PlaygroundHost.service?.setRenderer(value: $0) })
    }

    var body: some Scene { WindowGroup { PlaygroundRoot() } }
}

struct PlaygroundRoot: View {
    @State private var store = WebProjectStore()
    @State private var sessions: [String: WebAgentSession] = [:]
    @State private var showNewProject = false
    @State private var showSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Bumped after the compile worker's probe answers, so the status re-reads.
    @State private var statusTick = 0

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            if let session = currentSession {
                // The detail column is used as provided: its own stack gives
                // the chat a navigation bar for the Edit / Run items.
                NavigationStack {
                    ProjectView(session: session)
                        .id(session.projectID)
                        .navigationTitle(store.projects.first(where: { $0.id == session.projectID })?.name ?? "Project")
                        .navigationBarTitleDisplayMode(.inline)
                }
            } else {
                Text("Create a project to start").foregroundColor(.secondary)
            }
        }
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet(templates: WebTemplate.all.map { ProjectTemplateChoice(id: $0.id, name: $0.name, subtitle: $0.subtitle, isBlank: $0.asset == nil) }) { name, choice in
                if let template = WebTemplate.all.first(where: { $0.id == choice.id }) {
                    store.create(named: name, template: template)
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
    }

    /// Re-reads the compiler status until the worker's probe has answered.
    private func refreshStatus(remaining: Int) {
        guard remaining > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            statusTick += 1
            if PlaygroundHost.service?.toolchainStatus().hasPrefix("No compiler: probing") == true { refreshStatus(remaining: remaining - 1) }
        }
    }

    private var currentSession: WebAgentSession? {
        guard let id = store.selection, store.projects.contains(where: { $0.id == id }) else { return nil }
        if let existing = sessions[id] { return existing }
        let session = WebAgentSession(projectID: id, store: store)
        Task { @MainActor in sessions[id] = session }
        return session
    }

    private var sidebar: some View {
        List(selection: Binding(get: { store.selection }, set: { if let id = $0 { store.select(id) } })) {
            Section("Projects") {
                Button { showNewProject = true } label: {
                    Label("New Project", systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("new-project")
                ForEach(store.projects) { project in
                    HStack {
                        Label(project.name, systemImage: "doc.text")
                        Spacer()
                        Button { store.delete(project.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                            .accessibilityLabel("Delete \(project.name)")
                    }
                    .tag(project.id)
                }
            }
            Section {
                Text((PlaygroundHost.service?.toolchainStatus() ?? "no host") + (statusTick < 0 ? "" : ""))
                    .font(.caption).foregroundColor(.secondary)
                    .onAppear { refreshStatus(remaining: 10) }
            } header: {
                Text("Compiler")
            }
        }
        // As the iPhone's sidebar is drawn.
        .listStyle(.insetGrouped)
        .navigationTitle("Playground")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
    }
}

/// One project: AgentUI's AgentView (the transcript over the composer), with
/// Edit and Run as bar items that open modals (the editor sheet, the
/// full-screen run) — the iOS Playground's shape, from the same shared
/// screens (AgentUI + examples/shared/playground_ui).
struct ProjectView: View {
    var session: WebAgentSession
    @State private var draft = ""
    @State private var compiling = false
    @State private var showEditor = false
    @State private var running = false
    @State private var buildFailure: String?

    var body: some View {
        AgentView(
            messages: session.messages.map(TranscriptMessage.init),
            activity: session.activity,
            error: session.error,
            emptyBody: "Describe a screen or an app. The agent writes the SwiftUI, compiles it in your browser, fixes errors, and runs it.",
            emptyFootnote: "Model: \(WebSettings.model)",
            draft: $draft,
            placeholder: "Describe the app…",
            busy: session.busy,
            send: send,
            stop: { session.cancel() })
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showEditor = true } label: { Image(systemName: "pencil") }
                    .accessibilityLabel("Edit")
                    .accessibilityIdentifier("edit")
                // The iOS Playground's order: edit, the web, native.
                if PlaygroundHost.service?.canRunOnWeb() == true {
                    Button { run(onWeb: true) } label: { Image(systemName: "globe") }
                        .accessibilityLabel("Run on the web")
                        .accessibilityIdentifier("run-web")
                }
                Button { run() } label: { Image(systemName: "play.fill") }
                    .accessibilityLabel("Run")
                    .accessibilityIdentifier("run")
            }
        }
        .disabled(compiling)
        .overlay(alignment: .center) {
            if compiling {
                HStack(spacing: 10) { ProgressView(); Text("Building…") }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.2)))
            }
        }
        .sheet(isPresented: $showEditor) {
            ProjectEditorSheet(
                fileName: "App.swift",
                load: { session.store.source(session.projectID) },
                save: { text in
                    session.store.write(session.projectID, source: text)
                    session.buildOK = false
                }
            ) { text in
                if RendererPreference.isGPU {
                    // The self-drawing renderer has no DOM to host the highlighted editor.
                    TextEditor(text: text).font(.system(size: 13, design: .monospaced))
                } else {
                    CodeEditor(text: text, fileName: "App.swift")
                        .accessibilityIdentifier("editor")
                }
            }
        }
        .sheet(isPresented: Binding(get: { buildFailure != nil }, set: { if !$0 { buildFailure = nil } })) {
            BuildDiagnosticsSheet(diagnostics: buildFailure ?? "")
        }
        .fullScreenCover(isPresented: $running) {
            ShakeToLeave(message: "Shake your phone — or press Esc — any time to get back here.", onLeave: { stop() }) {
                RunSurface(onStopped: { running = false })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func send() {
        let text = draft
        draft = ""
        session.send(text)
    }

    /// Build (when the last build is stale), then run full screen — or, on
    /// a host with a browser to hand, in that browser.
    private func run(onWeb: Bool = false) {
        Task { @MainActor in
            if !session.buildOK {
                compiling = true
                let result = await session.build()
                compiling = false
                guard result == "ok" else {
                    buildFailure = session.lastDiagnostics ?? result
                    return
                }
            }
            do {
                if onWeb {
                    _ = try await PlaygroundHost.service?.runOnWeb()
                } else {
                    _ = try await PlaygroundHost.service?.run(project: session.projectID)
                    running = true
                }
            } catch {
                session.error = "\(error)"
            }
        }
    }

    private func stop() {
        PlaygroundHost.service?.stop()
        running = false
    }
}

/// The page's run surface: the host mounts the running build's DOM into
/// this element (index.html's `isoSurfaceMount`), and reports "stopped"
/// when its Stop bar ends the run.
struct RunSurface: PlatformViewRepresentable {
    let onStopped: () -> Void

    var kind: String { "surface" }
    var value: String { "run" }
    func onValueChanged(_ value: String) {
        if value == "stopped" { onStopped() }
    }
}

extension TranscriptMessage {
    init(_ message: ChatMessage) {
        let role: TranscriptMessage.Role
        switch message.role {
        case .user: role = .user
        case .assistant: role = .assistant
        case .tool: role = .tool
        }
        self.init(
            id: message.id, role: role, text: message.text,
            activities: message.toolCalls.map { WebAgentSession.activityLabel($0).withoutEllipsis },
            toolName: message.toolName)
    }
}

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var hasKey = PlaygroundHost.service?.hasKey() ?? false
    @State private var model = WebSettings.model

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("OpenRouter API key (sk-or-…)", text: $key)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("api-key")
                    Button(hasKey ? "Replace key" : "Save key") {
                        PlaygroundHost.service?.setKey(key: key.trimmed)
                        hasKey = !key.isEmpty
                        key = ""
                    }
                    .disabled(key.trimmed.isEmpty)
                } header: {
                    Text("Agent")
                } footer: {
                    Text(hasKey ? "A key is stored in this browser only. Usage is billed to your OpenRouter account." : "Create a key at openrouter.ai/keys. It stays in this browser's storage.")
                }
                Section {
                    TextField("Model id", text: $model)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { WebSettings.model = model.trimmed }
                        .accessibilityIdentifier("model-id")
                    Button("Use this model") { WebSettings.model = model.trimmed }
                        .disabled(model.trimmed.isEmpty)
                } header: {
                    Text("Model")
                } footer: {
                    Text("Any OpenRouter model id that supports tools, e.g. anthropic/claude-sonnet-5, openai/gpt-5.2, z-ai/glm-5.")
                }
                RendererSettingsSection(
                    nativeName: "React", gpuName: "WebGPU",
                    footer: "React builds real DOM (text fields, scrolling); WebGPU is the self-drawing SwiftGPU renderer. Applies when the page is refreshed.")
                Section("Compiler") {
                    Text(PlaygroundHost.service?.toolchainStatus() ?? "no host").font(.footnote)
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
