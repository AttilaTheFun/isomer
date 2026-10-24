// The running reactor on Apple platforms: one at a time, in a WasmView
// (the SwiftUI tree renderer, or Metal when Settings chose the GPU), the
// surface the shared run cover shows (PlaygroundSurfaces.run). Its guest has
// a home of its own (Application Support/runs/<name>) and the platform
// services the Playground's runs have always had. The agent's ui_tree, tap,
// type_text, submit and swipe drive it through the tree it ships, the
// channel a finger uses.

import Foundation
import SwiftUI
import ApplePlatformServices
import IsomerSwiftUI
import IsomerTree
import IsomerWasmView

@MainActor @Observable
final class AppleRun {
    static let shared = AppleRun()

    struct Current: Identifiable {
        let id = UUID()
        var wasm: Data
        var label: String
        /// Names the guest's home and its keychain namespace.
        var name: String
        /// KEY=VALUE variables the guest is given (WasmKitRuntime forwards
        /// the process's ISO_ ones when it instantiates).
        var environment: [String: String]
    }

    private(set) var current: Current?
    @ObservationIgnored private(set) var model: WasmViewModel?
    @ObservationIgnored private var log: [String] = []
    @ObservationIgnored private var setVariables: [String] = []

    func start(_ run: Current) {
        stop()
        for (key, value) in run.environment {
            setenv(key, value, 1)
            setVariables.append(key)
        }
        let model = WasmViewModel(runtime: { WasmRuntimeRegistry.make(for: $0) })
        let home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(run.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        model.guestHomeDirectory = home.path
        model.guestBundleIdentifier = "dev.isomer.playground.run." + run.name
        log = []
        model.onLog = { [weak self] line in
            NSLog("[playground] guest: %@", line)
            Task { @MainActor in self?.append(line) }
        }
        self.model = model
        current = run
    }

    func stop() {
        model?.forceShutdown()
        model = nil
        current = nil
        for key in setVariables { unsetenv(key) }
        setVariables = []
    }

    func append(_ line: String) {
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    var logs: String { log.isEmpty ? "(no log output yet)" : log.joined(separator: "\n") }

    // MARK: Driving the run (the agent's ui_tree / tap / type / submit / swipe)

    /// One line per node: `path kind[/view] "text" label=… id=… [tap edit submit drag]`.
    func treeDump(maxLines: Int = 400) -> String {
        guard let root = model?.tree else { return "(no tree yet — is the app running?)" }
        var lines: [String] = []
        func walk(_ node: PatchedNode, path: String, depth: Int) {
            let n = node.flat
            var line = String(repeating: "  ", count: depth) + path + " " + "\(n.kind)"
            if let view = n.view { line += "/" + view }
            if let v = n.v, !v.isEmpty { line += " \"" + String(v.prefix(60)).replacingOccurrences(of: "\n", with: " ") + "\"" }
            if let label = param(n, "a11yLabel") { line += " label=\"\(label)\"" }
            if let id = param(n, "a11yId") { line += " id=\"\(id)\"" }
            if let placeholder = n.placeholder, !placeholder.isEmpty { line += " placeholder=\"\(placeholder)\"" }
            var caps: [String] = []
            if n.tap != nil { caps.append("tap") }
            if n.edit != nil { caps.append("edit") }
            if param(n, "submit") != nil { caps.append("submit") }
            if n.drag != nil { caps.append("drag") }
            if !caps.isEmpty { line += " [" + caps.joined(separator: " ") + "]" }
            lines.append(line)
            for (index, child) in node.children.enumerated() {
                walk(child, path: path + "." + String(index), depth: depth + 1)
            }
        }
        walk(root, path: "0", depth: 0)
        if lines.count > maxLines {
            return lines.prefix(maxLines).joined(separator: "\n") + "\n… (\(lines.count - maxLines) more nodes; drive by label or narrow the app)"
        }
        return lines.joined(separator: "\n")
    }

    func tap(_ target: String) -> String {
        guard let model, let (node, path) = find(target) else { return "error: no node matching \(target) (call ui_tree)" }
        guard let id = nearest(node, path: path, key: { $0.flat.tap }) else { return "error: nothing tappable at \(target)" }
        model.send(id: id, value: "")
        return "tapped \(path)"
    }

    func type(_ target: String, text: String) -> String {
        guard let model, let (node, path) = find(target) else { return "error: no node matching \(target)" }
        guard let id = nearest(node, path: path, key: { $0.flat.edit }) else { return "error: no text field at \(target)" }
        model.send(id: id, value: text)
        return "typed into \(path)"
    }

    func submit(_ target: String) -> String {
        guard let model, let (node, path) = find(target) else { return "error: no node matching \(target)" }
        guard let id = nearest(node, path: path, key: { n in n.flat.params.first(where: { $0.key == "submit" })?.value }) else {
            return "error: nothing to submit at \(target) (no onSubmit)"
        }
        model.send(id: id, value: "")
        return "submitted \(path)"
    }

    func swipe(_ target: String, dx: Double, dy: Double, steps: Int = 8) async -> String {
        guard let model, let (node, path) = find(target) else { return "error: no node matching \(target)" }
        guard let id = nearest(node, path: path, key: { $0.flat.drag }) else {
            return "error: no DragGesture at \(target) (native scrolling cannot be swiped)"
        }
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            model.send(id: id, value: "changed:\(dx * t),\(dy * t)")
            try? await Task.sleep(for: .milliseconds(16))
        }
        model.send(id: id, value: "ended:\(dx),\(dy)")
        return "swiped \(path) by (\(Int(dx)), \(Int(dy)))"
    }

    private func param(_ n: IsoFlat_Node, _ key: String) -> String? {
        for kv in n.params where kv.key == key { return kv.value }
        return nil
    }

    /// A target is a tree path ("0.2.1") or a label: an accessibility
    /// label/identifier, a text, or a placeholder (whole, then prefix).
    private func find(_ target: String) -> (PatchedNode, String)? {
        guard let root = model?.tree else { return nil }
        let wanted = target.trimmingCharacters(in: .whitespaces)
        if wanted.allSatisfy({ $0.isNumber || $0 == "." }) {
            var node = root
            for part in wanted.split(separator: ".").dropFirst() {
                guard let index = Int(part), index < node.children.count else { return nil }
                node = node.children[index]
            }
            return (node, wanted)
        }
        var exact: (PatchedNode, String)?
        var prefix: (PatchedNode, String)?
        func walk(_ node: PatchedNode, path: String) {
            let n = node.flat
            for c in [param(n, "a11yLabel"), param(n, "a11yId"), n.v, n.placeholder].compactMap({ $0 }) {
                if exact == nil, c.caseInsensitiveCompare(wanted) == .orderedSame { exact = (node, path) }
                if prefix == nil, c.lowercased().hasPrefix(wanted.lowercased()) { prefix = (node, path) }
            }
            for (index, child) in node.children.enumerated() { walk(child, path: path + "." + String(index)) }
        }
        walk(root, path: "0")
        return exact ?? prefix
    }

    /// The handler on the node, else the first inside it, else the nearest
    /// ancestor's (a Button's label is a child of the tap node).
    private func nearest(_ node: PatchedNode, path: String, key: (PatchedNode) -> String?) -> String? {
        if let id = key(node) { return id }
        func below(_ n: PatchedNode) -> String? {
            for child in n.children { if let id = key(child) ?? below(child) { return id } }
            return nil
        }
        if let id = below(node) { return id }
        guard let root = model?.tree else { return nil }
        var chain: [PatchedNode] = [root]
        var current = root
        for part in path.split(separator: ".").dropFirst() {
            guard let index = Int(part), index < current.children.count else { break }
            current = current.children[index]
            chain.append(current)
        }
        for ancestor in chain.reversed().dropFirst() { if let id = key(ancestor) { return id } }
        return nil
    }
}

/// The run cover's surface: the current run in a WasmView, as an app's
/// root (inside the safe area); tells the cover when the run has stopped.
struct AppleRunSurface: View {
    let onStopped: () -> Void
    private var run = AppleRun.shared

