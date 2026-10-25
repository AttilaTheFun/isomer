// Projects for the web and Android Playgrounds: files in the app's
// Application Support under playground/ (FileManager's; the web keeps them
// in IndexedDB), one directory per project. Templates are the same sample
// apps the iOS Playground seeds, compiled in (TemplateSources, generated
// from them). What the Playground kept before 0.31 in its host's storage is
// moved over once, the first time the new store is empty.

import Foundation
import Observation
import SwiftUI
import Isomer

struct WebProject: Identifiable, Equatable {
    var id: String
    var name: String
}

struct WebTemplate: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var asset: String?
    var subtitle: String

    static let blank = WebTemplate(name: "Blank", asset: nil, subtitle: "An empty App with one screen.")
    static let all: [WebTemplate] = [
        blank,
        WebTemplate(name: "Counter", asset: "Counter.swift", subtitle: "One button, one number."),
        WebTemplate(name: "2048", asset: "Game2048.swift", subtitle: "Swipe tiles; interactive drag."),
        WebTemplate(name: "Hacker News", asset: "HackerNews.swift", subtitle: "Top stories over the network service."),
        WebTemplate(name: "Meme Creator", asset: "MemeCreator.swift", subtitle: "Captions over a picked image."),
        WebTemplate(name: "Pokédex", asset: "Pokedex.swift", subtitle: "A list with remote artwork."),
        WebTemplate(name: "Date Planner", asset: "DatePlanner.swift", subtitle: "Events by day; a sheet to add one."),
        WebTemplate(name: "Map Explorer", asset: "MapExplorer.swift", subtitle: "A map with markers, a park and a route."),
        WebTemplate(name: "Floating Menu", asset: "FloatingMenu.swift", subtitle: "A menu over a floating button."),
        WebTemplate(name: "This website", asset: "Splash.swift", subtitle: "The front page you came from — edit it and Run."),
    ]

    static let blankSource = """
    import SwiftUI

    @main
    struct MyApp: App {
        var body: some Scene { WindowGroup { RootView() } }
    }

    struct RootView: View {
        var body: some View {
            VStack(spacing: 12) {
                Text("Hello, Isomer").font(.title)
                Text("Describe an app to the agent, or edit this file.").foregroundColor(.secondary)
            }
            .padding()
        }
    }
    """

    func source() -> String {
        guard let asset, let source = TemplateSources.byName[asset] else { return Self.blankSource }
        return source
    }
}

/// The Playground's files: Application Support/playground/<path>.
enum PlaygroundFiles {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("playground", isDirectory: true)
    }

    static func url(_ path: String) -> URL { root.appendingPathComponent(path, isDirectory: false) }

    static func read(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: url(path)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ path: String, _ contents: String) {
        write(path, Data(contents.utf8))
    }

    static func write(_ path: String, _ data: Data) {
        let target = url(path)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: target)
    }

    static func delete(_ path: String) {
        try? FileManager.default.removeItem(at: url(path))
    }

    /// The projects as the host kept them before 0.31 (`playground/...` in
    /// its old file service), written here once: when there is no index yet.
    static func moveLegacyFiles() {
        guard !FileManager.default.fileExists(atPath: url(indexPath).path),
              let host = PlaygroundHost.service,
              let json = parseJSON(host.legacyFiles()), case .object(let files) = json else { return }
        for (path, value) in files {
            guard path.hasPrefix("playground/"), let base64 = value.string,
                  let data = Data(base64Encoded: base64) else { continue }
            write(String(path.dropFirst("playground/".count)), data)
        }
    }

    static let indexPath = "projects.json"
}

@Observable
final class WebProjectStore {
    private(set) var projects: [WebProject] = []
    var selection: String?

