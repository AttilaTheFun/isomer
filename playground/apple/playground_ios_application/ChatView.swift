// The conversation column: AgentUI's AgentView (the transcript over the
// composer, in the Claude app's shape) with the Playground's controls in the
// composer — attach/import, the model and effort pills — and Edit/Run as
// bar items.

import AgentUI
import SwiftUI
#if os(iOS)
import PhotosUI
import UIKit
import UniformTypeIdentifiers
#endif

struct ChatView: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject private var auth: AuthStore
    @State private var draft = ""
    /// Images picked for the next message (JPEG bytes).
    @State private var attachments: [Data] = []
    #if os(iOS)
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var showAttachPicker = false
    @State private var importItems: [PhotosPickerItem] = []
    @State private var showImportPhotos = false
    @State private var showImportFiles = false
    #endif
    @EnvironmentObject private var projects: ProjectStore
    @State private var showModelSheet = false
    @State private var showEffortSheet = false
    @State private var showEditor = false
    @State private var compiling = false
    @State private var buildFailure: BuildFailure?
    @State private var webRunURL: URL?

    /// Where a run goes once the build is current.
    enum Destination { case web, native }

    var body: some View {
        agentView
        .sheet(isPresented: $showModelSheet) {
            ModelSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showEffortSheet) {
            EffortSheet()
                .presentationDetents([.medium])
        }
        // The three ways out of the chat — edit the source, run it on the
        // web, run it natively — all modal: the chat stays the home screen.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showEditor = true } label: { Image(systemName: "pencil") }
                    .accessibilityLabel("Edit")
                Button { run(.web) } label: { Image(systemName: "globe") }
                    .accessibilityLabel("Run on the web")
                Button { run(.native) } label: { Image(systemName: "play.fill") }
                    .accessibilityLabel("Run")
            }
        }
        .disabled(compiling)
        .overlay { if compiling { CompilingOverlay() } }
        .animation(.easeInOut(duration: 0.15), value: compiling)
        .sheet(isPresented: $showEditor) { EditorSheet(session: session) }
        .sheet(item: $buildFailure) { failure in BuildFailureSheet(diagnostics: failure.diagnostics) }
        #if os(iOS)
        .fullScreenCover(item: $webRunURL) { url in WebFullScreen(url: url) }
        #endif
        #if os(iOS)
        .background(Color(.systemBackground))
        #endif
    }

    private var agentView: some View {
        AgentView(
            messages: session.messages.map { TranscriptMessage($0, projects: projects, projectID: session.projectID) },
            activity: session.activity,
            error: session.error,
            emptyBody: "Describe a screen or an app. The agent writes the SwiftUI, compiles it on this device, fixes errors, and runs it in the preview.",
            emptyFootnote: "Model: \(auth.modelID)",
            draft: $draft,
            placeholder: "Describe the app…",
            busy: session.busy,
            attachmentCount: attachments.count,
            send: send,
            stop: { session.cancel() },
            controls: { controls },
            attachments: { attachmentTiles })
    }

    /// The composer's controls: the attach/import menu, the model and effort pills.
    @ViewBuilder private var controls: some View {
        #if os(iOS)
        Menu {
            Button { showAttachPicker = true } label: { Label("Attach photo to message", systemImage: "photo") }
            Divider()
            Button { showImportPhotos = true } label: { Label("Import photos into project", systemImage: "photo.on.rectangle") }
            Button { showImportFiles = true } label: { Label("Import files into project", systemImage: "doc") }
        } label: {
            Label("Attach", systemImage: "plus")
        }
        .labelStyle(.iconOnly)
        .agentSoftCircleButton()
        .accessibilityLabel("Attach")
        .photosPicker(isPresented: $showAttachPicker, selection: $pickedItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: pickedItems) { items in
            guard !items.isEmpty else { return }
            pickedItems = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let jpeg = Self.downscaledJPEG(data) {
                        attachments.append(jpeg)
                    }
                }
            }
        }
        .photosPicker(isPresented: $showImportPhotos, selection: $importItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: importItems) { items in
            guard !items.isEmpty else { return }
            importItems = []
            Task { await importPhotos(items) }
        }
        .fileImporter(isPresented: $showImportFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        #endif
        Button { showModelSheet = true } label: { AgentPillLabel(modelPill) }
            .agentPillButton()
            .accessibilityLabel("Model")
        Button { showEffortSheet = true } label: { AgentPillLabel(ReasoningEffort.title(for: auth.reasoningEffort)) }
            .agentPillButton()
            .accessibilityLabel("Effort")
    }

    /// The model's short name ("claude-sonnet-5").
    private var modelPill: String {
        let short = auth.modelID.split(separator: "/").last.map(String.init) ?? auth.modelID
        return short.isEmpty ? "Model" : short
    }

    private var attachmentTiles: some View {
        ForEach(attachments.indices, id: \.self) { index in
            AgentAttachmentTile(remove: { attachments.remove(at: index) }) {
                thumbnail(attachments[index])
            }
        }
    }

    @ViewBuilder private func thumbnail(_ data: Data) -> some View {
        #if os(iOS)
        if let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            Color.secondary.opacity(0.2)
        }
        #else
        Color.secondary.opacity(0.2)
        #endif
    }

    #if os(iOS)
    /// Photos go into the project's imported/ folder as full-size JPEGs.
    private func importPhotos(_ items: [PhotosPickerItem]) async {
        var imported: [String] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) ?? data
            let stamp = Int(Date().timeIntervalSince1970)
            if let path = projects.importAsset(jpeg, preferredName: "photo-\(stamp)-\(index + 1).jpg", in: session.projectID) {
                imported.append(path)
            }
        }
        noteImports(imported)
    }

    /// Files are copied as they are, keeping their names.
    private func importFiles(_ urls: [URL]) {
        var imported: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            if let path = projects.importAsset(data, preferredName: url.lastPathComponent, in: session.projectID) {
                imported.append(path)
            }
        }
        noteImports(imported)
    }

    private func noteImports(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        session.note("Imported into the app's Documents: " + paths.joined(separator: ", ") + ". Read them with Data(contentsOf: URL.documentsDirectory.appendingPathComponent(path)).", tool: "import")
    }

    /// Attachments are sent as JPEG, at most 1280px on the long side.
    static func downscaledJPEG(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 1280 / max(1, longest))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }
    #endif

    /// Build (unless the last build is current), then present the run —
    /// the compiler's diagnostics as a sheet when it fails.
    private func run(_ destination: Destination) {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
        Task { @MainActor in
            var wasm = session.buildIsCurrent ? session.buildProduct : nil
            if wasm == nil {
                compiling = true
                let result = await ProjectBuilder.build(session: session, projects: projects)
                compiling = false
                switch result {
                case .success(let built): wasm = built
                case .failure(let failure):
                    buildFailure = failure
                    return
                }
            }
            guard let wasm else { return }
            switch destination {
            case .native:
                // Presented by the app shell (MainSplitView), like the agent's runs.
                NotificationCenter.default.post(name: .playgroundRun, object: session.projectID)
            case .web:
                if let url = WebRunServer.shared.publish(wasm: wasm, sandbox: projects.sandboxDir(session.projectID)) { webRunURL = url }
            }
        }
    }

    private func send() {
        let text = draft
        let images = attachments
        draft = ""
        attachments = []
        session.send(text, images: images)
    }

}

extension TranscriptMessage {
    /// The app's chat model as a transcript row; image paths become file URLs.
    @MainActor init(_ message: ChatMessage, projects: ProjectStore, projectID: String) {
        let role: TranscriptMessage.Role
        switch message.role {
        case .user: role = .user
        case .assistant: role = .assistant
        case .tool: role = .tool
        }
        self.init(
            id: message.id, role: role, text: message.text,
            activities: message.toolCalls.map { AgentSession.activityLabel($0).replacingOccurrences(of: "…", with: "") },
            toolName: message.toolName,
            imageURLs: message.imagePaths.map { projects.dir(projectID).appendingPathComponent($0).absoluteString })
    }
}
