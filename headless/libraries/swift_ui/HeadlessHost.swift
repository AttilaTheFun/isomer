// The headless host (headless/libraries/swift_ui): an app's SwiftUI run on
// the building machine (macOS, or Linux in a container) with nothing drawn,
// its UI read and driven through the runtime. `App.main()` runs `HeadlessApp`
// (`iso_process_host_run`), which speaks newline-delimited JSON on standard
// input and output, a command a line and an answer a line:
//
//   {"cmd": "ls"}                                   the screen as it is
//   {"cmd": "tap", "target": "Send"}                a button, by its accessibility
//                                                   identifier, label or text
//   {"cmd": "type", "target": "Title", "text": "Hi"} a text field's text
//   {"cmd": "set", "target": "Wi-Fi", "value": "0"} a control's value (a toggle's
//                                                   "1"/"0", a picker's index)
//   {"cmd": "back"}                                 the system's back
//   {"cmd": "dismiss"}                              the topmost presentation
//   {"cmd": "wait", "text": "Taps: 1", "timeout": 5} until the text shows
//   {"cmd": "quit"}
//
// Each answer is `{"ok": true|false, "error": …, "screen": {…}}`, the screen
// once the UI has settled after the command: what the flat tree a host
// receives shows (texts; buttons, fields and controls with their roles,
// labels, identifiers and values; what is presented), never pixels. The
// tests' client is IsomerHeadless (headless/isomer_headless).

#if !canImport(WASILibc)

internal import IsomerSwiftUI
internal import SwiftUI
import FlatBuffers
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The services half with nothing to draw: text measured as a fixed-width
/// estimate, every image ready, frames asked for remembered.
final class HeadlessHostBridge: HostBridge {
    func measureText(_ text: String, fontSize: Double, weight: Int, wrapWidth: Double?) -> CGSize {
        let width = fontSize * 0.55 * Double(text.count)
        if let wrapWidth, wrapWidth > 0, width > wrapWidth {
            let lines = (width / wrapWidth).rounded(.up)
            return CGSize(width: wrapWidth, height: fontSize * 1.3 * lines)
        }
        return CGSize(width: width, height: fontSize * 1.3)
    }

    func imageInfo(_ source: String, isRemote: Bool) -> ImageStatus { .ready(CGSize(width: 1, height: 1)) }
    func beginFrame(width: Double, height: Double) {}
    func fillRect(_ rect: CGRect, cornerRadius: Double, color: HostColor) {}
    func strokeRect(_ rect: CGRect, cornerRadius: Double, lineWidth: Double, color: HostColor) {}
    func fillGradient(_ rect: CGRect, cornerRadius: Double, gradientJSON: String) {}
    func drawShadow(_ rect: CGRect, cornerRadius: Double, color: HostColor, radius: Double, x: Double, y: Double) {}
    func drawText(_ text: String, in rect: CGRect, fontSize: Double, weight: Int, color: HostColor) {}
    func drawImage(_ source: String, isRemote: Bool, in dest: CGRect, clip: CGRect, cornerRadius: Double, opacity: Double) {}
    func pushClip(_ rect: CGRect, cornerRadius: Double) {}
    func popClip() {}
    func syncHostViews(_ viewsJSON: String) {}
    func endFrame() {}
    func beginTextInput(_ text: String, in rect: CGRect, fontSize: Double) {}
    func endTextInput() {}
    func scheduleRender() { HeadlessApp.needsFrame = true }
    func log(_ message: String) { HeadlessApp.logLine("[iso] \(message)") }
    func openURL(_ url: String) { HeadlessApp.openedURLs.append(url) }
    func now() -> Double { Date().timeIntervalSince1970 }
}

/// The tree a host would draw, kept.
final class HeadlessRenderer: TreeRenderer {
    let supportedModes: Set<IntegrationMode> = [.embedded, .app]
    private(set) var tree: RenderNode?

    @MainActor
    func render(tree: RenderNode) {
        self.tree = tree
    }
}

/// One frame as a host sees it: the flat tree and its handlers.
@MainActor
struct HeadlessFrame {
    struct Element {
        var role: String
        var label: String
        var id: String?
        var value: String?
        /// The handler a tap or an edit goes to.
        var handler: String?
    }

    var texts: [String] = []
    var elements: [Element] = []
    var presented: [(style: String, title: String, message: String, dismiss: String?)] = []

