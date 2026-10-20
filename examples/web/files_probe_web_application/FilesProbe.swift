// The web's app files, checked from the app's side: on every launch the
// probe finds its directories where an iOS app's are, counts its launches in
// Documents, writes into Application Support, Caches and the temporary
// directory, lists, renames and removes, and shows one line per check ("ok
// …" or "FAIL …"). Loaded again, it finds what the last launch left under
// its home and nothing in /tmp. tools/testing/run_files_check.js drives it in
// headless Chrome across reloads (see BUILD.bazel).

import Foundation
import SwiftUI

@main
struct FilesProbeApp: App {
    var body: some Scene {
        WindowGroup { FilesProbeRoot() }
    }
}

struct FilesProbeRoot: View {
    @State private var lateWrites = 0

    var body: some View {
        NavigationStack {
            List {
                Section("Launch") {
                    ForEach(report, id: \.self) { Text($0) }
                }
                Section {
                    // The driver taps this and reloads at once: the write has
                    // to leave the page before the page does.
                    Button("Write late") {
                        lateWrites += 1
                        try? Data("late \(lateWrites)".utf8).write(to: probeFile("late.txt"))
                    }
                }
            }
            .navigationTitle("Files")
        }
    }
}

/// The checks, run once, on the first look at the report.
let report: [String] = FileChecks().run()

func probeFile(_ name: String) -> URL {
    URL.documentsDirectory.appending(path: name)
}

struct FileChecks {
    let files = FileManager.default
    var lines: [String] = []

    mutating func check(_ name: String, _ value: @autoclosure () throws -> String, _ expected: String) {
        do {
            let found = try value()
            lines.append(found == expected ? "ok \(name)" : "FAIL \(name): \(found), expected \(expected)")
        } catch {
            lines.append("FAIL \(name): \(error)")
        }
    }

    func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    func run() -> [String] {
        var checks = self

        // Where things are: an iOS container's layout.
        checks.check("home", NSHomeDirectory(), "/home/app")
        checks.check("documents", URL.documentsDirectory.path, "/home/app/Documents")
        checks.check("application support", URL.applicationSupportDirectory.path, "/home/app/Library/Application Support")
        checks.check("caches", URL.cachesDirectory.path, "/home/app/Library/Caches")
        checks.check("temporary", files.temporaryDirectory.path, "/tmp")
        checks.check("bundle identifier", Bundle.main.bundleIdentifier ?? "none", ProcessInfo.processInfo.environment["ISOMER_BUNDLE_IDENTIFIER"] ?? "none")
        for directory in [URL.documentsDirectory, .applicationSupportDirectory, .cachesDirectory] {
            checks.check("\(directory.lastPathComponent) exists", "\((try? files.contentsOfDirectory(atPath: directory.path)) != nil)", "true")
        }

        // The launch count, kept in Documents.
        let counter = probeFile("launches.txt")
        let launch = ((try? read(counter)).flatMap { Int($0) } ?? 0) + 1
        checks.lines.insert("launch \(launch)", at: 0)
        checks.check("write the count", try { try write("\(launch)", to: counter); return try read(counter) }(), "\(launch)")
        checks.check("count's size", try { String(describing: try files.attributesOfItem(atPath: counter.path)[.size] ?? "none") }(), "\("\(launch)".utf8.count)")

        // Application Support and Caches keep what the last launch wrote.
        for (name, directory) in [("support", URL.applicationSupportDirectory), ("cache", URL.cachesDirectory)] {
            let file = directory.appending(path: "\(name).txt")
            if launch > 1 {
                checks.check("\(name) kept", (try? read(file)) ?? "missing", "\(launch - 1)")
            }
            checks.check("\(name) written", try { try write("\(launch)", to: file); return try read(file) }(), "\(launch)")
        }

        // The temporary directory starts empty every launch.
        let scratch = files.temporaryDirectory.appending(path: "probe.txt")
        checks.check("temporary fresh", "\(files.fileExists(atPath: scratch.path))", "false")
        checks.check("temporary written", try { try write("scratch", to: scratch); return try read(scratch) }(), "scratch")

        // A late write (the button), from the launch before.
        if launch > 1, files.fileExists(atPath: probeFile("late.txt").path) {
            checks.lines.append("late write kept: \((try? read(probeFile("late.txt"))) ?? "unreadable")")
        }

        // A directory listed, with one file removed and one renamed.
        let notes = probeFile("notes")
        if launch > 1 {
            checks.check("notes kept", try { try files.contentsOfDirectory(atPath: notes.path).sorted().joined(separator: ",") }(), "a.txt,b.txt")
        }
        checks.check("notes made", try {
            try files.createDirectory(at: notes, withIntermediateDirectories: true)
            for name in ["a.txt", "c.txt", "moving.txt"] { try write(name, to: notes.appending(path: name)) }
            try files.removeItem(at: notes.appending(path: "c.txt"))
            if files.fileExists(atPath: notes.appending(path: "b.txt").path) {
                try files.removeItem(at: notes.appending(path: "b.txt"))
            }
            try files.moveItem(at: notes.appending(path: "moving.txt"), to: notes.appending(path: "b.txt"))
            return try files.contentsOfDirectory(atPath: notes.path).sorted().joined(separator: ",")
        }(), "a.txt,b.txt")
        checks.check("renamed", (try? read(notes.appending(path: "b.txt"))) ?? "missing", "moving.txt")

        // A tree removed whole (FileManager walks it with fts).
        let tree = probeFile("tree")
        checks.check("tree removed", try {
            try files.createDirectory(at: tree.appending(path: "deeper/deepest"), withIntermediateDirectories: true)
            try write("leaf", to: tree.appending(path: "deeper/leaf.txt"))
            try write("leaf", to: tree.appending(path: "deeper/deepest/leaf.txt"))
            try files.removeItem(at: tree)
            return "\(files.fileExists(atPath: tree.path))"
        }(), "false")

        // A log appended through a FileHandle: one line per launch.
        let log = probeFile("log.txt")
        checks.check("log appended", try {
            if !files.fileExists(atPath: log.path) { try write("", to: log) }
            let handle = try FileHandle(forWritingTo: log)
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data("launch \(launch)\n".utf8))
            try handle.close()
            return "\(try read(log).split(separator: "\n").count)"
        }(), "\(launch)")

        // A SQLite database in Application Support (SQLiteProbe.swift).
        checks.checkSQLite(launch: launch)

        // Outside the container nothing can be written.
        checks.check("root refused", "\((try? write("no", to: URL(filePath: "/outside.txt"))) == nil)", "true")

        for line in checks.lines { print("[files] \(line)") }
        return checks.lines
    }
}
