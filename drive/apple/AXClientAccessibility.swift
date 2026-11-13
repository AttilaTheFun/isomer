// The Apple driver on the Mac (AccessibilityDriver.swift): the app asks its
// own process for its accessibility tree as an accessibility client would
// (AXUIElement), which is what makes SwiftUI build it, and acts through the
// same API (press, select a row, set a value, increment, cancel). In its own
// process AppKit answers each call on the calling thread, so every call is
// made on the main thread, as AppKit's views must be touched.

#if canImport(AppKit) && !canImport(UIKit)
import AppKit
import ApplicationServices
import Foundation
import IsomerWire

/// One element of the tree as read, for the screen built from it.
private struct AXNode: @unchecked Sendable {
    var role: String
    var label: String
    var value: String?
    var id: String?
    var options: [String] = []
    var element: AXUIElement
    var kind: String
    var params: [String: String]
}

/// Reads the tree (on the main thread: AppKit answers in process).
private enum AXClient {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let text = attribute(element, name) as? String, !text.isEmpty else { return nil }
        return text
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func value(_ element: AXUIElement) -> String? {
        guard let value = attribute(element, kAXValueAttribute) else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func frame(_ element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID() {
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        }
        if let extent = attribute(element, kAXSizeAttribute), CFGetTypeID(extent) == AXValueGetTypeID() {
            AXValueGetValue(extent as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }

    /// The window's chrome (close, zoom, minimize), not the app's.
    static let chrome: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]

    /// The app's front window, or what it presents (a sheet, an alert):
    /// its elements in order, and what is presented.
    static func read(_ pid: pid_t) -> (nodes: [AXNode], presented: [(String, String, String)], size: CGSize) {
        let app = AXUIElementCreateApplication(pid)
        let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let focused = attribute(app, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
        func isPresented(_ element: AXUIElement) -> Bool {
            string(element, kAXRoleAttribute) == "AXSheet"
                || ["AXDialog", "AXSystemDialog", "AXFloatingWindow"].contains(string(element, kAXSubroleAttribute) ?? "")
        }
        // The main window: the focused one, or the first standard one.
        let main = [focused].compactMap { $0 }.first { !isPresented($0) }
            ?? windows.first { !isPresented($0) } ?? focused ?? windows.first
        guard let main else { return ([], [], .zero) }
        // What it presents: a sheet among its children or the app's windows,
        // a dialog window, the focused one if it is one.
        var presentations = children(main).filter(isPresented) + windows.filter(isPresented)
        if let focused, isPresented(focused), !presentations.contains(where: { CFEqual($0, focused) }) {
            presentations.append(focused)
        }
        var root = main
        var presented: [(String, String, String)] = []
        if let sheet = presentations.last {
            root = sheet
            var texts: [String] = []
            func collect(_ element: AXUIElement) {
                if string(element, kAXRoleAttribute) == "AXStaticText", let text = value(element) ?? string(element, kAXDescriptionAttribute) {
                    texts.append(text)
                }
                for child in children(element) { collect(child) }
            }
            collect(sheet)
            // Sheet or alert: AppKit says which (AXClientAccessibility's
            // screen()); the texts are its title and message.
            presented.append(("sheet", texts.first ?? string(sheet, kAXTitleAttribute) ?? "", texts.dropFirst().first ?? ""))
        }
        // An open menu (a Menu's pull-down, a pop-up's): an AXMenu under its
        // button, which a button's node doesn't lead into. While it's open
        // it is all that can be used, as a person sees it; its items are
        // buttons (AXMenuItem).
        if let menu = openMenu(in: root) { root = menu }
        var nodes: [AXNode] = []
        visit(root, &nodes)
        return (nodes, presented, frame(main).size)
    }

    /// The menu open under `element` (an AXMenu with items), if one is.
    static func openMenu(in element: AXUIElement) -> AXUIElement? {
        for child in children(element) {
            if string(child, kAXRoleAttribute) == "AXMenu",
               children(child).contains(where: { string($0, kAXRoleAttribute) == "AXMenuItem" }) {
                return child
            }
            if let found = openMenu(in: child) { return found }
        }
        return nil
    }

    static func visit(_ element: AXUIElement, _ nodes: inout [AXNode]) {
        let role = string(element, kAXRoleAttribute) ?? ""
        let subrole = string(element, kAXSubroleAttribute)
        if let subrole, chrome.contains(subrole) { return }
        let label = string(element, kAXDescriptionAttribute) ?? string(element, kAXTitleAttribute) ?? ""
        let id = string(element, kAXIdentifierAttribute)
        let frame = frame(element)
        var params = ["role": role, "frame": "\(Int(frame.minX)) \(Int(frame.minY)) \(Int(frame.width)) \(Int(frame.height))"]
        if let subrole { params["subrole"] = subrole }
        if let help = string(element, kAXHelpAttribute) { params["help"] = help }
        func node(_ role: String, _ label: String, _ value: String?, _ options: [String] = []) -> AXNode {
            AXNode(role: role, label: label, value: value, id: id, options: options, element: element, kind: role == "text" ? "AXStaticText" : params["role"]!, params: params)
        }
        switch role {
        case "AXButton", "AXLink", "AXMenuButton", "AXMenuItem":
            nodes.append(node("button", label, nil))
        case "AXCheckBox", "AXSwitch":
            nodes.append(node("toggle", label, value(element)))
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField":
            let placeholder = string(element, kAXPlaceholderValueAttribute) ?? ""
            nodes.append(node("textField", label.isEmpty ? placeholder : label, value(element)))
        case "AXSlider":
            nodes.append(node("slider", label, value(element)))
        case "AXIncrementor":
            nodes.append(node("stepper", label, value(element)))
        case "AXPopUpButton":
            nodes.append(node("picker", label, value(element)))
        case "AXRadioGroup":
            let options = children(element).compactMap { string($0, kAXTitleAttribute) ?? string($0, kAXDescriptionAttribute) }
            nodes.append(node("segmented", label, nil, options))
        case "AXStaticText":
            if let text = value(element) ?? (label.isEmpty ? nil : label) { nodes.append(node("text", text, nil)) }
        case "AXRow":
            // A list's row that holds only texts is a button (it selects, it
            // opens), as Isomer's renderers give it: its texts, then it.
            let start = nodes.count
            for child in children(element) { visit(child, &nodes) }
            let added = nodes[start...]
            if !added.isEmpty, added.allSatisfy({ $0.role == "text" }) {
                var row = node("button", added.map(\.label).joined(separator: " "), nil)
                row.kind = "AXRow"
                nodes.append(row)
            }
        default:
            for child in children(element) { visit(child, &nodes) }
        }
    }

    /// An action done: a press that opens something modal (an alert)
    /// returns before it completes, and one that closes its own window (an
    /// alert's Cancel) leaves its element gone; both still pressed.
    static func perform(_ element: AXUIElement, _ action: String) -> Bool {
        let result = AXUIElementPerformAction(element, action as CFString)
        return result == .success || result == .cannotComplete || result == .invalidUIElement
    }

    static func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, name as CFString, value) == .success
    }
}

extension AccessibilityDriver {
    static let platform = "macOS"

