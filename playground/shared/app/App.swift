// The Playground: one shell on every platform, written in SwiftUI and
// compiled against Apple's SwiftUI (iOS, macOS) and Isomer's (the web,
// Android, Linux, Windows). Its sidebar is the projects: describe an app,
// an agent writes the SwiftUI, and the app compiles it to a wasm reactor
// on the device and runs it. New projects start from the canned examples
// (the templates: Counter, 2048, the Pokédex…), which live only here.
// What is platform-bound (the compiler, running a reactor, the chat's
// network, the code editor) is the host's: PlaygroundHostService
// (Services.swift), and the views a host injects (PlaygroundSurfaces).

import AgentUI
import Foundation
import SwiftUI
import Isomer

/// The views a native host injects where the platform has its own: the run
/// surface (a WasmView on Apple platforms; the run's own window on Linux
/// and Windows) and the code editor. Unset, the shared ones are used (the
/// web page's and Android's run surface, a TextEditor).
public enum PlaygroundSurfaces {
    @MainActor public static var run: ((_ onStopped: @escaping () -> Void) -> AnyView)?
    @MainActor public static var codeEditor: ((_ text: Binding<String>, _ fileName: String) -> AnyView)?
}

/// The app: the shell, given what the host can do.
public struct PlaygroundRoot: View {
    /// Projects only where the host compiles.
    private let hasProjects = PlaygroundHost.service?.supportsProjects() ?? false
    @State private var store: WebProjectStore
    @State private var sessions: [String: WebAgentSession] = [:]
    /// The project open.
    @State private var selection: String?
    @State private var showNewProject = false
    @State private var showSettings = false
    @State private var columns: NavigationSplitViewVisibility = .all
    /// A phone's one column: the sidebar (the app's main menu) until
    /// something is opened.
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// A run the launch asked for (ISO_PLAYGROUND_RUN_PROJECT), and whether
    /// it was started.
    @State private var launchRunStarted = false
    /// The launch's own selection, which opens no page on a phone.
    @State private var settingFirstSelection = false

    /// What a launch hook opens (ISO_PLAYGROUND_OPEN_PROJECT,
    /// ISO_PLAYGROUND_RUN_PROJECT) is open from the first frame, on its page.
    public init() {
        let store = WebProjectStore()
        _store = State(initialValue: store)
        if let launched = Self.launchProject(store: store) {
            _selection = State(initialValue: launched)
            _compactColumn = State(initialValue: .detail)
        }
    }

    private var compact: Bool { sizeClass == .compact }

