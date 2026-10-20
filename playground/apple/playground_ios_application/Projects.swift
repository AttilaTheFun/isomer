// Projects: one directory per project under Documents/Projects/<id>/ with
// the Swift sources (files/), the chat transcript (chat.json) and metadata
// (project.json). The sidebar lists them; the agent edits their files.

import CryptoKit
import Foundation

struct Project: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var createdAt: Date
    /// For a bundled sample: the hash of the source it was seeded with, so a
    /// newer bundle replaces the file while it is still untouched.
    var sampleHash: String?
}

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published var selection: String?

    let root: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
        CrashRecorder.shared.noteCrashes(in: self)
        // Out of the box: one project per bundled example (the templates).
        // Each example seeds once per install — a deleted one stays deleted
        // (recreate it from the New Project picker); an untouched one is
        // refreshed when the bundled source changes.
        let selected = selection
        var seeded = Set(UserDefaults.standard.stringArray(forKey: Self.seededKey) ?? [])
        for template in ProjectTemplate.examples {
            let source = template.source
            let hash = Self.hash(source)
            if var project = projects.first(where: { $0.name == template.name }) {
                seeded.insert(template.id)
                // Refresh only a project whose file still matches the source it
                // was seeded with, or any version this template has shipped
                // (TemplateHistory: a project from before hashes, or seeded by
                // another build). Anything else carries the user's edits.
                let file = read(projectMainFile, in: project.id)
                let current = file.map(Self.hash)
                let shipped = file.flatMap(TemplateHistory.template(of:)) == template.resource.map { $0 + ".swift" }
                guard project.sampleHash == current || shipped, current != hash else {
                    if project.sampleHash == nil, current == hash { project.sampleHash = hash; save(project) }
                    continue
                }
                write(projectMainFile, contents: source, in: project.id)
                try? FileManager.default.removeItem(at: buildURL(project.id))
                project.sampleHash = hash
                save(project)
            } else if !seeded.contains(template.id) {
                create(named: template.name, template: template)
                seeded.insert(template.id)
            }
        }
        UserDefaults.standard.set(Array(seeded).sorted(), forKey: Self.seededKey)
        reload()
        selection = selected.flatMap { id in projects.first(where: { $0.id == id })?.id } ?? projects.first?.id
    }

    func reload() {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        projects = ids.compactMap { id -> Project? in
            let meta = dir(id).appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: meta) else { return nil }
            return try? JSONDecoder().decode(Project.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func filesDir(_ id: String) -> URL { dir(id).appendingPathComponent("files", isDirectory: true) }

    private static let seededKey = "playground.seededTemplates"

    /// Creates a project from a template (blank by default) with its
    /// App.swift written; bundled examples remember the seeded source's hash.
    @discardableResult
    func create(named name: String, template: ProjectTemplate = .blank) -> Project {
        var project = Project(id: UUID().uuidString, name: name, createdAt: Date())
        try? FileManager.default.createDirectory(at: filesDir(project.id), withIntermediateDirectories: true)
        let source = template.source
        if template.resource != nil { project.sampleHash = Self.hash(source) }
        save(project)
        write(projectMainFile, contents: source, in: project.id)
        reload()
        selection = project.id
        return project
    }

    func save(_ project: Project) {
        let meta = dir(project.id).appendingPathComponent("project.json")
        try? JSONEncoder().encode(project).write(to: meta)
    }

    func rename(_ id: String, to name: String) {
        guard var project = projects.first(where: { $0.id == id }) else { return }
        project.name = name
        save(project)
        reload()
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: dir(id))
        reload()
        if selection == id { selection = projects.first?.id }
    }

    // MARK: Files

    func fileNames(in id: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: filesDir(id).path)) ?? [])
            .filter { $0.hasSuffix(".swift") }.sorted()
    }

    func fileURLs(in id: String) -> [URL] {
        fileNames(in: id).map { filesDir(id).appendingPathComponent($0) }
    }

    func read(_ name: String, in id: String) -> String? {
        try? String(contentsOf: filesDir(id).appendingPathComponent(name), encoding: .utf8)
    }

    func write(_ name: String, contents: String, in id: String) {
        try? FileManager.default.createDirectory(at: filesDir(id), withIntermediateDirectories: true)
        try? contents.write(to: filesDir(id).appendingPathComponent(name), atomically: true, encoding: .utf8)
        objectWillChange.send()
    }

    func deleteFile(_ name: String, in id: String) {
        try? FileManager.default.removeItem(at: filesDir(id).appendingPathComponent(name))
        objectWillChange.send()
    }

    // MARK: Last successful build (for deep-linked full-screen runs)

    static func hash(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func buildURL(_ id: String) -> URL { dir(id).appendingPathComponent("build.wasm") }

    // MARK: Run snapshots

    /// A run's own copy of the project: the sources as they were when the
    /// run was requested, and the wasm compiled from exactly those, so an
    /// edit landing mid-compile (the agent's, or the user's) can neither tear
    /// the build nor change what a running copy is.
    struct RunSnapshot {
        let dir: URL
        let files: [URL]
        var wasmURL: URL { dir.appendingPathComponent("build.wasm") }
    }

    private static var runsRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("runs", isDirectory: true)
    }

    /// Copies the project's source files into a fresh temporary directory.
    func snapshotForRun(_ id: String) -> RunSnapshot {
        let dir = Self.runsRoot.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sources = dir.appendingPathComponent("src", isDirectory: true)
        try? FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        var files: [URL] = []
        for file in fileURLs(in: id) {
            let copy = sources.appendingPathComponent(file.lastPathComponent)
            if (try? FileManager.default.copyItem(at: file, to: copy)) != nil { files.append(copy) }
        }
        return RunSnapshot(dir: dir, files: files)
    }

    /// Snapshots are per process: clear the previous launch's on startup.
    static func pruneRunSnapshots() {
        try? FileManager.default.removeItem(at: runsRoot)
    }

    // MARK: Imported assets (files/photos the mini app can read)

    /// A run's home (its Documents, Application Support, Caches and
    /// UserDefaults: WasmViewModel.guestHomeDirectory), and the imported/
    /// folder in its Documents, where the app reads what was imported
    /// (`URL.documentsDirectory.appendingPathComponent("imported/<name>")`).
    func sandboxDir(_ id: String) -> URL { dir(id).appendingPathComponent("data", isDirectory: true) }
    func importedDir(_ id: String) -> URL {
        let documents = sandboxDir(id).appendingPathComponent("Documents", isDirectory: true)
        let folder = documents.appendingPathComponent("imported", isDirectory: true)
        // Before 0.31 imports were at the sandbox's top (the file service's
        // root): moved once into Documents.
        let old = sandboxDir(id).appendingPathComponent("imported", isDirectory: true)
        if FileManager.default.fileExists(atPath: old.path), !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: old, to: folder)
        }
        return folder
    }

    /// Copies `data` into imported/ under a unique file name; returns its
    /// path in Documents ("imported/<name>").
    @discardableResult
    func importAsset(_ data: Data, preferredName: String, in id: String) -> String? {
        let folder = importedDir(id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (preferredName as NSString).deletingPathExtension.replacingOccurrences(of: "/", with: "-")
        let ext = (preferredName as NSString).pathExtension
        var name = ext.isEmpty ? base : base + "." + ext
        var counter = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            counter += 1
        }
        guard (try? data.write(to: folder.appendingPathComponent(name))) != nil else { return nil }
        objectWillChange.send()
        return "imported/" + name
    }

    /// The imported assets (sandbox-relative path, size in bytes).
    func importedAssets(in id: String) -> [(path: String, size: Int)] {
        let folder = importedDir(id)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        return names.map { name in
            let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? NSNumber)?.intValue ?? 0
            return ("imported/" + name, size)
        }
    }

    /// Stores an attachment (JPEG bytes) under the project's images/ folder;
    /// returns its message-relative path.
    func saveImage(_ jpeg: Data, in id: String) -> String? {
        let folder = dir(id).appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "images/\(UUID().uuidString).jpg"
        return (try? jpeg.write(to: dir(id).appendingPathComponent(name))) != nil ? name : nil
    }

    func imageData(_ path: String, in id: String) -> Data? {
        try? Data(contentsOf: dir(id).appendingPathComponent(path))
    }

    /// Identifies the app build that produced a saved wasm: the embedded
    /// toolchain (the framework the project compiles against) ships inside
    /// the app, so a build from an older app is stale and must be redone.
    static let toolchainStamp: String = {
        // Bundle timestamps are normalized (1980) by the build, so hash the
        // SDK itself: the Swift modules' contents (small) plus the archive
        // names and sizes, and the app version.
        let bundle = Bundle.main
        var hasher = SHA256()
        hasher.update(data: Data(((bundle.infoDictionary?["CFBundleVersion"] as? String) ?? "").utf8))
        let root = bundle.url(forResource: "playground_sdk", withExtension: nil) ?? bundle.resourceURL
        if let root {
            let modules = root.appendingPathComponent("modules")
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: modules.path)) ?? []).sorted()
            for name in names {
                hasher.update(data: Data(name.utf8))
                if let data = try? Data(contentsOf: modules.appendingPathComponent(name)) { hasher.update(data: data) }
            }
            let lib = root.appendingPathComponent("lib")
            let archives = ((try? FileManager.default.contentsOfDirectory(atPath: lib.path)) ?? []).sorted()
            for name in archives {
                let size = (try? FileManager.default.attributesOfItem(atPath: lib.appendingPathComponent(name).path)[.size] as? NSNumber)?.intValue ?? 0
                hasher.update(data: Data("\(name):\(size)".utf8))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }()

    private func stampURL(_ id: String) -> URL { dir(id).appendingPathComponent("build.stamp") }

    func saveBuild(_ wasm: Data, in id: String) {
        try? wasm.write(to: buildURL(id))
        try? Self.toolchainStamp.write(to: stampURL(id), atomically: true, encoding: .utf8)
    }

    /// The last build, unless it came from a different app build.
    func loadBuild(_ id: String) -> Data? {
        guard let stamp = try? String(contentsOf: stampURL(id), encoding: .utf8), stamp == Self.toolchainStamp else {
            try? FileManager.default.removeItem(at: buildURL(id))
            return nil
        }
        return try? Data(contentsOf: buildURL(id))
    }

    /// `iso-playground://project/<id>` opens the project's last build full
    /// screen (relaunching without a link returns to the main UI).
    static func deepLink(for id: String) -> URL {
        URL(string: "iso-playground://project/\(id)")!
    }

    static func projectID(from url: URL) -> String? {
        guard url.scheme == "iso-playground", url.host == "project" else { return nil }
        let id = url.pathComponents.dropFirst().first ?? ""
        return id.isEmpty ? nil : id
    }

    // MARK: Chat transcript

    func loadMessages(_ id: String) -> [ChatMessage] {
        let url = dir(id).appendingPathComponent("chat.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
    }

    func saveMessages(_ messages: [ChatMessage], in id: String) {
        let url = dir(id).appendingPathComponent("chat.json")
        try? JSONEncoder().encode(messages).write(to: url)
    }

    /// A zip of the project's sources for the share sheet, made with the
    /// file coordinator's for-uploading read (no zip library needed).
    func zip(_ id: String) -> URL? {
        guard let project = projects.first(where: { $0.id == id }) else { return nil }
        let source = filesDir(id)
        let safeName = project.name.replacingOccurrences(of: "/", with: "-")
        let target = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(safeName).zip")
        try? FileManager.default.removeItem(at: target)
        var result: URL?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .forUploading, error: &coordinationError) { zipped in
            if (try? FileManager.default.copyItem(at: zipped, to: target)) != nil { result = target }
        }
        return result
    }
}