    /// The Mac's tree is built for whoever asks for it: nothing to turn on.
    static func enableAccessibility() {}

    func screen() async -> AccessibilityScreen {
        let (nodes, presented, size) = AXClient.read(getpid())
        info.width = Double(size.width)
        info.height = Double(size.height)
        var screen = AccessibilityScreen()
        // An alert is an NSAlert's panel (a sheet on its window, or a modal
        // window of its own); a SwiftUI sheet is SwiftUI's window.
        let alert = NSApp.windows.contains { window in
            window.isVisible && (window.sheetParent != nil || window == NSApp.modalWindow)
                && String(describing: Swift.type(of: window)).contains("Alert")
        }
        screen.presented = presented.map { (style: alert ? "alert" : $0.0, title: $0.1, message: $0.2) }
        for node in nodes {
            screen.add(node.element, role: node.role, label: node.label, value: node.value, id: node.id,
                       options: node.options, kind: node.kind, params: node.params)
        }
        screen.name()
        return screen
    }

    /// AppKit's transitions are the app's own, and the screen settles past
    /// them.
    func transitioning() -> Bool { false }

    /// A Mac's list gives every row: nothing to scroll to.
    func reveal(_ screen: AccessibilityScreen, _ find: (AccessibilityScreen) -> AccessibilityScreen.Element?) async
        -> AccessibilityScreen.Element? {
        find(screen)
    }

    private func element(_ element: AccessibilityScreen.Element) -> AXUIElement {
        element.object as! AXUIElement
    }

    /// Runs `body` here, on the main thread, where AppKit answers it.
    private func off<T>(_ body: () -> T) async -> T {
        body()
    }