    // Visor's shape: two columns, the sidebar (an inset grouped list of the
    // projects) and the project selected. A phone shows one at a time, the
    // sidebar first.
    public var body: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
            sidebar
        } detail: {
            page
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet(templates: WebTemplate.all.map { ProjectTemplateChoice(id: $0.id, name: $0.name, subtitle: $0.subtitle, isBlank: $0.asset == nil) }) { name, choice in
                if let template = WebTemplate.all.first(where: { $0.id == choice.id }) {
                    let project = store.create(named: name, template: template)
                    selection = project.id
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsSheet(hasProjects: hasProjects) }
        .onAppear {
            openFirstPageIfWide()
            startLaunchRun()
        }
        .task { startLaunchRun() }
        // A window that widens past a phone's opens a page beside the sidebar.
        .onChange(of: sizeClass) { _ in openFirstPageIfWide() }
        .onChange(of: selection) { value in
            if let value { store.select(value) }
            if settingFirstSelection {
                settingFirstSelection = false
                return
            }
            if compact, compactColumn != (value == nil ? .sidebar : .detail) { compactColumn = value == nil ? .sidebar : .detail }
        }
    }

    /// Wide, the last project is open beside the sidebar; a phone stays on
    /// the sidebar, its main menu, with nothing selected (a selection there
    /// would open its page).
    private func openFirstPageIfWide() {
        guard !compact, selection == nil, hasProjects, let last = store.selection ?? store.projects.first?.id else { return }
        settingFirstSelection = true
        selection = last
    }

    /// Headless hooks: ISO_PLAYGROUND_OPEN_PROJECT=<id or name> opens a
    /// project; ISO_PLAYGROUND_RUN_PROJECT=<id or name> opens it and builds
    /// and runs it (the proof's shot of a canned example running).
    static func launchProject(store: WebProjectStore) -> String? {
        let environment = ProcessInfo.processInfo.environment
        for hook in ["ISO_PLAYGROUND_RUN_PROJECT", "ISO_PLAYGROUND_OPEN_PROJECT"] {
            if let key = environment[hook], !key.isEmpty,
               let project = store.projects.first(where: { $0.id == key || $0.name == key }) {
                return project.id
            }
        }
        return nil
    }

    /// ISO_PLAYGROUND_AUTORUN=all compiles every project at launch.
    private func startLaunchRun() {
        guard !launchRunStarted else { return }
        launchRunStarted = true
        if ProcessInfo.processInfo.environment["ISO_PLAYGROUND_AUTORUN"] == "all" {
            compileEveryProject()
        }
    }

    /// ISO_PLAYGROUND_AUTORUN=all: every project compiled with the host's
    /// compiler, each logged ("[playground] compiled <name>" or "compile
    /// failed <name>: <diagnostics>"), then "[playground] compiled all": what
    /// the e2e reads ("every project compiles").
    private func compileEveryProject() {
        let projects = store.projects.map { ($0.name, store.source($0.id)) }
        Task { @MainActor in
            for (name, source) in projects {
                do {
                    let diagnostics = try await PlaygroundHost.service?.compile(source: source) ?? "no host"
                    playgroundLog(diagnostics.isEmpty ? "[playground] compiled \(name): \(source.utf8.count) bytes of source"
                                  : "[playground] compile failed \(name): \(diagnostics.prefix(300))")
                } catch {
                    playgroundLog("[playground] compile failed \(name): \(error)")
                }
            }
            playgroundLog("[playground] compiled all")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            if hasProjects {
                Section("Projects") {
                    Button { showNewProject = true } label: {
                        Label("New Project", systemImage: "plus.circle.fill")
                    }
                    .accessibilityIdentifier("new-project")
                    ForEach(store.projects) { project in
                        HStack {
                            Label(project.name, systemImage: "app.dashed")
                            Spacer()
                            Button { delete(project: project.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)
                                .accessibilityLabel("Delete \(project.name)")
                        }
                        .tag(project.id)
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("Playground")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settings")
            }
        }
    }

    private func delete(project id: String) {
        store.delete(id)
        sessions[id] = nil
        if selection == id { selection = compact ? nil : store.selection }
    }

    // MARK: The page

    @ViewBuilder
    private var page: some View {
        if let id = selection, let session = session(for: id) {
            Barred {
                ProjectView(session: session, runAtLaunch: Self.runsAtLaunch(id, store: store))
                    .id(id)
                    .navigationTitle(store.projects.first(where: { $0.id == id })?.name ?? "Project")
                    .inlineTitle()
            }
        } else {
            Barred { Placeholder(text: hasProjects ? "Select a project, or make a new one" : "This platform has no compiler yet") }
        }
    }

    /// Whether ISO_PLAYGROUND_RUN_PROJECT names this project.
    static func runsAtLaunch(_ id: String, store: WebProjectStore) -> Bool {
        guard let key = ProcessInfo.processInfo.environment["ISO_PLAYGROUND_RUN_PROJECT"], !key.isEmpty else { return false }
        return store.projects.first(where: { $0.id == key || $0.name == key })?.id == id
    }

    private func session(for id: String) -> WebAgentSession? {
        guard store.projects.contains(where: { $0.id == id }) else { return nil }
        if let existing = sessions[id] { return existing }
        let session = WebAgentSession(projectID: id, store: store)
        Task { @MainActor in sessions[id] = session }
        return session
    }
}

/// A page's container: Apple's SwiftUI gives the detail column its bar
/// (a nested stack strips it on a collapsed phone and squeezes the Mac's
/// sidebar); other SwiftUIs give a column a bar only inside a stack.
struct Barred<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(iOS) || os(macOS)
        content()
        #else
        NavigationStack { content() }
        #endif
    }
}

/// A line for the tests' log readers: the unified log on Apple platforms
/// (where `print` is not kept), standard output elsewhere.
func playgroundLog(_ line: String) {
    #if os(iOS) || os(macOS)
    NSLog("%@", line)
    #else
    print(line)
    #endif
}

/// A column with nothing selected.
struct Placeholder: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text).font(.headline).foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// An inline navigation title where the platform has one.
    func inlineTitle() -> some View {
        #if os(macOS)
        return self
        #else
        return navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// One project: AgentUI's AgentView (the transcript over the composer), with
/// Edit and Run as bar items that open modals (the editor sheet, the
/// full-screen run).
struct ProjectView: View {
    var session: WebAgentSession
    /// Build and run as soon as the page appears (ISO_PLAYGROUND_RUN_PROJECT).
    var runAtLaunch = false
    @State private var draft = ""
    @State private var ranAtLaunch = false
    @State private var compiling = false
    @State private var showEditor = false
    @State private var running = false
    @State private var buildFailure: String?

    var body: some View {
        AgentView(
            messages: session.messages.map(TranscriptMessage.init),
            activity: session.activity,
            error: session.error,
            emptyBody: "Describe a screen or an app. The agent writes the SwiftUI, compiles it here, fixes errors, and runs it.",
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
                    session.fileVersion += 1
                }
            ) { text in
                CodeEditorView(text: text, fileName: "App.swift")
            }
        }
        .sheet(isPresented: Binding(get: { buildFailure != nil }, set: { if !$0 { buildFailure = nil } })) {
            BuildDiagnosticsSheet(diagnostics: buildFailure ?? "")
        }
        .runCover(isPresented: $running)
        .onAppear {
            guard runAtLaunch, !ranAtLaunch else { return }
            ranAtLaunch = true
            run()
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
}

/// The platform's code editor: the host's where it has one (the iOS
/// Playground's highlighted UITextView, the web page's), else a TextEditor.
struct CodeEditorView: View {
    @Binding var text: String
    let fileName: String

    var body: some View {
        if let editor = PlaygroundSurfaces.codeEditor {
            editor($text, fileName)
        } else {
            #if os(iOS) || os(macOS) || os(Linux) || os(Windows)
            TextEditor(text: $text).font(.system(size: 13, design: .monospaced))
            #else
            CodeEditor(text: $text, fileName: fileName)
                .accessibilityIdentifier("editor")
            #endif
        }
    }
}

extension View {
    /// The running build full screen, with a shake (or Esc) to leave: the
    /// host's run surface. The host started the run; the cover comes down
    /// when the run stops or the reader leaves.
    func runCover(isPresented: Binding<Bool>) -> some View {
        let leave = {
            PlaygroundHost.service?.stop()
            isPresented.wrappedValue = false
        }
        return fullScreenCoverOrSheet(isPresented: isPresented) {
            ShakeToLeave(message: "Shake your phone — or press Esc — any time to get back here.", onLeave: leave) {
                RunSurfaceView(onStopped: { isPresented.wrappedValue = false })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            #if os(macOS)
            // A Mac can't be shaken: the sheet's own way out.
            .overlay(alignment: .bottomTrailing) {
                Button("Stop", action: leave)
                    .keyboardShortcut(.cancelAction)
                    .padding(10)
                    .accessibilityIdentifier("stop-run")
            }
            #endif
        }
    }

    @ViewBuilder
    fileprivate func fullScreenCoverOrSheet<Cover: View>(isPresented: Binding<Bool>, @ViewBuilder cover: @escaping () -> Cover) -> some View {
        #if os(macOS)
        // A run is an app of its own: a sheet near the window's size.
        sheet(isPresented: isPresented) { cover().frame(minWidth: 1100, minHeight: 720) }
        #else
        fullScreenCover(isPresented: isPresented, content: cover)
        #endif
    }
}

/// The host's view of the running build.
struct RunSurfaceView: View {
    let onStopped: () -> Void

    var body: some View {
        if let surface = PlaygroundSurfaces.run {
            surface(onStopped)
        } else {
            #if os(iOS) || os(macOS)
            Placeholder(text: "This host has no run surface")
            #else
            RunSurface(onStopped: onStopped)
            #endif
        }
    }
}

#if !(os(iOS) || os(macOS))
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
#endif

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
    let hasProjects: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var hasKey = PlaygroundHost.service?.hasKey() ?? false
    @State private var model = WebSettings.model
    @State private var signInError: String?

    var body: some View {
        NavigationStack {
            Form {
                if hasProjects, PlaygroundHost.service?.supports("sign-in") == true {
                    Section {
                        Button(hasKey ? "Sign in to OpenRouter again" : "Sign in with OpenRouter") {
                            Task { @MainActor in
                                do {
                                    _ = try await PlaygroundHost.service?.signIn()
                                    hasKey = PlaygroundHost.service?.hasKey() ?? false
                                } catch {
                                    signInError = "\(error)"
                                }
                            }
                        }
                        .accessibilityIdentifier("sign-in")
                        if let signInError { Text(signInError).font(.footnote).foregroundColor(.red) }
                    } footer: {
                        Text("Links your OpenRouter account: the agent's usage is billed to it. Or paste a key below.")
                    }
                }
                if hasProjects {
                    Section {
                        TextField("OpenRouter API key (sk-or-…)", text: $key)
                            .plainTextEntry()
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
                        Text(hasKey ? "A key is stored on this device only. Usage is billed to your OpenRouter account." : "Create a key at openrouter.ai/keys. It stays on this device.")
                    }
                    Section {
                        TextField("Model id", text: $model)
                            .plainTextEntry()
                            .onSubmit { WebSettings.model = model.trimmed }
                            .accessibilityIdentifier("model-id")
                        Button("Use this model") { WebSettings.model = model.trimmed }
                            .disabled(model.trimmed.isEmpty)
                    } header: {
                        Text("Model")
                    } footer: {
                        Text("Any OpenRouter model id that supports tools, e.g. anthropic/claude-sonnet-5, openai/gpt-5.2, z-ai/glm-5.")
                    }
                }
                if hasProjects {
                    Section("Compiler") {
                        Text(PlaygroundHost.service?.toolchainStatus() ?? "no host").font(.footnote)
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: PlaygroundHost.service?.appVersion() ?? "")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

extension View {
    /// A field for keys and ids: no autocorrection or capitals.
    func plainTextEntry() -> some View {
        #if os(macOS)
        return autocorrectionDisabled()
        #else
        return autocorrectionDisabled().textInputAutocapitalization(.never)
        #endif
    }
}
