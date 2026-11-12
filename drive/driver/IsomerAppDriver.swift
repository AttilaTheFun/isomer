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
        /// What a tap sends its handler: nothing for a button; a bar item's
        /// place (`trailingItem:2`) or a menu's item (`3`) for the chrome a
        /// host draws from one node.
        var tapValue = ""
        /// A `Menu`'s button: a tap opens it, and its items are buttons
        /// until one is tapped (`select` chooses one directly).
        var menu = false
        /// What leads text typed into it: a component renderer's search
        /// field is its navigation stack's (`search:<text>`).
        var typePrefix = ""
        /// Its name on the screen: its role and its place among that role's,
        /// from 1 (`button-3`).
        var name = ""
        /// Its node, for `inspect`; and the element it is inside, if any.
        var node: IsoFlat_Node?
        var container: Int?
    }

    var texts: [String] = []
    /// Each text's node and the element it is inside (`text-<n>`, the n-th).
    var textNodes: [(node: IsoFlat_Node, container: Int?)] = []
    var elements: [Element] = []
    /// The views a swipe drags, by the texts in them: (texts, id, drag handler).
    var draggables: [(label: String, id: String?, handler: String)] = []
    var presented: [(style: String, title: String, message: String, dismiss: String?)] = []

    /// Whether the width is compact: a split view then shows one column.
    let compact: Bool
    /// A compact split view showing a column after its first: its handler
    /// and the column before, where `back` goes (as a host reports it,
    /// "compact:<column>:back").
    var splitBack: (handler: String, column: String)?
    /// The topmost presentation's node (the last one walked), if any.
    private var topPresentation: IsoFlat_Node?

    /// The menu a tap opened (its handler), whose items are buttons.
    let openMenu: String?

    init(_ root: IsoFlat_Node, compact: Bool = false, openMenu: String? = nil) {
        self.compact = compact
        self.openMenu = openMenu
        walk(root, around: [], inside: nil)
        // Something presented (a sheet, an alert, a popover) is all that can
        // be used: the screen is the topmost presentation's, as a person
        // sees it, with every presentation still listed.
        if let top = topPresentation {
            let shown = presented
            texts = []
            textNodes = []
            elements = []
            draggables = []
            splitBack = nil
            walk(top, around: [], inside: nil)
            presented = shown
        }
        var counts: [String: Int] = [:]
        for index in elements.indices {
            let role = elements[index].role
            counts[role, default: 0] += 1
            elements[index].name = "\(role)-\(counts[role]!)"
        }
    }

    /// The columns a split view shows: at compact width the one its
    /// `compact` parameter names (the sidebar until it says otherwise), as the
    /// hosts collapse it; every column at regular width.
    private func shownColumns(_ node: IsoFlat_Node, _ p: [String: String]) -> [IsoFlat_Node] {
        guard compact else { return node.ch }
        let names = p["columns"] == "2" ? ["sidebar", "detail"] : ["sidebar", "content", "detail"]
        guard let index = names.firstIndex(of: p["compact"] ?? "sidebar"), index < node.ch.count else { return node.ch }
        return [node.ch[index]]
    }

    /// The column before the one a compact split view shows, if any.
    private func previousColumn(_ p: [String: String]) -> String? {
        let names = p["columns"] == "2" ? ["sidebar", "detail"] : ["sidebar", "content", "detail"]
        guard let index = names.firstIndex(of: p["compact"] ?? "sidebar"), index > 0 else { return nil }
        return names[index - 1]
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
    /// `inside`: the element the node is in (its index), for a text's
    /// container.
    /// `combined`: inside an element made one (`.accessibilityElement(children:
    /// .combine)`), whose texts were taken as one.
    private mutating func walk(_ node: IsoFlat_Node, around: [String], inside: Int?, combined: Bool = false) {
        let p = Self.params(node)
        if p["a11yHidden"] == "1" { return }
        let id = p["a11yId"]
        let count = elements.count
        // A view made one accessibility element of its children: its texts
        // are one text, a line each (a code listing reads as one), as
        // VoiceOver reads it as one element.
        let combines = !combined && p["a11yChildren"] == "combine"
        if combines {
            let merged = Self.textsUnder(node).joined(separator: "\n")
            if !merged.isEmpty {
                texts.append(merged)
                textNodes.append((node, inside))
            }
        }
        switch node.kind {
        case .text:
            if !combined, !combines, let text = node.v, !text.isEmpty {
                texts.append(text)
                textNodes.append((node, inside))
            }
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
            topPresentation = node
        case .hostview:
            let kind = node.view ?? "view"
            if ["toggle", "picker", "segmented", "stepper", "datepicker", "colorpicker"].contains(kind) {
                var label = p["a11yLabel"] ?? p["title"] ?? Self.textsUnder(node).joined(separator: " ")
                if label.isEmpty { label = around.joined(separator: " ") }
                let role = kind == "picker" && p["style"] == "segmented" ? "segmented" : kind
                elements.append(Element(role: role, label: label, id: id, value: node.v,
                                        options: node.options.compactMap { $0 }, handler: node.edit))
            } else if kind == "menu" {
                // A Menu: a button named by its label (options[0]); its
                // actions are options[1...], sent by their 1-based place.
                let options = node.options.compactMap { $0 }
                let label = p["a11yLabel"] ?? options.first ?? "Menu"
                var button = Element(role: "button", label: label, id: id, options: Array(options.dropFirst()),
                                     handler: node.edit)
                button.menu = true
                elements.append(button)
                if let handler = node.edit, handler == openMenu {
                    for (index, option) in options.enumerated().dropFirst() {
                        var item = Element(role: "button", label: option, handler: handler)
                        item.tapValue = String(index)
                        elements.append(item)
                    }
                }
            } else if kind == "search" {
                // `.searchable`'s field, named by its prompt.
                elements.append(Element(role: "textField", label: p["a11yLabel"] ?? p["prompt"] ?? "Search", id: id,
                                        value: node.v ?? "", handler: node.edit))
            } else if kind == "navbar" || kind == "navstack", let handler = node.edit {
                // The bar's items, drawn by the host from this one node (the
                // self-drawing renderer's bar, a component renderer's
                // navigation stack): a button each, named by its
                // accessibility label (an icon item's title) or its title, a
                // tap sending its place.
                func items(_ titles: String?, _ labels: String?, _ disabled: String?, tap: (Int) -> String) {
                    guard let titles, !titles.isEmpty else { return }
                    let labelList = (labels ?? "").components(separatedBy: "\n")
                    let disabledList = (disabled ?? "").components(separatedBy: "\n")
                    for (index, title) in titles.components(separatedBy: "\n").enumerated() {
                        if disabledList.indices.contains(index), disabledList[index] == "1" { continue }
                        let label = labelList.indices.contains(index) && !labelList[index].isEmpty ? labelList[index] : title
                        var item = Element(role: "button", label: label, handler: handler)
                        item.tapValue = tap(index)
                        elements.append(item)
                    }
                }
                items(p["leading"], p["leadingLabels"], p["leadingDisabled"]) { "leading:\($0)" }
                items(p["trailingItems"], p["trailingLabels"], p["trailingDisabled"]) { "trailingItem:\($0)" }
                // A component renderer's `.searchable` field, the stack's own.
                if kind == "navstack", let prompt = p["searchPrompt"] {
                    var field = Element(role: "textField", label: prompt, value: p["searchValue"] ?? "", handler: handler)
                    field.typePrefix = "search:"
                    elements.append(field)
                }
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
        let split = node.kind == .hostview && node.view == "navsplit"
        // The innermost split showing a later column takes `back`.
        if split, compact, let handler = node.edit, let previous = previousColumn(p) {
            splitBack = (handler, previous)
        }
        // What this node added is its children's container (the innermost).
        for index in count..<elements.count {
            elements[index].node = node
            elements[index].container = inside
        }
        let within = elements.count > count ? elements.count - 1 : inside
        let children = split ? shownColumns(node, p) : node.ch
        for child in children { walk(child, around: texts, inside: within, combined: combined || combines) }
    }

    /// A name on the screen (`button-3`, `text-2`): its role and place.
    static func parseName(_ target: String) -> (role: String, number: Int)? {
        guard let dash = target.lastIndex(of: "-"), let number = Int(target[target.index(after: dash)...]), number > 0 else {
            return nil
        }
        let role = String(target[..<dash])
        guard !role.isEmpty, role.allSatisfy(\.isLetter) else { return nil }
        return (role, number)
    }

    /// The element a name gives (`button-3`); for `text-<n>`, the element
    /// the text is in.
    func named(_ target: String) -> Element? {
        guard let (role, number) = Self.parseName(target) else { return nil }
        if role.lowercased() == "text" {
            guard number <= textNodes.count, let container = textNodes[number - 1].container else { return nil }
            return elements[container]
        }
        return elements.filter { $0.role.lowercased() == role.lowercased() }.dropFirst(number - 1).first
    }

    /// The element a target names: its name on the screen, its accessibility
    /// identifier, then its label exactly, then the last (innermost) whose
    /// label holds it.
    func element(_ target: String, roles: Set<String>? = nil) -> Element? {
        if let element = named(target) {
            return roles == nil || roles!.contains(element.role) ? element : nil
        }
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

    /// `inspect`: an element or a text in full, as the tree has it.
    func inspection(_ target: String) -> Wire_Inspection? {
        var inspection = Wire_Inspection()
        let node: IsoFlat_Node
        var container: Int?
        if let (role, number) = Self.parseName(target), role.lowercased() == "text" {
            guard number <= textNodes.count else { return nil }
            node = textNodes[number - 1].node
            container = textNodes[number - 1].container
            inspection.name = "text-\(number)"
            inspection.role = "text"
            // The text as listed: a combined element's, its texts as one.
            inspection.label = texts[number - 1]
        } else {
            guard let element = element(target), let elementNode = element.node else { return nil }
            node = elementNode
            container = element.container
            inspection.name = element.name
            inspection.role = element.role
            inspection.label = element.label
            if let id = element.id { inspection.id = id }
            if let value = element.value { inspection.value = value }
            inspection.options = element.options
        }
        if let container { inspection.container = elements[container].name }
        inspection.texts = Self.textsUnder(node)
        switch node.kind {
        case .hostview: inspection.kind = node.view ?? "hostView"
        case .textfield: inspection.kind = "textField"
        default: inspection.kind = "\(node.kind)"
        }
        inspection.actions = [node.tap.map { _ in "tap" }, node.edit.map { _ in "edit" }, node.drag.map { _ in "drag" }]
            .compactMap { $0 }
        inspection.params = Self.params(node)
        if let size = node.size { inspection.fontSize = size }
        if let weight = node.weight { inspection.fontWeight = weight }
        if let lines = node.lines { inspection.lines = lines }
        if let color = node.color {
            func hex(_ channel: Float32) -> String { String(format: "%02x", Int((max(0, min(1, channel)) * 255).rounded())) }
            inspection.color = "#" + hex(color.r) + hex(color.g) + hex(color.b) + hex(color.a)
        }
        return inspection
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
            entry.name = element.name
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
    /// The `Menu` a tap opened (its handler): its items are buttons on the
    /// next screens, until one is tapped or something else is.
    private var openMenu: String?

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
        // The tree as the app means it: a self-drawing renderer's drawn
        // chrome read as the toggle, picker or bar it stands for.
        encoder.semantic = true
        guard let root = try? IsoFlat_Node(treeBytes: encoder.encode(root: tree)) else { return nil }
        Runtime.shared.installTreeHandlers(encoder.handlers)
        return DriverScreen(root, compact: Runtime.shared.compactWidth, openMenu: openMenu)
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

    /// A target on no row built: each lazy list's rows built a page at a
    /// time, as though its host scrolled there, until a screen has it (a
    /// person scrolls to it; the runtime builds a list's rows near those
    /// shown). Gives that screen and what puts the list back as its host
    /// last showed it.
    func reveal(_ target: String) async -> (screen: DriverScreen, restore: () -> Void)? {
        let runtime = Runtime.shared
        let page = 20
        for (list, rows, shown) in runtime.listsWithUnbuiltRows {
            var first = 0
            while first < rows {
                runtime.showListRows(list, first...min(rows - 1, first + page - 1))
                if let screen = await settle(), screen.element(target) != nil {
                    return (screen, { runtime.showListRows(list, shown) })
                }
                first += page
            }
            runtime.showListRows(list, shown)
        }
        return nil
    }

    /// Runs one command and answers it.
    public func handle(_ command: Wire_Command) async -> Wire_Answer {
        var error: String?
        let target = command.target
        var before = await settle()
        let runtime = Runtime.shared
        // A target by label or identifier on no row built is looked for down
        // the lists (a name, `button-3`, is this screen's own).
        var restore: (() -> Void)?
        if ["tap", "type", "set", "select", "inspect"].contains(command.cmd), !target.isEmpty,
           DriverScreen.parseName(target) == nil, let screen = before, screen.element(target) == nil,
           let (revealed, putBack) = await reveal(target) {
            before = revealed
            restore = putBack
        }
        defer { restore?() }
        // The element used is brought into sight first, as a person scrolls
        // to what they tap, so a headful app is seen to be driven; a headless
        // one draws nothing to scroll.
        if info.platform != "Headless", ["tap", "type", "set", "select"].contains(command.cmd), !target.isEmpty,
           let handler = before?.element(target)?.handler {
            runtime.reveal(handler: handler)
            before = await settle() ?? before
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        switch command.cmd {
        case "ls", "quit":
            break
        case "info":
            break
        case "inspect":
            if let inspection = before?.inspection(target) {
                var answer = Wire_Answer()
                answer.ok = true
                answer.inspection = inspection
                if let before { answer.screen = before.wire }
                return answer
            }
            error = "no element \(target)"
        case "tap":
            if let element = before?.element(target, roles: ["button"]), let handler = element.handler {
                if element.menu {
                    // Opened: its items are buttons now.
                    openMenu = handler
                } else {
                    openMenu = nil
                    runtime.hostViewEvent(id: handler, value: element.tapValue)
                }
            } else {
                error = "no button \(target)"
            }
        case "type":
            if let element = before?.element(target, roles: ["textField"]), let handler = element.handler {
                runtime.hostViewEvent(id: handler, value: element.typePrefix + command.text)
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
            if let element = before?.element(target, roles: ["button"]), element.menu, let handler = element.handler {
                // A Menu's item, chosen directly (1-based: its label is 0).
                let wanted = command.value
                if let index = element.options.firstIndex(of: wanted)
                    ?? element.options.firstIndex(where: { $0.localizedCaseInsensitiveCompare(wanted) == .orderedSame }) {
                    openMenu = nil
                    runtime.hostViewEvent(id: handler, value: String(index + 1))
                } else {
                    error = "\(target) has no item \(wanted) (it has \(element.options.joined(separator: ", ")))"
                }
            } else if let element = before?.element(target, roles: ["picker", "segmented"]), let handler = element.handler {
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
            // A navigation stack's page first; then a compact split view's
            // column, as its host goes back to the column before.
            if !runtime.handleBackButton() {
                if let back = before?.splitBack {
                    runtime.hostViewEvent(id: back.handler, value: "compact:\(back.column):back")
                } else {
                    error = "nothing to go back from"
                }
            }
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
        // The list as its host shows it again, for the answer's screen.
        restore?()
        restore = nil
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
