// Hot reloaders: a name, a polling interval and a URL that lists the
// published versions of an app as JSON. Running one runs the newest
// version's wasm reactor full screen (the host's run, as a project's build
// runs), keeps polling, and offers to reload when a newer version appears.
// The use case: a remote coding session publishes builds to a static site
// (tools/playground/publish_hot_reload.sh) while the device follows along.
//
// versions.json: a bare array or {"versions": [...]}, newest FIRST, each
// {"version", "url" (absolute or relative to the JSON), "notes"?, "published"?}.

import Foundation
#if (os(Linux) || os(Windows)) && canImport(FoundationNetworking)
// The toolchain's Foundation there (Isomer's is on wasm and Android) keeps
// URLSession in a module of its own.
import FoundationNetworking
#endif
import Observation
import SwiftUI
import Isomer

struct HotReloader: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var url: String
    var intervalSeconds: Double
    /// The last version that ran, and one announced but not yet run.
    var lastVersion: String?
    var pendingVersion: String?
}

struct HotVersion: Hashable, Identifiable {
    var version: String
    var url: String
    var notes: String?
    var published: String?
    var id: String { version }
}

enum HotReloadError: Error, CustomStringConvertible {
    case badURL, invalidJSON, empty, http(Int)

    var description: String {
        switch self {
        case .badURL: return "The URL is not valid."
        case .invalidJSON: return "The URL did not return a versions list (expected JSON: an array of {version, url}, newest first)."
        case .empty: return "No versions have been published yet."
        case .http(let status): return "The server answered HTTP \(status)."
        }
    }
}

/// The reloaders, kept in Application Support/HotReloaders/index.json.
@MainActor @Observable
final class HotReloadStore {
    private(set) var reloaders: [HotReloader] = []

    init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let list = try? JSONDecoder().decode([HotReloader].self, from: data) {
            reloaders = list
        }
    }

    private static var indexURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HotReloaders", isDirectory: true)
            .appendingPathComponent("index.json", isDirectory: false)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(reloaders) else { return }
        try? FileManager.default.createDirectory(at: Self.indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.indexURL)
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
        save()
    }

    /// The published versions, newest first; throws on invalid or empty.
    static func fetchVersions(_ address: String) async throws -> [HotVersion] {
        guard let url = URL(string: address.trimmed), url.host != nil else { throw HotReloadError.badURL }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 300 { throw HotReloadError.http(status) }
        guard let json = parseJSON(String(decoding: data, as: UTF8.self)) else { throw HotReloadError.invalidJSON }
        guard let entries = json.array ?? json["versions"].array else { throw HotReloadError.invalidJSON }
        let versions: [HotVersion] = entries.compactMap { entry in
            guard let version = entry["version"].string, let path = entry["url"].string,
                  let resolved = URL(string: path, relativeTo: url)?.absoluteString else { return nil }
            return HotVersion(version: version, url: resolved, notes: entry["notes"].string, published: entry["published"].string)
        }
        guard !versions.isEmpty else { throw HotReloadError.empty }
        return versions
    }
}

// MARK: - New Hot Reloader sheet

struct NewHotReloaderSheet: View {
    let created: (HotReloader) -> Void
    @Environment(HotReloadStore.self) private var hot
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var interval: Double = 15

    private static let intervals: [(String, Double)] = [("5 seconds", 5), ("15 seconds", 15), ("30 seconds", 30), ("1 minute", 60), ("5 minutes", 300)]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("hot-name")
                    TextField("https://…/versions.json", text: $url)
                        .plainTextEntry()
                        .accessibilityIdentifier("hot-url")
                } header: {
                    Text("Versions URL")
                } footer: {
                    Text("A URL (GitHub Pages works) returning the published versions as JSON: an array of {\"version\", \"url\"} objects, newest first; url points at the wasm reactor. tools/playground/publish_hot_reload.sh writes it.")
                }
                Section("Polling") {
                    Picker("Check every", selection: $interval) {
                        ForEach(Self.intervals, id: \.1) { entry in Text(entry.0).tag(entry.1) }
                    }
                }
            }
            .navigationTitle("New Hot Reloader")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let trimmed = name.trimmed
                        let reloader = hot.create(name: trimmed.isEmpty ? "Hot Reloader" : trimmed, url: url.trimmed, intervalSeconds: interval)
                        created(reloader)
                        dismiss()
                    }
                    .disabled(URL(string: url.trimmed)?.host == nil)
                    .accessibilityIdentifier("hot-create")
                }
            }
        }
    }
}