    /// A row is selected (as a click selects it, which opens a sidebar's
    /// destination); anything else is pressed.
    func activate(_ target: AccessibilityScreen.Element) async -> Bool {
        let ax = UncheckedAX(element(target))
        let row = target.kind == "AXRow"
        let before = await screen().wire
        let done = await off {
            if row { return AXClient.set(ax.element, kAXSelectedAttribute, kCFBooleanTrue) }
            return AXClient.perform(ax.element, kAXPressAction)
        }
        if done { return true }
        // A press can report failure and still have done what it does (an
        // alert's button closes the alert as it answers): it took if the
        // screen changed.
        try? await Task.sleep(nanoseconds: 300_000_000)
        return await screen().wire != before
    }

    func type(_ text: String, into target: AccessibilityScreen.Element) async -> Bool {
        let ax = UncheckedAX(element(target))
        return await off {
            _ = AXClient.set(ax.element, kAXFocusedAttribute, kCFBooleanTrue)
            return AXClient.set(ax.element, kAXValueAttribute, text as CFString)
        }
    }

    func set(_ target: AccessibilityScreen.Element, _ value: String) async -> String? {
        let ax = UncheckedAX(element(target))
        switch target.role {
        case "toggle":
            let on = ["1", "on", "true"].contains(value.lowercased())
            if on != (target.value == "1"), !(await activate(target)) { return "\(target.name) didn't toggle" }
            return nil
        case "slider":
            guard let number = Double(value) else { return "\(value) isn't a number" }
            return await off { AXClient.set(ax.element, kAXValueAttribute, NSNumber(value: number)) }
                ? nil : "\(target.name) didn't take \(value)"
        case "stepper":
            guard let want = Double(value) else { return "\(value) isn't a number" }
            for _ in 0..<100 {
                let current = await off { AXClient.value(ax.element) } ?? ""
                guard let have = Double(current) else { return "\(target.name)'s value \(current) isn't a number" }
                if have == want { return nil }
                let action = have < want ? kAXIncrementAction : kAXDecrementAction
                guard await off({ AXClient.perform(ax.element, action) }) else { return "\(target.name) stopped at \(current)" }
            }
            return "\(target.name) didn't reach \(value)"
        case "textField":
            return await type(value, into: target) ? nil : "\(target.name) takes no text"
        default:
            return "\(target.name) can't be set"
        }
    }

    func select(_ target: AccessibilityScreen.Element, _ option: String) async -> String? {
        let ax = UncheckedAX(element(target))
        if target.role == "segmented" {
            let pressed = await off {
                for child in AXClient.children(ax.element)
                    where (AXClient.string(child, kAXTitleAttribute) ?? AXClient.string(child, kAXDescriptionAttribute)) == option {
                    return AXClient.perform(child, kAXPressAction)
                }
                return false
            }
            return pressed ? nil : "\(target.name) has no option \(option)"
        }
        // A pop-up's menu: opened, then its item pressed.
        guard await off({ AXClient.perform(ax.element, kAXPressAction) }) else { return "\(target.name) didn't open" }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let chosen = await off {
            func find(_ element: AXUIElement) -> AXUIElement? {
                if AXClient.string(element, kAXRoleAttribute) == "AXMenuItem", AXClient.string(element, kAXTitleAttribute) == option {
                    return element
                }
                for child in AXClient.children(element) { if let found = find(child) { return found } }
                return nil
            }
            guard let item = find(ax.element) else {
                _ = AXClient.perform(ax.element, kAXCancelAction)
                return false
            }
            return AXClient.perform(item, kAXPressAction)
        }
        return chosen ? nil : "\(target.name) has no option \(option)"
    }

    func swipe(_ screen: AccessibilityScreen, _ target: String, _ direction: String) async -> String? {
        "swipe isn't driven on the Mac yet"
    }

    /// The toolbar's Back, as a navigation stack gives it.
    func back(_ screen: AccessibilityScreen) async -> Bool {
        guard let button = screen.elements.last(where: { $0.role == "button" && ($0.label == "Back" || $0.id == "Back") })
        else { return false }
        return await activate(button)
    }

    /// A sheet's cancel, as Escape gives it; else its Cancel button.
    func dismiss(_ screen: AccessibilityScreen) async -> Bool {
        if let cancel = screen.elements.last(where: { $0.role == "button" && ["Cancel", "Done", "OK"].contains($0.label) }) {
            return await activate(cancel)
        }
        let pid = getpid()
        return await off {
            let app = AXUIElementCreateApplication(pid)
            guard let window = AXClient.attribute(app, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }),
                  let sheet = AXClient.children(window).last(where: { AXClient.string($0, kAXRoleAttribute) == "AXSheet" })
            else { return false }
            return AXClient.perform(sheet, kAXCancelAction)
        }
    }
}

/// An AXUIElement carried to the thread that asks it (CF objects are safe
/// to use from any thread).
private struct UncheckedAX: @unchecked Sendable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}
#endif
