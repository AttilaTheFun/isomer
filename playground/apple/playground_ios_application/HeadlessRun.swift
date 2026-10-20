// The agent's run: the build runs OFFSCREEN, in a window behind the app's
// own, so the user keeps the chat (and can play their own copy full screen)
// while the agent runs, screenshots and reads the logs of its version. The
// window is the size of the screen, so layouts match what a full-screen run
// would show; `drawHierarchy` renders it even though the main window covers it.

import SwiftUI
import IsomerTree
import IsomerSwiftUI
import IsomerWasmView
#if os(iOS)
import UIKit
#endif

@MainActor
final class HeadlessRun {
    static let shared = HeadlessRun()

    #if os(iOS)
    private var window: UIWindow?
    #endif
    private(set) var projectID: String?
    /// The run's engine: created here, injected into the view, shut down
    /// here (graceful with a deadline, then forced).
    private var model: WasmViewModel?

    var isRunning: Bool {
        #if os(iOS)
        return window != nil
        #else
        return false
        #endif
    }

    /// Starts (or restarts) the agent's run over `wasm`. Reports status and
    /// logs to `RunMonitor.shared`, which `beginRun` has just reset.
    func start(wasm: Data, projectID: String, projects: ProjectStore) {
        forceStop()
        self.projectID = projectID
        MemoryFootprint.log("before run")
        #if os(iOS)
        let model = WasmViewModel.playground()
        self.model = model
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            RunMonitor.shared.record(status: "Load failed: no window scene")
            return
        }
        let root = ServicedWasmView(wasm: wasm, label: "run", projectID: projectID, monitored: true, model: model)
            .environmentObject(projects)
        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = .systemBackground
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        // Behind the app's window: rendered, never seen, never receives touches.
        window.windowLevel = UIWindow.Level.normal - 1
        window.isUserInteractionEnabled = false
        window.isHidden = false
        self.window = window
        RunMonitor.shared.runStarted()
        #else
        RunMonitor.shared.record(status: "Load failed: headless runs need iOS")
        #endif
    }

    /// Graceful shutdown (view tasks unwind), forced after `timeout`, then
    /// the window goes away. Returns how it ended, for the agent's transcript.
    func stop(timeout: TimeInterval = 1) async -> WasmFeatureRuntime.ShutdownOutcome {
        var outcome = WasmFeatureRuntime.ShutdownOutcome.graceful
        if let model {
            MemoryFootprint.log("before shutdown")
            outcome = await model.shutdown(timeout: timeout)
        }
        forceStop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MemoryFootprint.log("after release") }
        return outcome
    }

    /// Immediate teardown: releases the window and the engine now.
    func forceStop() {
        model?.forceShutdown()
        model = nil
        #if os(iOS)
        guard let window else { return }
        weak var controller = window.rootViewController
        weak var deadWindow = window
        window.isHidden = true
        window.rootViewController = nil
        self.window = nil
        RunMonitor.shared.runEnded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NSLog("[playground] headless teardown: window %@, controller %@",
                  deadWindow == nil ? "released" : "ALIVE", controller == nil ? "released" : "ALIVE")
        }
        #endif
        projectID = nil
    }

    // MARK: Driving the run (the agent's ui_tree / tap / type / submit / swipe)
    //
    // The run is a live WasmView: the guest ships its tree to the host and
    // the host answers with events on node ids — the same channel a real
    // finger uses. So the agent drives the app semantically: it reads the
    // tree (kinds, text, accessibility labels, which nodes take a tap, an
    // edit, a submit, a drag) and sends the event the renderer would send.
    // Continuous native gestures (scrolling a ScrollView) are the gap; a
    // guest DragGesture is driven by synthesizing its changed/ended stream.

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
            // Every other wire param (colors, fonts, frames…) for debugging a
            // rendering question; the labels above are the ones agents target.
            let shown: Set<String> = ["a11yLabel", "a11yId", "submit"]
            let rest = n.params.filter { !shown.contains($0.key ?? "") }.map { "\($0.key ?? "?")=\(($0.value ?? "").prefix(24))" }
            if !rest.isEmpty { line += " {" + rest.joined(separator: " ") + "}" }
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

    /// Taps the node (a Button, row, link, toggle…) — the nearest tap
    /// handler on it, inside it, or above it.
    func tap(_ target: String) -> String {
        guard let model, let (node, path) = find(target) else { return "error: no node matching \(target) (call ui_tree)" }
        guard let id = nearest(node, path: path, key: { $0.flat.tap }) else { return "error: nothing tappable at \(target) (no Button/row/link on, inside or above it)" }
        model.send(id: id, value: "")
        return "tapped \(path)"
    }

    /// Replaces a text field's contents (the edit handler on/inside the node).
    func type(_ target: String, text: String) -> String {
        guard let model, let (node, path) = find(target) else { return "error: no node matching \(target)" }
        guard let id = nearest(node, path: path, key: { $0.flat.edit }) else { return "error: no text field at \(target)" }
        model.send(id: id, value: text)
        return "typed into \(path)"
    }

    /// Fires a text field's onSubmit (Return).
    func submit(_ target: String) -> String {
        guard let model, let (node, path) = find(target) else { return "error: no node matching \(target)" }
        guard let id = nearest(node, path: path, key: { n in n.flat.params.first(where: { $0.key == "submit" })?.value }) else { return "error: nothing to submit at \(target) (no onSubmit)" }
        model.send(id: id, value: "")
        return "submitted \(path)"
    }

    /// A finite swipe on a guest DragGesture: the translation grows over
    /// `steps` onChanged reports, then onEnded lands at (dx, dy).
    func swipe(_ target: String, dx: Double, dy: Double, steps: Int = 8) async -> String {
        guard let model, let (node, path) = find(target) else { return "error: no node matching \(target)" }
        guard let id = nearest(node, path: path, key: { $0.flat.drag }) else {
            return "error: no DragGesture at \(target). Swipes drive guest DragGestures only; a ScrollView scrolls natively and cannot be swiped here."
        }
        let steps = max(1, min(steps, 60))
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            model.send(id: id, value: "changed:\(dx * t),\(dy * t)")
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        model.send(id: id, value: "ended:\(dx),\(dy)")
        return "swiped \(path) by (\(Int(dx)), \(Int(dy)))"
    }

    private func param(_ n: IsoFlat_Node, _ key: String) -> String? {
        for kv in n.params where kv.key == key { return kv.value }
        return nil
    }

    /// A target is a tree path ("0.2.1") or a label: an accessibility
    /// label/identifier, a text, or a placeholder (case-insensitive,
    /// whole then prefix match).
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
            let candidates = [param(n, "a11yLabel"), param(n, "a11yId"), n.v, n.placeholder].compactMap { $0 }
            for c in candidates {
                if exact == nil, c.caseInsensitiveCompare(wanted) == .orderedSame { exact = (node, path) }
                if prefix == nil, c.lowercased().hasPrefix(wanted.lowercased()) { prefix = (node, path) }
            }
            for (index, child) in node.children.enumerated() { walk(child, path: path + "." + String(index)) }
        }
        walk(root, path: "0")
        return exact ?? prefix
    }

    /// The handler id on the node, else the first inside it, else the
    /// nearest ancestor's (a Button's label is a child of the tap node).
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

    #if os(iOS)
    /// A JPEG of the offscreen run, downscaled for the model.
    func screenshot(maxWidth: CGFloat = 780) -> Data? {
        guard let window else { return nil }
        window.layoutIfNeeded()
        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(UIScreen.main.scale, maxWidth / max(1, bounds.width))
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        return image.jpegData(compressionQuality: 0.72)
    }
    #endif
}