    init(_ root: IsoFlat_Node) {
        walk(root, around: [])
    }

    private static func params(_ node: IsoFlat_Node) -> [String: String] {
        var result: [String: String] = [:]
        for kv in node.params { result[kv.key] = kv.value }
        return result
    }

    private static func textsUnder(_ node: IsoFlat_Node) -> [String] {
        var found: [String] = []
        func visit(_ node: IsoFlat_Node) {
            if params(node)["a11yHidden"] == "1" { return }
            if node.kind == .text, let text = node.v, !text.isEmpty { found.append(text) }
            for child in node.ch { visit(child) }
        }
        visit(node)
        return found
    }

    /// `around`: the texts of the node's parent, a control's label when it
    /// has none of its own (a Toggle's label stands beside its switch).
    private mutating func walk(_ node: IsoFlat_Node, around: [String]) {
        let p = Self.params(node)
        if p["a11yHidden"] == "1" { return }
        let id = p["a11yId"]
        switch node.kind {
        case .text:
            if let text = node.v, !text.isEmpty { texts.append(text) }
        case .textfield:
            elements.append(Element(role: "textField", label: p["a11yLabel"] ?? node.placeholder ?? "", id: id,
                                    value: node.v ?? "", handler: node.edit ?? node.id.map { "\($0).text" }))
        case .slider:
            elements.append(Element(role: "slider", label: p["a11yLabel"] ?? p["title"] ?? "", id: id,
                                    value: node.num.map { String($0) }, handler: node.edit))
        case .presentation:
            let style: String
            switch node.style {
            case .alert: style = "alert"
            case .popover: style = "popover"
            default: style = "sheet"
            }
            presented.append((style, node.title ?? "", node.message ?? "", node.dismiss))
        case .hostview:
            let kind = node.view ?? "view"
            if ["toggle", "picker", "segmented", "stepper", "datepicker", "colorpicker"].contains(kind) {
                var label = p["a11yLabel"] ?? p["title"] ?? Self.textsUnder(node).joined(separator: " ")
                if label.isEmpty { label = around.joined(separator: " ") }
                elements.append(Element(role: kind, label: label, id: id, value: node.v, handler: node.edit))
            }
        default:
            break
        }
        if let tap = node.tap {
            let label = p["a11yLabel"] ?? Self.textsUnder(node).joined(separator: " ")
            elements.append(Element(role: "button", label: label, id: id, value: p["a11yValue"], handler: tap))
        }
        let texts = Self.textsUnder(node)
        for child in node.ch { walk(child, around: texts) }
    }

    /// The element a target names: its accessibility identifier, then its
    /// label exactly, then the last (innermost) whose label holds it.
    func element(_ target: String, roles: Set<String>? = nil) -> Element? {
        let candidates = elements.filter { roles == nil || roles!.contains($0.role) }
        return candidates.first { $0.id == target }
            ?? candidates.last { $0.label == target }
            ?? candidates.last { $0.label.contains(target) }
    }

    var json: [String: Any] {
        [
            "texts": texts,
            "elements": elements.map { element -> [String: Any] in
                var entry: [String: Any] = ["role": element.role, "label": element.label]
                if let id = element.id { entry["id"] = id }
                if let value = element.value { entry["value"] = value }
                return entry
            },
            "presented": presented.map { ["style": $0.style, "title": $0.title, "message": $0.message] },
        ]
    }
}

/// Not Apple's, so not public: `App.main()` calls it (`iso_process_host_run`, below).
enum HeadlessApp {
    nonisolated(unsafe) static var needsFrame = true
    nonisolated(unsafe) static var openedURLs: [String] = []
    nonisolated(unsafe) static let renderer = HeadlessRenderer()
    nonisolated(unsafe) static var encoder = FlatTreeEncoder()

