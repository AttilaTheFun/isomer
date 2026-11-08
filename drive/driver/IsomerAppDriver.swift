// IsomerDriver: an Isomer app's screen read and used through its runtime, in
// any host: the headless one (headless/libraries/swift_ui) or one that draws
// (Android's, the web's, a desktop's), where it answers a driver over a
// connection the app opened (`dialOut`). shared/wire/headless.proto is the
// protocol:
//
//   ls                          the screen as it is
//   info                        what the app is (name, platform, renderer, size)
//   tap <target>                a button, by its accessibility identifier,
//                               label or text
//   type <target> <text>        a text field's text
//   set <target> <value>        a control's value (a toggle's "1"/"0", a
//                               picker's index)
//   select <target> <option>    a picker's or segmented control's option, by label
//   swipe <target> <direction>  a drag across a view that takes one (up, down,
//                               left, right)
//   back, dismiss               the system's back; the topmost presentation
//   wait <text> [timeout]       until the text shows
//   quit                        ends the call (and a headless app)
//
// Each answer carries the screen once the UI has settled after the command
// (texts; buttons, fields and controls with their roles, labels, identifiers,
// values and options; what is presented), never pixels.

import Foundation
import IsomerSwiftUI
import IsomerServing
import IsomerWire
import SwiftUI

/// One frame as a driver reads it: the flat tree and its handlers.
@MainActor
struct DriverScreen {
    struct Element {
        var role: String
        var label: String
        var id: String?
        var value: String?
        var options: [String] = []
        /// The handler a tap or an edit goes to.
        var handler: String?
    }

    var texts: [String] = []
    var elements: [Element] = []
    /// The views a swipe drags, by the texts in them: (texts, id, drag handler).
    var draggables: [(label: String, id: String?, handler: String)] = []
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
                let role = kind == "picker" && p["style"] == "segmented" ? "segmented" : kind
                elements.append(Element(role: role, label: label, id: id, value: node.v,
                                        options: node.options.compactMap { $0 }, handler: node.edit))
            }
        default:
            break
        }
        if let tap = node.tap {
            let label = p["a11yLabel"] ?? Self.textsUnder(node).joined(separator: " ")
            elements.append(Element(role: "button", label: label, id: id, value: p["a11yValue"], handler: tap))
        }
        if let drag = node.drag {
            draggables.append((p["a11yLabel"] ?? Self.textsUnder(node).joined(separator: " "), id, drag))
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

    /// The view a swipe drags: as `element`, among those that take a drag;
    /// with no target, the innermost one.
    func draggable(_ target: String) -> String? {
        if target.isEmpty { return draggables.last?.handler }
        return (draggables.first { $0.id == target }
            ?? draggables.last { $0.label == target }
            ?? draggables.last { $0.label.contains(target) })?.handler
    }

    var wire: Wire_Screen {
        var screen = Wire_Screen()
        screen.texts = texts
        screen.elements = elements.map { element in
            var entry = Wire_Element()
            entry.role = element.role
            entry.label = element.label
            if let id = element.id { entry.id = id }
            if let value = element.value { entry.value = value }
            entry.options = element.options
            return entry
        }
        screen.presented = presented.map { presentation in
            var entry = Wire_Presentation()
            entry.style = presentation.style
            entry.title = presentation.title
            entry.message = presentation.message
            return entry
        }
        return screen
    }
}

/// Drives the app running in this process.
@MainActor
public final class IsomerAppDriver {
    /// What the app is, for `info` (the host fills in its platform and
    /// renderer).
    public var info: Wire_Info
    /// Renders a frame if the app asked for one (the headless host's frames
    /// come only from here); nil where the host draws on its own.
    private let renderIfNeeded: (@MainActor () -> Void)?
    private var encoder = FlatTreeEncoder()

    public init(info: Wire_Info, renderIfNeeded: (@MainActor () -> Void)? = nil) {
        self.info = info
        self.renderIfNeeded = renderIfNeeded
    }

    /// The app's name, bundle identifier and version from its bundle, for an
    /// `info` a host completes.
    public static func bundleInfo(platform: String, renderer: String) -> Wire_Info {
        var info = Wire_Info()
        let bundle = Bundle.main
        let environment = ProcessInfo.processInfo.environment
        info.name = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? environment["ISOMER_BUNDLE_NAME"] ?? ProcessInfo.processInfo.processName
        info.bundleIdentifier = bundle.bundleIdentifier ?? environment["ISOMER_BUNDLE_IDENTIFIER"] ?? ""
        info.version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        info.platform = platform
        info.renderer = renderer
        return info
    }

    /// The frame as it stands, its handlers installed where the runtime
    /// looks them up (the same ids a renderer's encoding gives them).
    func screen() -> DriverScreen? {
        guard let tree = Runtime.shared.retainedTree else { return nil }
        encoder = FlatTreeEncoder()
        guard let root = try? IsoFlat_Node(treeBytes: encoder.encode(root: tree)) else { return nil }
        Runtime.shared.installTreeHandlers(encoder.handlers)
        return DriverScreen(root)
    }

