// What the agent can see of its running build: the run's load status and
// the guest's log lines. The agent's offscreen run (`HeadlessRun`) feeds
// them in; the `screenshot`, `logs` and `close_run` tools read from here.

import SwiftUI
#if os(iOS)
import UIKit
#endif

@MainActor
final class RunMonitor: ObservableObject {
    static let shared = RunMonitor()

    /// The latest WasmView status ("Loaded run", "Load failed: …").
    @Published private(set) var status = ""
    /// True while the agent's run is up.
    @Published private(set) var isPresented = false
    /// Recent runtime + guest log lines (newest last), capped.
    private(set) var lines: [String] = []

    /// The presenting run appeared. (Its WasmView may already have reported
    /// "Loaded" — a child's callbacks precede the parent's onAppear — so this
    /// does not reset anything; `beginRun` does, before the run is requested.)
    func runStarted() {
        isPresented = true
    }

    func runEnded() {
        isPresented = false
        status = ""
    }

    /// Called before a new run is requested: forget the previous run's
    /// status and log so the wait sees only this run's.
    func beginRun() {
        status = ""
        lines.removeAll()
    }

    func record(status: String) {
        self.status = status
        append("[status] \(status)")
    }

    func append(_ line: String) {
        lines.append(line)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    }

    var isLoaded: Bool { status.hasPrefix("Loaded") }
    var loadFailed: Bool { status.hasPrefix("Load failed") }

    /// The last `limit` log lines as one string (or a note when empty).
    func recentLog(limit: Int = 120) -> String {
        let tail = lines.suffix(limit)
        return tail.isEmpty ? "(no log output yet)" : tail.joined(separator: "\n")
    }

    /// Waits for the presented run to finish loading (a fresh wasm instance
    /// plus its first frames). Returns false on a load failure or timeout.
    func waitUntilLoaded(timeout: Double = 90) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if loadFailed { return false }
            if isLoaded {
                // The first frames land shortly after "Loaded" (network-backed
                // content a little later); give them a moment.
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                return true
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }

}

extension Notification.Name {
    /// Close the presented full-screen run (deep-link launches).
    static let playgroundStopRun = Notification.Name("playground.stopRun")
}
