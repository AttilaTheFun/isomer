// Hot reloaders: a name, a polling interval and a URL that lists the
// published versions of an app as JSON. Opening one fetches the list, runs
// the newest version's wasm bundle full screen (the same run as a project's
// build), keeps polling, and offers to reload when a newer version appears.
// The use case: a remote Claude Code / Codex session publishes builds to a
// static site (tools/playground/publish_hot_reload.sh) while the phone
// follows along.
//
// versions.json: a bare array or {"versions": [...]}, newest FIRST, each
// {"version", "url" (absolute or relative to the JSON), "notes"?, "published"?}.

import Foundation
import SwiftUI
import IsomerWasmView

struct HotReloader: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var url: String
    var intervalSeconds: Double
    var createdAt: Date = Date()
    /// The last version that ran, and one announced but not yet run.
    var lastVersion: String?
    var pendingVersion: String?
    /// The first-run explanation was shown.
    var introduced = false
}

struct HotVersion: Codable, Hashable {
    var version: String
    var url: String
    var notes: String?
    var published: String?
}

enum HotReloadError: LocalizedError {
    case badURL, invalidJSON, empty, http(Int), emptyBundle(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "The URL is not valid."
        case .invalidJSON: return "The URL did not return a versions list (expected JSON: an array of {version, url}, newest first)."
        case .empty: return "No versions have been published yet."
        case .http(let status): return "The server answered HTTP \(status)."
        case .emptyBundle(let version): return "Version \(version) has no wasm bundle at its URL."
        }
    }
}

@MainActor
final class HotReloadStore: ObservableObject {
    @Published private(set) var reloaders: [HotReloader] = []
    private let root: URL

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HotReloaders", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([HotReloader].self, from: data) {
            reloaders = list
        }
    }

    private var indexURL: URL { root.appendingPathComponent("index.json") }

    private func save() {
        if let data = try? JSONEncoder().encode(reloaders) { try? data.write(to: indexURL, options: .atomic) }
    }

    @discardableResult
    func create(name: String, url: String, intervalSeconds: Double) -> HotReloader {
        let reloader = HotReloader(name: name, url: url, intervalSeconds: intervalSeconds)
        reloaders.append(reloader)
        save()
        return reloader
    }

    func update(_ reloader: HotReloader) {
        guard let index = reloaders.firstIndex(where: { $0.id == reloader.id }) else { return }
        reloaders[index] = reloader
        save()
    }

    func delete(_ id: String) {
        reloaders.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id, isDirectory: true))
        save()
    }

    // MARK: Fetching

    /// The published versions, newest first; throws on invalid or empty.
    func fetchVersions(_ reloader: HotReloader) async throws -> [HotVersion] {
        guard let url = URL(string: reloader.url.trimmingCharacters(in: .whitespaces)) else { throw HotReloadError.badURL }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 300 { throw HotReloadError.http(status) }
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data) } catch { throw HotReloadError.invalidJSON }
        let entries: [[String: Any]]
        if let list = raw as? [[String: Any]] {
            entries = list
        } else if let object = raw as? [String: Any], let list = object["versions"] as? [[String: Any]] {
            entries = list
        } else {
            throw HotReloadError.invalidJSON
        }
        let versions: [HotVersion] = entries.compactMap { entry in
            guard let version = entry["version"] as? String, let path = entry["url"] as? String,
                  let resolved = URL(string: path, relativeTo: url)?.absoluteString else { return nil }
            return HotVersion(version: version, url: resolved, notes: entry["notes"] as? String, published: entry["published"] as? String)
        }
        guard !versions.isEmpty else { throw HotReloadError.empty }
        return versions
    }

    /// The version's wasm bundle (cached under the reloader's folder).
    func fetchBundle(_ reloader: HotReloader, version: HotVersion) async throws -> Data {
        let folder = root.appendingPathComponent(reloader.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cached = folder.appendingPathComponent(version.version.replacingOccurrences(of: "/", with: "-") + ".wasm")
        if let data = try? Data(contentsOf: cached), !data.isEmpty { return data }
        guard let url = URL(string: version.url) else { throw HotReloadError.badURL }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 300 { throw HotReloadError.http(status) }
        guard !data.isEmpty else { throw HotReloadError.emptyBundle(version.version) }
        try? data.write(to: cached, options: .atomic)
        // Keep the cache to the two newest bundles.
        if let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let sorted = files.filter { $0.pathExtension == "wasm" }.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            for old in sorted.dropFirst(2) { try? FileManager.default.removeItem(at: old) }
        }
        return data
    }
}

// MARK: - New Hot Reloader sheet

struct NewHotReloaderSheet: View {
    @EnvironmentObject private var hot: HotReloadStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var interval: Double = 15

    private static let intervals: [(String, Double)] = [("5 seconds", 5), ("15 seconds", 15), ("30 seconds", 30), ("1 minute", 60), ("5 minutes", 300)]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("hot-name")
                    TextField("https://…/versions.json", text: $url)
                        .accessibilityIdentifier("hot-url")
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                } header: {
                    Text("Versions URL")
                } footer: {
                    Text("A URL (GitHub Pages works) returning the published versions as JSON: an array of {\"version\", \"url\"} objects, newest first; url points at the wasm bundle. tools/playground/publish_hot_reload.sh writes it.")
                }
                Section("Polling") {
                    Picker("Check every", selection: $interval) {
                        ForEach(Self.intervals, id: \.1) { entry in Text(entry.0).tag(entry.1) }
                    }
                }
            }
            .navigationTitle("New Hot Reloader")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        hot.create(name: trimmed.isEmpty ? "Hot Reloader" : trimmed, url: url, intervalSeconds: interval)
                        dismiss()
                    }
                    .disabled(URL(string: url.trimmingCharacters(in: .whitespaces))?.host == nil)
                }
            }
        }
    }
}