    /// Frames until the screen holds still (three readings in a row the same,
    /// or the timeout): the app's tasks and animations run meanwhile.
    func settle(timeout: Double = 3) async -> DriverScreen? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: Wire_Screen?
        var still = 0
        var current = screen()
        while Date() < deadline {
            renderIfNeeded?()
            current = screen()
            let reading = current?.wire
            if reading == last {
                still += 1
                if still >= 3 { break }
            } else {
                still = 0
                last = reading
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return current
    }

    /// Runs one command and answers it.
    public func handle(_ command: Wire_Command) async -> Wire_Answer {
        var error: String?
        let target = command.target
        let before = await settle()
        let runtime = Runtime.shared
        switch command.cmd {
        case "ls", "quit":
            break
        case "info":
            break
        case "tap":
            if let handler = before?.element(target, roles: ["button"])?.handler {
                runtime.hostViewEvent(id: handler, value: "")
            } else {
                error = "no button \(target)"
            }
        case "type":
            if let handler = before?.element(target, roles: ["textField"])?.handler {
                runtime.hostViewEvent(id: handler, value: command.text)
            } else {
                error = "no text field \(target)"
            }
        case "set":
            if let handler = before?.element(target)?.handler {
                runtime.hostViewEvent(id: handler, value: command.value)
            } else {
                error = "no control \(target)"
            }
        case "select":
            if let element = before?.element(target, roles: ["picker", "segmented"]), let handler = element.handler {
                let wanted = command.value
                if let index = element.options.firstIndex(of: wanted)
                    ?? element.options.firstIndex(where: { $0.localizedCaseInsensitiveCompare(wanted) == .orderedSame }) {
                    runtime.hostViewEvent(id: handler, value: String(index))
                } else {
                    error = "\(target) has no option \(wanted) (it has \(element.options.joined(separator: ", ")))"
                }
            } else {
                error = "no picker \(target)"
            }
        case "swipe":
            if let handler = before?.draggable(target) {
                let distance = 240.0
                let (dx, dy): (Double, Double)
                switch command.direction {
                case "up": (dx, dy) = (0, -distance)
                case "down": (dx, dy) = (0, distance)
                case "left": (dx, dy) = (-distance, 0)
                default: (dx, dy) = (distance, 0)
                }
                // A drag's moves, then its end, as a renderer reports them.
                for step in 1...4 {
                    let fraction = Double(step) / 4
                    runtime.hostViewEvent(id: handler, value: "changed:\(dx * fraction),\(dy * fraction)")
                    renderIfNeeded?()
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
                runtime.hostViewEvent(id: handler, value: "ended:\(dx),\(dy)")
            } else {
                error = target.isEmpty ? "nothing on the screen takes a swipe" : "\(target) takes no swipe"
            }
        case "back":
            if !runtime.handleBackButton() { error = "nothing to go back from" }
        case "dismiss":
            if let dismiss = before?.presented.last?.dismiss {
                runtime.hostViewEvent(id: dismiss, value: "")
            } else {
                error = "nothing presented"
            }
        case "wait":
            let text = command.text
            let deadline = Date().addingTimeInterval(command.timeout > 0 ? command.timeout : 5)
            var shown = false
            while Date() < deadline {
                if let frame = await settle(timeout: 0.5), frame.texts.contains(where: { $0.contains(text) })
                    || frame.elements.contains(where: { $0.label.contains(text) || ($0.value ?? "").contains(text) }) {
                    shown = true
                    break
                }
            }
            if !shown { error = "\(text) didn't show" }
        default:
            error = "unknown command: \(command.cmd)"
        }
        runtime.requestFrame()
        var answer = Wire_Answer()
        answer.ok = error == nil
        if let error { answer.error = error }
        if let frame = await settle() { answer.screen = frame.wire }
        if command.cmd == "info" {
            var info = self.info
            info.width = runtime.width
            info.height = runtime.height
            answer.info = info
        }
        return answer
    }
}

/// The driver as an `IsomerServer`'s `drive`: commands answered one at a
/// time on the main actor, until `quit` or the call's end.
public struct IsomerDriverServer: IsomerServer {
    let driver: IsomerAppDriver
    /// Told of `quit` (a headless app ends).
    let onQuit: @Sendable () -> Void

    public init(_ driver: IsomerAppDriver, onQuit: @escaping @Sendable () -> Void = {}) {
        self.driver = driver
        self.onQuit = onQuit
    }

    public func drive(_ commands: IsomerInbound<Wire_Command>, _ answers: IsomerOutbound<Wire_Answer>, context: IsomerCallContext) async throws {
        for try await command in commands {
            let answer = await driver.handle(command)
            try await answers.write(answer)
            if command.cmd == "quit" {
                onQuit()
                return
            }
        }
    }
}

extension IsomerAppDriver {
    /// Dials out to a driver (a test host, a CLI's hub) and serves its
    /// commands over the connection this app opened, until it ends: the
    /// way a headful app is driven from where it can't be reached (a
    /// simulator, an emulator, a device, a browser tab).
    public func dialOut(_ connection: any IsomerConnection, context: IsomerCallContext) async throws {
        let call = try await connection.attach(context: context)
        var hello = Wire_Answer()
        hello.ok = true
        hello.info = info
        try await call.write(hello)
        for try await command in call.inbound {
            try await call.write(await handle(command))
            if command.cmd == "quit" { break }
        }
        await call.finish()
    }
}