// MARK: - A reloader's columns

/// A reloader's versions (the content column): run the newest, or any
/// other; while one runs, the newer ones are offered as they appear.
struct HotReloaderView: View {
    let reloader: HotReloader
    let deleted: () -> Void
    @Environment(HotReloadStore.self) private var hot
    @State private var versions: [HotVersion] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var running: HotVersion?
    @State private var newVersion: HotVersion?
    @State private var announced: Set<String> = []
    @State private var poller: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                Button { if let newest = versions.first { run(newest) } } label: {
                    Label("Run the newest version", systemImage: "play.fill")
                }
                .disabled(versions.isEmpty)
                .accessibilityIdentifier("hot-run")
            } footer: {
                Text("\(reloader.url), checked every \(Int(reloader.intervalSeconds)) s. Publish a version with tools/playground/publish_hot_reload.sh.")
            }
            Section {
                if loading && versions.isEmpty { ProgressView() }
                if let failure { Text(failure).foregroundColor(.secondary) }
                ForEach(versions) { version in
                    Button { run(version) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(version.version).foregroundColor(.primary)
                                if version.version == reloader.lastVersion {
                                    Text("last run").font(.caption).foregroundColor(.secondary)
                                }
                            }
                            if let notes = version.notes { Text(notes).font(.caption).foregroundColor(.secondary).lineLimit(2) }
                        }
                    }
                }
            } header: {
                Text("Versions")
            }
            Section {
                Button("Delete Hot Reloader", role: .destructive) {
                    hot.delete(reloader.id)
                    deleted()
                }
            }
        }
        .navigationTitle(reloader.name)
        .inlineTitle()
        .refreshable { await load() }
        .task { await load() }
        .onDisappear { poller?.cancel() }
        .runCover(isPresented: Binding(get: { running != nil }, set: { if !$0 { stopped() } }))
        .alert("New version available", isPresented: Binding(get: { newVersion != nil }, set: { if !$0 { newVersion = nil } })) {
            Button("Reload") { if let version = newVersion { newVersion = nil; reload(to: version) } }
            Button("Later", role: .cancel) {
                if let version = newVersion {
                    var current = reloader
                    current.pendingVersion = version.version
                    hot.update(current)
                }
                newVersion = nil
            }
        } message: {
            Text("\(reloader.name) \(newVersion?.version ?? "") was published\(newVersion?.notes.map { ": \($0)" } ?? ""). Reload now, or later.")
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            versions = try await HotReloadStore.fetchVersions(reloader.url)
            failure = nil
        } catch {
            failure = "\(error)"
        }
    }

    private func run(_ version: HotVersion) {
        Task { @MainActor in
            do {
                _ = try await PlaygroundHost.service?.runReactor(url: version.url, project: "hot-\(reloader.id)", environment: "")
                running = version
                announced = Set(versions.map(\.version))
                var updated = reloader
                updated.lastVersion = version.version
                updated.pendingVersion = nil
                hot.update(updated)
                startPolling()
            } catch {
                failure = "\(error)"
            }
        }
    }

    private func reload(to version: HotVersion) {
        PlaygroundHost.service?.stop()
        running = nil
        run(version)
    }

    private func stopped() {
        poller?.cancel()
        running = nil
    }

    private func startPolling() {
        poller?.cancel()
        let interval = max(2, reloader.intervalSeconds)
        let address = reloader.url
        poller = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, running != nil,
                      let fresh = try? await HotReloadStore.fetchVersions(address), let newest = fresh.first else { continue }
                versions = fresh
                if newest.version != running?.version, !announced.contains(newest.version), newVersion == nil {
                    announced.insert(newest.version)
                    newVersion = newest
                }
            }
        }
    }
}
