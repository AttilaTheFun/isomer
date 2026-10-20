// Playground — describe an app, an agent writes the SwiftUI, and the app
// compiles it to a `iso_hot` wasm reactor ON THE DEVICE and runs it:
//   • natively under WasmView (the real SwiftUI renderer), or
//   • on the web: the in-app server publishes it and SFSafariViewController
//     opens the react-renderer page — the same bytes, real DOM.
//
// Shell: a splash/sign-in screen until a model provider is linked
// (OpenRouter OAuth, or an Anthropic key), then a NavigationSplitView —
// projects sidebar (+ new) and the chat; editor + runs are modal from there.

import ApplePlatformServices
import PlatformServices
import AgentUI
import SwiftUI
import IsomerWasmView
#if os(iOS)
import UIKit
#endif

@main
struct PlaygroundApp: App {
    @StateObject private var auth = AuthStore()
    @StateObject private var projects = ProjectStore()
    @StateObject private var hot = HotReloadStore()
    /// Deep link `iso-playground://project/<id>`: run that project's last
    /// build full screen over whatever is showing.
    @State private var linkedProject: String?

    init() {
        // The app's own shared screens (`.onShake`) read the compiled-in
        // service table, like the example apps do.
        installPlatformDeviceMotion(deviceMotion: NativeDeviceMotionService.shared)
        // Transcript images are project files: decode them from disk.
        TranscriptImages.render = { url, maxEdge in
            #if os(iOS)
            if let fileURL = URL(string: url), let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) {
                return AnyView(Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: maxEdge, maxHeight: maxEdge))
            }
            #endif
            return AnyView(Color.secondary.opacity(0.2).frame(width: 96, height: 96))
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isSignedIn {
                    MainSplitView()
                } else {
                    SplashView()
                }
            }
            .environmentObject(auth)
            .environmentObject(projects)
            .environmentObject(hot)
            .onOpenURL { url in
                if let id = ProjectStore.projectID(from: url) { linkedProject = id }
            }
            .onAppear {
                // Headless twin of the deep link (simctl openurl shows a
                // confirmation prompt that can't be tapped from a script).
                if let key = ProcessInfo.processInfo.environment["ISO_PLAYGROUND_OPEN_PROJECT"], !key.isEmpty {
                    // A project id, or a project NAME (ids are random per install).
                    linkedProject = projects.projects.first { $0.id == key || $0.name == key }?.id ?? key
                }
            }
            #if os(iOS)
            .fullScreenCover(item: $linkedProject) { id in
                FullScreenRun(projectID: id).environmentObject(projects)
            }
            #endif
        }
    }
}

/// How a headless run asks to run the current build.
enum RunDestination: String, Identifiable {
    case native
    case safari
    var id: String { rawValue }
}