// MARK: - The run

/// Fetches, runs, polls and reloads one hot reloader, full screen.
struct HotReloadScreen: View {
    let reloaderID: String
    @EnvironmentObject private var hot: HotReloadStore
    @EnvironmentObject private var projects: ProjectStore
    @Environment(\.dismiss) private var dismiss

    private enum Phase { case loading, running(HotVersion, Data) }
    @State private var phase: Phase = .loading
    @State private var model = WasmViewModel.playground()
    @State private var generation = 0
    @State private var fetchError: String?
    @State private var showIntro = false
    @State private var newVersion: HotVersion?
    @State private var announced: Set<String> = []
    @State private var askDismiss = false
    @State private var poller: Task<Void, Never>?

    private var reloader: HotReloader? { hot.reloaders.first { $0.id == reloaderID } }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Fetching \(reloader?.name ?? "")…").foregroundColor(.secondary)
                }
            case .running(let version, let wasm):
                ServicedWasmView(wasm: wasm, label: "hot \(version.version)", projectID: "hot-\(reloaderID)", model: model)
                    .id(generation)
            }
        }
        .task { await load() }
        .onDisappear { poller?.cancel() }
        .onShake { askDismiss = true }
        .alert("Couldn't load \(reloader?.name ?? "the app")", isPresented: Binding(get: { fetchError != nil }, set: { if !$0 { fetchError = nil } })) {
            Button("Try Again") { Task { await load() } }
            Button("Cancel", role: .cancel) { leave() }
        } message: {
            Text(fetchError ?? "")
        }
        .alert("Running \(runningVersion)", isPresented: $showIntro) {
            Button("OK") {}
        } message: {
            Text("This is the newest published version of \(reloader?.name ?? "the app"). You'll be told when a new version is available. Shake the device to leave.")
        }
        .alert("New version available", isPresented: Binding(get: { newVersion != nil }, set: { if !$0 { newVersion = nil } })) {
            Button("Reload") { if let version = newVersion { Task { await reload(to: version) } } }
            Button("Later", role: .cancel) {
                if var current = reloader, let version = newVersion { current.pendingVersion = version.version; hot.update(current) }
            }
        } message: {
            Text("\(reloader?.name ?? "The app") \(newVersion?.version ?? "") was published\(newVersion?.notes.map { ": \($0)" } ?? ""). Reload now, or later — the next open uses it.")
        }
        .alert("Leave the app?", isPresented: $askDismiss) {
            Button("Leave", role: .destructive) { leave() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shake again any time to get back here.")
        }
    }

    private var runningVersion: String {
        if case .running(let version, _) = phase { return version.version }
        return ""
    }

    /// The initial fetch: newest version → bundle → run; then poll.
    private func load() async {
        guard let reloader else { return }
        phase = .loading
        do {
            let versions = try await hot.fetchVersions(reloader)
            let newest = versions[0]
            let wasm = try await hot.fetchBundle(reloader, version: newest)
            model = WasmViewModel.playground()
            generation += 1
            phase = .running(newest, wasm)
            announced = [newest.version]
            var updated = reloader
            updated.lastVersion = newest.version
            updated.pendingVersion = nil
            if !updated.introduced {
                updated.introduced = true
                showIntro = true
            }
            hot.update(updated)
            NSLog("[playground] hot reload %@: running %@", reloader.name, newest.version)
            startPolling()
        } catch {
            fetchError = error.localizedDescription
            NSLog("[playground] hot reload %@: %@", reloader.name, error.localizedDescription)
        }
    }

    private func startPolling() {
        poller?.cancel()
        guard let reloader else { return }
        let interval = max(2, reloader.intervalSeconds)
        poller = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let current = self.reloader else { return }
                guard let versions = try? await hot.fetchVersions(current), let newest = versions.first else { continue }
                if newest.version != runningVersion, !announced.contains(newest.version), newVersion == nil {
                    announced.insert(newest.version)
                    newVersion = newest
                    NSLog("[playground] hot reload %@: new version %@", current.name, newest.version)
                }
            }
        }
    }

    /// Swap the running build for `version`: graceful shutdown, then the
    /// new bundle in a fresh model.
    private func reload(to version: HotVersion) async {
        guard let reloader else { return }
        do {
            let wasm = try await hot.fetchBundle(reloader, version: version)
            _ = await model.shutdown(timeout: 1)
            model = WasmViewModel.playground()
            generation += 1
            phase = .running(version, wasm)
            var updated = reloader
            updated.lastVersion = version.version
            updated.pendingVersion = nil
            hot.update(updated)
            NSLog("[playground] hot reload %@: reloaded to %@", reloader.name, version.version)
        } catch {
            fetchError = error.localizedDescription
        }
    }

    private func leave() {
        poller?.cancel()
        Task { @MainActor in
            _ = await model.shutdown(timeout: 1)
            dismiss()
        }
    }
}