    init() {
        PlaygroundFiles.moveLegacyFiles()
        load()
        refreshShippedTemplates()
        if projects.isEmpty {
            // Out of the box: one project per bundled sample.
            for template in WebTemplate.all where template.asset != nil {
                create(named: template.name, template: template, select: false)
            }
            selection = projects.first?.id
        }
        // `?template=<name>` (the splash's "Edit this page"): select that
        // project, creating it from the template when it is not there.
        if let wanted = PlaygroundHost.service?.requestedTemplate(), !wanted.isEmpty {
            if let existing = projects.first(where: { $0.name == wanted }) {
                select(existing.id)
            } else if let template = WebTemplate.all.first(where: { $0.name == wanted }) {
                create(named: template.name, template: template)
            }
        }
    }

    private func load() {
        guard let text = PlaygroundFiles.read(PlaygroundFiles.indexPath), let json = parseJSON(text) else { return }
        projects = (json["projects"].array ?? []).compactMap { entry in
            guard let id = entry["id"].string, let name = entry["name"].string else { return nil }
            return WebProject(id: id, name: name)
        }
        selection = json["selection"].string ?? projects.first?.id
    }

    /// A project whose App.swift is still a version of a template the
    /// Playground shipped (TemplateHistory: never edited) takes the template
    /// as it is now; one with any edit keeps its source.
    private func refreshShippedTemplates() {
        for project in projects {
            let source = self.source(project.id)
            guard let asset = TemplateHistory.template(of: source),
                  let current = TemplateSources.byName[asset], current != source else { continue }
            write(project.id, source: current)
        }
    }

    private func save() {
        let json = JSONValue.object([
            "projects": .array(projects.map { .object(["id": .string($0.id), "name": .string($0.name)]) }),
            "selection": selection.map { .string($0) } ?? .null,
        ])
        PlaygroundFiles.write(PlaygroundFiles.indexPath, json.encoded())
    }

    @discardableResult
    func create(named name: String, template: WebTemplate, select: Bool = true) -> WebProject {
        let project = WebProject(id: UUID().uuidString, name: name)
        projects.append(project)
        write(project.id, source: template.source())
        if select { selection = project.id }
        save()
        return project
    }

    func delete(_ id: String) {
        projects.removeAll { $0.id == id }
        PlaygroundFiles.delete(id)
        if selection == id { selection = projects.first?.id }
        save()
    }

    func select(_ id: String) {
        selection = id
        save()
    }

    func source(_ id: String) -> String {
        PlaygroundFiles.read("\(id)/App.swift") ?? ""
    }

    func write(_ id: String, source: String) {
        PlaygroundFiles.write("\(id)/App.swift", source)
    }

    func loadChat(_ id: String) -> [ChatMessage] {
        guard let text = PlaygroundFiles.read("\(id)/chat.json"), let json = parseJSON(text) else { return [] }
        return (json.array ?? []).compactMap(ChatMessage.init(json:))
    }

    func saveChat(_ messages: [ChatMessage], in id: String) {
        PlaygroundFiles.write("\(id)/chat.json", JSONValue.array(messages.map(\.json)).encoded())
    }
}


extension String {
    /// The skim Foundation has no CharacterSet trimming; whitespace + newlines.
    var trimmed: String {
        var scalars = Substring(self)
        while let first = scalars.first, first.isWhitespace || first.isNewline { scalars = scalars.dropFirst() }
        while let last = scalars.last, last.isWhitespace || last.isNewline { scalars = scalars.dropLast() }
        return String(scalars)
    }

    var withoutEllipsis: String { filter { $0 != "…" } }
}


/// Settings kept with the projects (`settings.json`; moved over with them).
enum WebSettings {
    static let defaultModel = "anthropic/claude-sonnet-5"
    static var model: String {
        get {
            guard let text = PlaygroundFiles.read("settings.json"), let json = parseJSON(text),
                  let model = json["model"].string, !model.isEmpty else { return defaultModel }
            return model
        }
        set {
            PlaygroundFiles.write("settings.json", JSONValue.object(["model": .string(newValue)]).encoded())
        }
    }
}
