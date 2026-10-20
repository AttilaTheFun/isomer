// The Playground's file model: a flat folder of .swift files under
// Documents/Playground, seeded with a sample on first run. Deliberately
// simple — create / rename by filename, delete, select, edit — the file
// browser the editor pane binds to.

import Foundation

struct PlaygroundFile: Identifiable, Hashable {
    var id: String { name }
    /// Filename with extension (e.g. "Counter.swift").
    var name: String
}

@MainActor
final class PlaygroundStore: ObservableObject {
    @Published private(set) var files: [PlaygroundFile] = []
    @Published var selection: String?

    let root: URL

    init() {
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Playground", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        reload()
        if files.isEmpty {
            create(named: "Counter.swift", contents: Self.sample)
        }
        if selection == nil { selection = files.first?.name }
    }

    func reload() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        files = names.filter { $0.hasSuffix(".swift") }.sorted().map(PlaygroundFile.init)
    }

    func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    func contents(of name: String) -> String {
        (try? String(contentsOf: url(name), encoding: .utf8)) ?? ""
    }

    func save(_ name: String, contents: String) {
        try? contents.write(to: url(name), atomically: true, encoding: .utf8)
    }

    @discardableResult
    func create(named rawName: String, contents: String = PlaygroundStore.newFileTemplate) -> String {
        var name = rawName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Untitled" }
        if !name.hasSuffix(".swift") { name += ".swift" }
        // De-duplicate: Untitled.swift, Untitled 2.swift, ...
        var candidate = name
        var counter = 2
        while FileManager.default.fileExists(atPath: url(candidate).path) {
            candidate = name.replacingOccurrences(
                of: ".swift", with: " \(counter).swift")
            counter += 1
        }
        save(candidate, contents: contents)
        reload()
        selection = candidate
        return candidate
    }

    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: url(name))
        reload()
        if selection == name { selection = files.first?.name }
    }

    /// Every file's current contents, for a whole-module compile.
    func allFiles() -> [URL] { files.map { url($0.name) } }

    nonisolated static let newFileTemplate = """
    import SwiftUI

    // Add views here — every .swift file compiles into the same module.
    """

    nonisolated static let sample = ProjectTemplate.blankSource
}
