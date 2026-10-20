// Crash attribution for runs. A run (the agent's offscreen one, or the user's
// full-screen one) leaves a marker file while it is up, and streams the
// guest's log into a file beside it. If the process dies with a marker
// present — a host crash, a stack blowout in the engine, a jetsam kill —
// the next launch turns the marker into a crash record for that project:
// which run it was (agent or user), the build it ran, the log's tail, and,
// when MetricKit delivers one, the crash diagnostic (signal, exception, call
// stacks). Records feed the project's transcript (the agent sees it next
// turn) and the `crash_report` tool (the user says "it crashed"; the agent
// asks).

import Foundation
#if canImport(MetricKit) && os(iOS)
import MetricKit
#endif

struct CrashRecord: Codable, Identifiable {
    enum Owner: String, Codable { case agent, user }
    var id: String = UUID().uuidString
    var projectID: String
    var owner: Owner
    var startedAt: Date
    var detectedAt: Date = Date()
    /// Where the run's sources + wasm were copied (may be gone: temp dir).
    var snapshotDir: String?
    var logTail: [String]
    /// MetricKit's diagnostic, once delivered (JSON call-stack tree etc.).
    var diagnostic: String?

    /// The record as the agent reads it.
    var report: String {
        let formatter = ISO8601DateFormatter()
        var out = "Crash detected \(formatter.string(from: detectedAt)): the Playground died while "
        out += owner == .agent ? "your run (started \(formatter.string(from: startedAt))) was up." : "the user was playing the build full screen (started \(formatter.string(from: startedAt)))."
        out += "\n\nLast log lines of that run:\n" + (logTail.isEmpty ? "(none)" : logTail.joined(separator: "\n"))
        if let diagnostic { out += "\n\nCrash diagnostic:\n" + diagnostic }
        else { out += "\n\n(No crash diagnostic from the OS yet — usually a stack overflow, out-of-memory kill or a trap in the runtime; the log above is the best clue.)" }
        return out
    }
}

@MainActor
final class CrashRecorder: NSObject {
    static let shared = CrashRecorder()

    private struct Marker: Codable {
        var projectID: String
        var owner: CrashRecord.Owner
        var startedAt: Date
        var snapshotDir: String?
    }

    private var markersDir: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("active_runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var handles: [String: FileHandle] = [:]
    private var lineCounts: [String: Int] = [:]
    /// Crash records found at this launch, newest last (also saved per project).
    private(set) var recordsThisLaunch: [CrashRecord] = []
    private weak var projects: ProjectStore?

    // MARK: Run markers

    /// Called when a run's view appears. Returns the run's marker id.
    func runStarted(projectID: String, owner: CrashRecord.Owner, snapshotDir: URL?) -> String {
        let id = UUID().uuidString
        let marker = Marker(projectID: projectID, owner: owner, startedAt: Date(), snapshotDir: snapshotDir?.path)
        if let data = try? JSONEncoder().encode(marker) {
            try? data.write(to: markersDir.appendingPathComponent(id + ".json"), options: .atomic)
        }
        let logURL = markersDir.appendingPathComponent(id + ".log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        handles[id] = try? FileHandle(forWritingTo: logURL)
        return id
    }

    /// The guest's log line, flushed straight to disk so a crash keeps it.
    func append(_ line: String, run id: String) {
        guard let handle = handles[id] else { return }
        handle.write(Data((line + "\n").utf8))
        lineCounts[id, default: 0] += 1
    }

    /// Called when the run's view goes away: the run ended cleanly.
    func runEnded(_ id: String) {
        try? handles.removeValue(forKey: id)?.close()
        lineCounts[id] = nil
        try? FileManager.default.removeItem(at: markersDir.appendingPathComponent(id + ".json"))
        try? FileManager.default.removeItem(at: markersDir.appendingPathComponent(id + ".log"))
    }

    // MARK: Launch-time collection

    /// Turns leftover markers (the previous process died with runs up) into
    /// crash records: saved under the project, and returned so the caller can
    /// note them in the transcript. Also subscribes to MetricKit for the
    /// OS's diagnostic, which arrives shortly after launch.
    func collect(projects: ProjectStore) -> [CrashRecord] {
        self.projects = projects
        var records: [CrashRecord] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: markersDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let marker = try? JSONDecoder().decode(Marker.self, from: data) else { continue }
            let logURL = file.deletingPathExtension().appendingPathExtension("log")
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let tail = Array(log.split(separator: "\n").map(String.init).suffix(40))
            let record = CrashRecord(projectID: marker.projectID, owner: marker.owner, startedAt: marker.startedAt,
                                     snapshotDir: marker.snapshotDir, logTail: tail)
            save(record)
            records.append(record)
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: logURL)
        }
        records.sort { $0.startedAt < $1.startedAt }
        recordsThisLaunch = records
        #if canImport(MetricKit) && os(iOS)
        MXMetricManager.shared.add(self)
        #endif
        return records
    }