struct MainSplitView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var hot: HotReloadStore
    @State private var sessions: [String: AgentSession] = [:]
    @State private var showNewProject = false
    @State private var showNewHotReloader = false
    @State private var activeReloader: HotReloader?
    @State private var showSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// The native run presented over the whole shell (from the chat's play
    /// button or the agent's run/screenshot tools, whichever screen is up).
    @State private var run: RunRequest?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            // The chat is the project's home; the editor and both runs are
            // modal from its toolbar (the project's SwiftUI is meant to
            // feel like the whole app when it runs).
            if let session = currentSession {
                ChatView(session: session)
                    .navigationTitle(projects.projects.first(where: { $0.id == session.projectID })?.name ?? "Chat")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
            } else {
                Text("Create a project to start").foregroundColor(.secondary)
            }
        }
        .sheet(isPresented: $showNewProject) { TemplateNewProjectSheet() }
        .sheet(isPresented: $showNewHotReloader) { NewHotReloaderSheet() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        #if os(iOS)
        .fullScreenCover(item: $activeReloader) { reloader in HotReloadScreen(reloaderID: reloader.id) }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .playgroundRun)) { note in
            guard let id = note.object as? String,
                  let wasm = sessions[id]?.buildProduct ?? projects.loadBuild(id) else { return }
            run = RunRequest(projectID: id, wasm: wasm)
        }
        .onReceive(NotificationCenter.default.publisher(for: .playgroundStopRun)) { _ in run = nil }
        #if os(iOS)
        .fullScreenCover(item: $run) { request in
            PlayFullScreen(wasm: request.wasm, projectID: request.projectID)
        }
        #endif
        .onAppear {
            ProjectStore.pruneRunSnapshots()
            autorun()
        }
    }

    private var currentSession: AgentSession? {
        guard let id = projects.selection, projects.projects.contains(where: { $0.id == id }) else { return nil }
        if let existing = sessions[id] { return existing }
        let session = AgentSession(projectID: id, projects: projects, auth: auth)
        DispatchQueue.main.async { sessions[id] = session }
        return session
    }

    private var sidebar: some View {
        List(selection: $projects.selection) {
            Section("Projects") {
                // Always first: the way to make a project (was the + button).
                Button { showNewProject = true } label: {
                    Label("New Project", systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("new-project")
                ForEach(projects.projects) { project in
                    Label(project.name, systemImage: "app.dashed")
                        .tag(project.id)
                }
                .onDelete { offsets in
                    for index in offsets { projects.delete(projects.projects[index].id) }
                }
            }
            Section {
                Button { showNewHotReloader = true } label: {
                    Label("New Hot Reloader", systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("new-hot-reloader")
                ForEach(hot.reloaders) { reloader in
                    Button { activeReloader = reloader } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(reloader.name)
                                // Nothing runs while the list shows: tapping the row
                                // starts the installed version (or the newer pending one).
                                Text(reloader.pendingVersion.map { "\($0) ready — tap to run" } ?? reloader.lastVersion.map { "Installed \($0)" } ?? reloader.url)
                                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .foregroundColor(.primary)
                    .accessibilityIdentifier("hot-reloader-\(reloader.name)")
                }
                .onDelete { offsets in
                    for index in offsets { hot.delete(hot.reloaders[index].id) }
                }
            } header: {
                Text("Hot Reloaders")
            } footer: {
                Text("Follows an app published to a URL (e.g. by a remote Claude Code session): runs the newest version and reloads when a new one appears.")
            }
        }
        .navigationTitle("Playground")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
    }

    /// Headless hooks: ISO_PLAYGROUND_AUTORUN=native|safari|all|check|agent —
    /// build+run the selected project, compile every project, syntax-check
    /// the selected one's files, or drive the agent loop (with
    /// ISO_PLAYGROUND_AGENT_MOCK=1, no key needed).
    private func autorun() {
        guard let auto = ProcessInfo.processInfo.environment["ISO_PLAYGROUND_AUTORUN"],
              let session = currentSession else { return }
        let parts = auto.split(separator: "x", maxSplits: 1).map(String.init)
        let name = parts.first ?? auto
        let count = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
        switch name {
        case "all":
            // Every project in turn with the app's compiler (tests/e2e: the
            // templates compile out of the box), then "compiled all".
            let all = projects.projects.map { ($0.name, projects.fileURLs(in: $0.id)) }
            Task.detached {
                for (project, files) in all {
                    do {
                        let wasm = try ToolchainCompiler.compile(files: files)
                        NSLog("[playground] compiled %@: %d bytes", project, wasm.count)
                    } catch {
                        NSLog("[playground] compile failed %@: %@", project, (error as? CompileError)?.diagnostics ?? "\(error)")
                    }
                }
                NSLog("[playground] compiled all")
            }
        case "check":
            let files = projects.fileURLs(in: session.projectID)
            DispatchQueue.global().async {
                for file in files {
                    let source = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                    let found = ToolchainCompiler.syntaxCheck(source: source, fileName: file.lastPathComponent)
                    NSLog("[playground] check %@: %d diagnostics %@", file.lastPathComponent, found.count,
                          found.map { "L\($0.line):\($0.column) \($0.severity): \($0.message)" }.joined(separator: " | "))
                }
            }
        case "agent":
            let project = projects.create(named: "Agent test")
            let agent = AgentSession(projectID: project.id, projects: projects, auth: auth)
            sessions[project.id] = agent
            agent.send("Build a counter app with an Add button.")
            // Report the transcript once the loop settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
                for message in agent.messages {
                    NSLog("[playground] agent %@: %@ %@", message.role.rawValue, String(message.text.prefix(80)),
                          message.toolCalls.map(\.name).joined(separator: ","))
                    if message.toolName == "ui_tree" {
                        for line in message.text.split(separator: "\n").prefix(400) { NSLog("[playground] tree %@", String(line)) }
                    }
                }
                NSLog("[playground] agent build product: %d bytes, files: %@", agent.buildProduct?.count ?? 0,
                      projects.fileNames(in: project.id).joined(separator: ","))
            }
        default:
            for i in 0..<max(count, 1) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 12 * Double(i)) {
                    let files = projects.fileURLs(in: session.projectID)
                    Task.detached {
                        let result = Result { try ToolchainCompiler.compile(files: files) }
                        await MainActor.run {
                            switch result {
                            case .success(let wasm):
                                NSLog("[playground] compiled %d bytes", wasm.count)
                                session.buildProduct = wasm
                                session.buildCount += 1
                                session.buildIsCurrent = true
                                projects.saveBuild(wasm, in: session.projectID)
                                if name == "safari", let url = WebRunServer.shared.publish(wasm: wasm) {
                                    NSLog("[playground] published %@", url.absoluteString)
                                }
                            case .failure(let error):
                                NSLog("[playground] compile failed: %@", (error as? CompileError)?.diagnostics ?? "\(error)")
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - New project (name + template)

/// New Project on the shared sheet; the templates are the bundled samples.
struct TemplateNewProjectSheet: View {
    @EnvironmentObject private var projects: ProjectStore

    var body: some View {
        NewProjectSheet(
            templates: ProjectTemplate.all.map {
                ProjectTemplateChoice(id: $0.id, name: $0.name, subtitle: $0.subtitle, isBlank: $0.resource == nil)
            }
        ) { name, choice in
            _ = projects.create(named: name, template: ProjectTemplate.all.first { $0.id == choice.id } ?? .blank)
        }
    }
}

// MARK: - Model + Effort sheets (from the composer's pills)

/// Pick the model: the selected one in its own section, then the provider's
/// catalog — searchable, sortable, and filterable (OpenRouter lists hundreds).
struct ModelSheet: View {
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss
    @State private var models: [ModelInfo] = []
    /// OpenRouter's most-used models for programming, rank order.
    @State private var popular: [String] = []
    @State private var loading = false
    @State private var query = ""
    @AppStorage("playground.models.sort") private var sort: ModelSort = .popular
    @AppStorage("playground.models.toolsOnly") private var toolsOnly = true
    @AppStorage("playground.models.visionOnly") private var visionOnly = false
    @AppStorage("playground.models.freeOnly") private var freeOnly = false
    @AppStorage("playground.models.popularOnly") private var popularOnly = false
    @AppStorage("playground.models.provider") private var providerFilter = ""

    enum ModelSort: String, CaseIterable, Identifiable {
        case popular, arena, newest, name, priceLow, priceHigh, context
        var id: String { rawValue }
        var title: String {
            switch self {
            case .popular: return "Most used for coding"
            case .arena: return "Coding arena score"
            case .newest: return "Newest"
            case .name: return "Name"
            case .priceLow: return "Price: low to high"
            case .priceHigh: return "Price: high to low"
            case .context: return "Context: largest"
            }
        }
    }

    private var providers: [String] {
        Array(Set(models.map(\.provider).filter { !$0.isEmpty })).sorted()
    }

    private var filtered: [ModelInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var list = models.filter { model in
            (q.isEmpty || model.id.lowercased().contains(q) || model.name.lowercased().contains(q))
                && (!toolsOnly || model.supportsTools)
                && (!visionOnly || model.supportsImages)
                && (!freeOnly || model.isFree)
                && (!popularOnly || popularRank[model.id] != nil)
                && (providerFilter.isEmpty || model.provider == providerFilter)
        }
        switch sort {
        case .popular:
            // Ranked models first (by rank), then the rest newest first.
            list.sort {
                switch (popularRank[$0.id], popularRank[$1.id]) {
                case let (a?, b?): return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                default: return ($0.created ?? 0) > ($1.created ?? 0)
                }
            }
        case .arena: list.sort { ($0.codingArena ?? -1) > ($1.codingArena ?? -1) }
        case .newest: list.sort { ($0.created ?? 0) > ($1.created ?? 0) }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .priceLow: list.sort { ($0.promptPrice ?? 1e9) < ($1.promptPrice ?? 1e9) }
        case .priceHigh: list.sort { ($0.promptPrice ?? -1) > ($1.promptPrice ?? -1) }
        case .context: list.sort { ($0.contextLength ?? 0) > ($1.contextLength ?? 0) }
        }
        return list
    }

    private var popularRank: [String: Int] {
        Dictionary(uniqueKeysWithValues: popular.enumerated().map { ($1, $0) })
    }

    private var selected: ModelInfo {
        models.first(where: { $0.id == auth.modelID })
            ?? ModelInfo(id: auth.modelID, name: auth.modelID.split(separator: "/").last.map(String.init) ?? auth.modelID)
    }

    private var filtersActive: Bool { visionOnly || freeOnly || popularOnly || !providerFilter.isEmpty || !toolsOnly }

    var body: some View {
        NavigationStack {
            List {
                Section("Selected") {
                    row(selected, showsCheck: false)
                }
                Section {
                    if loading { ProgressView() }
                    ForEach(filtered.prefix(300)) { model in
                        Button { auth.modelID = model.id } label: { row(model, showsCheck: true) }
                    }
                    if filtered.count > 300 {
                        Text("\(filtered.count - 300) more — narrow the search or filters.")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                } header: {
                    Text("\(auth.provider?.title ?? "Models") · \(filtered.count)")
                } footer: {
                    Text("Prices are per million prompt tokens. Cheap models are fine for experiments; Opus/Fable for hard builds.")
                }
            }
            .searchable(text: $query, prompt: "Search models")
            .navigationTitle("Model")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(ModelSort.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                        Section("Show only") {
                            if !popular.isEmpty { Toggle("Popular for coding", isOn: $popularOnly) }
                            Toggle("Tool use", isOn: $toolsOnly)
                            Toggle("Image input", isOn: $visionOnly)
                            Toggle("Free", isOn: $freeOnly)
                        }
                        if !providers.isEmpty {
                            Picker("Provider", selection: $providerFilter) {
                                Text("All providers").tag("")
                                ForEach(providers, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.menu)
                        }
                    } label: {
                        Label("Sort and filter", systemImage: "line.3.horizontal.decrease")
                            .foregroundStyle(filtersActive ? Color.accentColor : Color.primary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await loadModels() }
        }
    }

    /// Name, id, and the capability badges (coding rank, image input, no
    /// tools); price and context on the right.
    private func row(_ model: ModelInfo, showsCheck: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name).foregroundColor(.primary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(model.id).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    if let rank = popularRank[model.id] { badge("#\(rank + 1) coding") }
                    if model.supportsImages { badge("image") }
                    if !model.supportsTools { badge("no tools") }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if let price = model.priceLabel { Text(price).font(.caption).foregroundColor(.secondary) }
                if let context = model.contextLabel { Text(context).font(.caption2).foregroundColor(.secondary) }
            }
            if showsCheck, model.id == auth.modelID {
                Image(systemName: "checkmark").foregroundColor(.accentColor)
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundColor(.secondary)
    }

    private func loadModels() async {
        switch auth.provider {
        case .anthropic: models = ModelCatalog.anthropicDirect
        case .openRouter:
            guard let key = auth.key else { return }
            models = ModelCatalog.cachedOpenRouterModels()
            popular = ModelCatalog.cachedPopularForCoding()
            loading = models.isEmpty
            async let freshModels = ModelCatalog.openRouterModels(key: key)
            async let freshPopular = ModelCatalog.openRouterPopularForCoding(key: key)
            let (fetched, ranked) = await (freshModels, freshPopular)
            if !fetched.isEmpty { models = fetched }
            if !ranked.isEmpty { popular = ranked }
            loading = false
        case nil: break
        }
    }
}

/// The reasoning-effort values ("" = the model's default). The choices
/// follow what the selected model accepts (OpenRouter lists them; some
/// models add xhigh/max), falling back to low/medium/high.
enum ReasoningEffort {
    static let all: [(id: String, title: String)] = [
        ("", "Default"), ("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra high"), ("max", "Max"),
    ]
    static let standard = ["low", "medium", "high"]

    static func values(forModel modelID: String) -> [(id: String, title: String)] {
        let supported = ModelCatalog.cachedOpenRouterModels().first(where: { $0.id == modelID })?.supportedEfforts ?? []
        let allowed = supported.isEmpty ? standard : supported
        return all.filter { $0.id.isEmpty || allowed.contains($0.id) }
    }

    static func title(for id: String) -> String {
        all.first(where: { $0.id == id })?.title ?? id.capitalized
    }
}

/// The reasoning effort (from the composer's Effort pill): pick one, done.
struct EffortSheet: View {
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(ReasoningEffort.values(forModel: auth.modelID), id: \.id) { value in
                    Button {
                        auth.reasoningEffort = value.id
                        dismiss()
                    } label: {
                        HStack {
                            Text(value.title).foregroundColor(.primary)
                            Spacer()
                            if value.id == auth.reasoningEffort { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                        }
                    }
                }
            }
            .navigationTitle("Effort")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Settings (model, provider)

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Provider", value: auth.provider?.title ?? "—")
                    LabeledContent("Model", value: auth.modelID)
                    Button("Sign out", role: .destructive) { auth.signOut(); dismiss() }
                }
                Section {
                    Text("Change the model and effort from the pills beside the chat input.")
                        .font(.footnote).foregroundColor(.secondary)
                }
                RendererSettingsSection(
                    nativeName: "SwiftUI", gpuName: "Metal",
                    footer: "SwiftUI renders a run with real views; Metal is the self-drawing SwiftGPU renderer. Applies to the next run.")
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// A request to run a build full screen.
struct RunRequest: Identifiable {
    let id = UUID()
    let projectID: String
    let wasm: Data
}

extension NativeDeviceMotionService: PlatformServices.DeviceMotionService {}