    init(onStopped: @escaping () -> Void) { self.onStopped = onStopped }

    var body: some View {
        Group {
            if let current = run.current, let model = run.model {
                WasmView(
                    model: model,
                    provider: DataBundleProvider(wasm: current.wasm, label: current.label),
                    ffiModulePrefix: platformServicesFFIPrefix,
                    dependencies: applePlatformDependencies(
                        namespace: "playground." + current.name,
                        flags: ["promo_banner": true],
                        analytics: { NSLog("[playground] analytics %@", $0) }),
                    renderer: .swiftUI
                ) { status in
                    NSLog("[playground] run status: %@", status)
                    AppleRun.shared.append("[status] " + status)
                }
                .id(current.id)
            } else {
                Color.clear
            }
        }
        .onChange(of: run.current?.id) { id in
            if id == nil { onStopped() }
        }
    }
}

/// A provider over in-memory bytes: a build or a downloaded reactor, no updates.
struct DataBundleProvider: BundleProvider {
    let wasm: Data
    let label: String

    func initialBundle() -> WasmServiceBundle? {
        WasmServiceBundle(label: label, wasm: [UInt8](wasm))
    }

    func bundleUpdates() -> AsyncStream<WasmServiceBundle> {
        AsyncStream { $0.finish() }
    }
}