    static func logLine(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Runs the installed app headless: commands from standard input, one at
    /// a time, answers on standard output; returns at `quit` or the input's end.
    @MainActor
    static func run() {
        let environment = ProcessInfo.processInfo.environment
        if environment["ISO_DARK"] != nil {
            Runtime.shared.setSystemColorScheme(dark: true)
        }
        Renderer.bind(renderer)
        let width = Double(environment["ISO_HEADLESS_WIDTH"] ?? "") ?? 390
        let height = Double(environment["ISO_HEADLESS_HEIGHT"] ?? "") ?? 844
        Runtime.shared.start(host: HeadlessHostBridge(), width: width, height: height)

        // The commands are read on a thread of their own and run on the main
        // actor one at a time, so the app's tasks run between them.
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            while let line = readLine() {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                let finished = DispatchSemaphore(value: 0)
                var quit = false
                Task { @MainActor in
                    quit = await handle(line)
                    finished.signal()
                }
                finished.wait()
                if quit { break }
            }
            done.signal()
        }
        // The main queue (and with it the main actor) runs on the main thread,
        // whose stack a deep view tree needs (dispatchMain would hand it to a
        // worker thread's 512 KB), until the reader ends.
        Thread.detachNewThread {
            done.wait()
            exit(0)
        }
        while true {
            _ = RunLoop.main.run(mode: .default, before: .distantFuture)
        }
    }

    /// The frame as it stands, encoded as a host receives it, its handlers
    /// installed where the runtime looks them up.
    @MainActor
    static func frame() -> HeadlessFrame? {
        guard let tree = renderer.tree else { return nil }
        encoder = FlatTreeEncoder()
        var buffer = ByteBuffer(bytes: encoder.encode(root: tree))
        let root: IsoFlat_Node = getRoot(byteBuffer: &buffer)
        Runtime.shared.installTreeHandlers(encoder.handlers)
        return HeadlessFrame(root)
    }

    /// Frames until the screen holds still (three in a row the same, or the
    /// timeout): the app's tasks and animations run meanwhile.
    @MainActor
    static func settle(timeout: Double = 3) async -> HeadlessFrame? {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        var still = 0
        var current = frame()
        while Date() < deadline {
            if needsFrame {
                needsFrame = false
                Runtime.shared.renderFrame()
            }
            current = frame()
            let text = current.map { serialize($0.json) } ?? ""
            if text == last {
                still += 1
                if still >= 3 { break }
            } else {
                still = 0
                last = text
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return current
    }

    /// Runs one command and writes its answer; true when it was `quit`.
    @MainActor
    static func handle(_ line: String) async -> Bool {
        var error: String?
        var quit = false
        let command = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
        let target = command["target"] as? String ?? ""
        let before = await settle()
        switch command["cmd"] as? String {
        case "ls":
            break
        case "tap":
            if let handler = before?.element(target, roles: ["button"])?.handler {
                Runtime.shared.hostViewEvent(id: handler, value: "")
            } else {
                error = "no button \(target)"
            }
        case "type":
            if let handler = before?.element(target, roles: ["textField"])?.handler {
                Runtime.shared.hostViewEvent(id: handler, value: command["text"] as? String ?? "")
            } else {
                error = "no text field \(target)"
            }
        case "set":
            if let handler = before?.element(target)?.handler {
                Runtime.shared.hostViewEvent(id: handler, value: command["value"] as? String ?? "")
            } else {
                error = "no control \(target)"
            }
        case "back":
            if !Runtime.shared.handleBackButton() { error = "nothing to go back from" }
        case "dismiss":
            if let dismiss = before?.presented.last?.dismiss {
                Runtime.shared.hostViewEvent(id: dismiss, value: "")
            } else {
                error = "nothing presented"
            }
        case "wait":
            let text = command["text"] as? String ?? ""
            let deadline = Date().addingTimeInterval(command["timeout"] as? Double ?? 5)
            var shown = false
            while Date() < deadline {
                if let frame = await settle(timeout: 0.5), frame.texts.contains(where: { $0.contains(text) })
                    || frame.elements.contains(where: { $0.label.contains(text) || ($0.value ?? "").contains(text) }) {
                    shown = true
                    break
                }
            }
            if !shown { error = "\(text) didn't show" }
        case "quit":
            quit = true
        default:
            error = "unknown command: \(line)"
        }
        needsFrame = true
        var answer: [String: Any] = ["ok": error == nil]
        if let error { answer["error"] = error }
        if let frame = await settle() { answer["screen"] = frame.json }
        print(serialize(answer))
        fflush(stdout)
        return quit
    }

    static func serialize(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

#endif

/// The headless host's process (shared/swift_ui_core/App.swift): nothing drawn, the UI read and driven over standard input and output until `quit`.
@_silgen_name("iso_process_host_run")
func _isoHeadlessProcessHostRun() {
    MainActor.assumeIsolated { HeadlessApp.run() }
}