    private func crashesDir(_ projectID: String) -> URL? {
        guard let projects else { return nil }
        let url = projects.dir(projectID).appendingPathComponent("crashes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func save(_ record: CrashRecord) {
        guard let dir = crashesDir(record.projectID), let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: dir.appendingPathComponent(record.id + ".json"), options: .atomic)
    }

    /// Collects at launch and writes a transcript note into each crashed
    /// project (a "crash" tool row; sent to the model as a note). Called
    /// from the store's init, before any chat session loads its messages.
    func noteCrashes(in projects: ProjectStore) {
        for record in collect(projects: projects) {
            let who = record.owner == .agent ? "the agent's run" : "the user's full-screen run"
            let text = "The Playground crashed while \(who) of this project was up (\(record.logTail.count) log lines kept). Call crash_report for the details."
            NSLog("[playground] crash note for %@: %@", record.projectID, text)
            var messages = projects.loadMessages(record.projectID)
            messages.append(ChatMessage(role: .tool, text: text, toolName: "crash"))
            projects.saveMessages(messages, in: record.projectID)
        }
    }

    /// The project's crash records, oldest first.
    func records(for projectID: String) -> [CrashRecord] {
        guard let dir = crashesDir(projectID),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { try? JSONDecoder().decode(CrashRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.detectedAt < $1.detectedAt }
    }

    /// What the `crash_report` tool returns.
    func latestReport(for projectID: String) -> String {
        guard let record = records(for: projectID).last else {
            return "No crash recorded for this project. (A crash is the Playground itself dying while a run is up; a build that fails to load or traps shows in `logs` instead.)"
        }
        return record.report
    }

    // MARK: MetricKit

    #if canImport(MetricKit) && os(iOS)
    /// Attaches the OS's crash diagnostic to the most recent record found at
    /// this launch (diagnostics are delivered on the launch after the crash).
    private func attach(diagnostic: String) {
        guard var record = recordsThisLaunch.last, record.diagnostic == nil else { return }
        record.diagnostic = diagnostic
        recordsThisLaunch[recordsThisLaunch.count - 1] = record
        save(record)
    }
    #endif
}

#if canImport(MetricKit) && os(iOS)
extension CrashRecorder: MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var parts: [String] = []
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                var text = "exception type \(crash.exceptionType.map(String.init(describing:)) ?? "?"), code \(crash.exceptionCode.map(String.init(describing:)) ?? "?"), signal \(crash.signal.map(String.init(describing:)) ?? "?")"
                if let reason = crash.terminationReason { text += ", reason: \(reason)" }
                if let region = crash.virtualMemoryRegionInfo { text += "\n\(region)" }
                let stacks = String(decoding: crash.callStackTree.jsonRepresentation(), as: UTF8.self)
                text += "\nCall stacks (JSON, truncated):\n" + String(stacks.prefix(6000))
                parts.append(text)
            }
        }
        guard !parts.isEmpty else { return }
        let joined = parts.joined(separator: "\n\n")
        Task { @MainActor in CrashRecorder.shared.attach(diagnostic: joined) }
    }
}
#endif
