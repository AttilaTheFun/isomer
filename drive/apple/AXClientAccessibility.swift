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
    var disabled = false
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
        // Each presentation, the one on top last (a sheet presented from a
        // sheet is the outer's child); the screen is the topmost's.
        var stack: [AXUIElement] = []
        var level = presentations.first
        while let current = level {
            stack.append(current)
            level = children(current).first(where: isPresented)
        }
        for presentation in presentations where !stack.contains(where: { CFEqual($0, presentation) }) {
            stack.append(presentation)
        }
        for sheet in stack {
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
        // button, which a button's node doesn't lead into; a context menu,
        // one of the application's own. While it's open it is all that can
        // be used, as a person sees it; its items are buttons (AXMenuItem).
        if let menu = openMenu(in: root) ?? children(app).first(where: isMenu) { root = menu }
        var nodes: [AXNode] = []
        visit(root, &nodes)
        return (nodes, presented, frame(main).size)
    }

    /// The menu open under `element` (an AXMenu with items), if one is.
    static func openMenu(in element: AXUIElement) -> AXUIElement? {
        for child in children(element) {
            if isMenu(child) { return child }
            if let found = openMenu(in: child) { return found }
        }
        return nil
    }

    /// An open menu: an AXMenu with items.
    static func isMenu(_ element: AXUIElement) -> Bool {
        string(element, kAXRoleAttribute) == "AXMenu"
            && children(element).contains(where: { string($0, kAXRoleAttribute) == "AXMenuItem" })
    }

    static func visit(_ element: AXUIElement, _ nodes: inout [AXNode]) {
        let role = string(element, kAXRoleAttribute) ?? ""
        let subrole = string(element, kAXSubroleAttribute)
        if let subrole, chrome.contains(subrole) { return }
        let label = string(element, kAXDescriptionAttribute) ?? string(element, kAXTitleAttribute) ?? ""
        let id = string(element, kAXIdentifierAttribute)
        let frame = frame(element)
        var params = ["role": role, "frame": AccessibilityScreen.describe(frame)]
        if let subrole { params["subrole"] = subrole }
        if let help = string(element, kAXHelpAttribute) { params["help"] = help }
        // AXEnabled false: listed as disabled, as Isomer's driver lists it.
        let disabled = (attribute(element, kAXEnabledAttribute) as? Bool) == false
        func node(_ role: String, _ label: String, _ value: String?, _ options: [String] = []) -> AXNode {
            AXNode(role: role, label: label, value: value, id: id, options: options, element: element,
                   kind: role == "text" ? "AXStaticText" : params["role"]!, params: params, disabled: disabled)
        }
        switch role {
        case "AXButton", "AXLink", "AXMenuButton", "AXMenuItem":
            var button = node("button", label, nil)
            // A navigation stack's Back (its chevron's symbol for an
            // identifier): named as UIKit's bar names it, so a test finds
            // it by one identifier on either.
            if id == "chevron.backward", label == "Back" { button.id = "BackButton" }
            nodes.append(button)
        case "AXRadioButton":
            // A tab of a tab group (SwiftUI's TabView on the Mac: an
            // AXTabGroup of radio buttons) is a button named by its title, as
            // UIKit's tab bar's are; a radio group's are its options instead
            // (AXRadioGroup, below, doesn't visit them).
            nodes.append(node("button", label, nil))
        case "AXCheckBox", "AXSwitch":
            nodes.append(node("toggle", label, value(element)))
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField":
            let placeholder = string(element, kAXPlaceholderValueAttribute) ?? ""
            nodes.append(node("textField", label.isEmpty ? placeholder.isEmpty ? fieldTitle(element) : placeholder : label,
                              value(element)))
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
                // The identifier its content carries is the row's (a
                // `List(selection:)` row found by it), not its texts'.
                if row.id == nil { row.id = added.first(where: { $0.id != nil })?.id }
                for index in start..<nodes.count { nodes[index].id = nil }
                nodes.append(row)
            }
        default:
            for child in children(element) { visit(child, &nodes) }
        }
    }

    /// A field's title where it carries none of its own: the text that
    /// titles it (AXTitleUIElement), else the text beside it in its row (a
    /// Form's row on the Mac draws a TextField's title as a label before
    /// the field).
    static func fieldTitle(_ element: AXUIElement) -> String {
        if let title = attribute(element, kAXTitleUIElementAttribute), CFGetTypeID(title) == AXUIElementGetTypeID() {
            let text = title as! AXUIElement
            if let words = value(text) ?? string(text, kAXDescriptionAttribute) { return words }
        }
        guard let parent = attribute(element, kAXParentAttribute).map({ $0 as! AXUIElement }) else { return "" }
        let siblings = children(parent)
        guard let index = siblings.firstIndex(where: { CFEqual($0, element) }), index > 0 else { return "" }
        let before = siblings[index - 1]
        guard string(before, kAXRoleAttribute) == "AXStaticText" else { return "" }
        return value(before) ?? string(before, kAXDescriptionAttribute) ?? ""
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
        // A context menu the driver holds open (`longPress`): its items are
        // all the screen has, as an open menu's are.
        if let menu = heldMenu as? NSMenu {
            var screen = AccessibilityScreen()
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                screen.add(item, role: "button", label: item.title, kind: "NSMenuItem", disabled: !item.isEnabled)
            }
            screen.name()
            return screen
        }
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
        // The alert is the topmost presentation (an alert over a sheet).
        screen.presented = presented.enumerated().map { index, presentation in
            (style: alert && index == presented.count - 1 ? "alert" : presentation.0, title: presentation.1, message: presentation.2)
        }
        for node in nodes {
            screen.add(node.element, role: node.role, label: node.label, value: node.value, id: node.id,
                       options: node.options, kind: node.kind, params: node.params, disabled: node.disabled)
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

    /// The element's AXUIElement; for what isn't one (a held menu's item,
    /// an NSMenuItem), the application's, which takes none of the actions
    /// asked of it.
    private func element(_ element: AccessibilityScreen.Element) -> AXUIElement {
        Self.ax(element.object) ?? AXUIElementCreateApplication(getpid())
    }

    private static func ax(_ object: AnyObject) -> AXUIElement? {
        CFGetTypeID(object as CFTypeRef) == AXUIElementGetTypeID() ? (object as! AXUIElement) : nil
    }

    /// Runs `body` here, on the main thread, where AppKit answers it.
    private func off<T>(_ body: () -> T) async -> T {
        body()
    }

    /// A row is selected (as a click selects it, which opens a sidebar's
    /// destination); anything else is pressed.
    func activate(_ target: AccessibilityScreen.Element) async -> Bool {
        // A held context menu's item: chosen, as a click on it chooses it.
        if let item = target.object as? NSMenuItem, let menu = item.menu {
            heldMenu = nil
            menu.performActionForItem(at: menu.index(of: item))
            return true
        }
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

    func swipeAction(_ screen: AccessibilityScreen, _ target: String, _ action: String) async -> String? {
        "a row's swipe actions aren't driven on the Mac yet"
    }

    /// A long press, as the Mac gives what it does: the view's context menu
    /// (a `.contextMenu`, which a secondary click opens), held open by the
    /// driver, its items then the screen's buttons until one is tapped or
    /// another command comes, as Isomer's driver holds one; else the mouse
    /// held down on it a second and let go (an `onLongPressGesture`). The
    /// menu is the one the view gives a secondary click (`menu(for:)`), not
    /// shown: AppKit tracks a shown menu in a loop of its own on the main
    /// thread, where this driver's work waits until the menu closes. A press
    /// that changes nothing on the screen took no long press: an error, as
    /// Isomer's driver's.
    func longPress(_ screen: AccessibilityScreen, _ target: String) async -> String? {
        guard let element = screen.element(target) ?? screen.textTarget(target) else { return "no view \(target)" }
        let name = element.name.isEmpty ? target : element.name
        // Pressed where its words are: a list's row of texts spans the
        // list's width, the view taking the press only its text's.
        let words = element.kind == "AXRow" ? screen.texts.last(where: { $0.text == target || $0.text == element.label }) : nil
        guard let spot = Self.ax(words?.object ?? element.object), let (window, location) = Self.place(spot) else {
            return "\(name) isn't in a window"
        }
        if let menu = Self.contextMenu(window, location) {
            heldMenu = menu
            return nil
        }
        await press(window, location, seconds: 1)
        return await settle(after: screen).wire != screen.wire ? nil : "\(name) takes no long press"
    }

    /// An element's window and its middle there (AppKit's coordinates).
    private static func place(_ element: AXUIElement) -> (NSWindow, NSPoint)? {
        let frame = AXClient.frame(element)
        // Accessibility's coordinates have their origin at the top left of
        // the main screen, AppKit's at its bottom left.
        guard !frame.isEmpty, let main = NSScreen.screens.first else { return nil }
        let point = NSPoint(x: frame.midX, y: main.frame.maxY - frame.midY)
        guard let window = NSApp.windows.last(where: { $0.isVisible && $0.frame.contains(point) }) ?? NSApp.mainWindow
        else { return nil }
        return (window, window.convertPoint(fromScreen: point))
    }

    /// The context menu a secondary click at `location` would open: the
    /// first the views under it give, innermost first, with items.
    private static func contextMenu(_ window: NSWindow, _ location: NSPoint) -> NSMenu? {
        guard let content = window.contentView,
              let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return nil }
        var view = content.hitTest(location)
        while let current = view {
            if let menu = current.menu(for: event) {
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
                if menu.items.contains(where: { !$0.isSeparatorItem && !$0.isHidden }) { return menu }
            }
            if current === content { break }
            view = current.superview
        }
        return nil
    }

    /// The mouse pressed at `location` in `window` for `seconds` and let go:
    /// events of the app's own queue (nothing moves on the Mac's screen),
    /// the app made active and the window key first, as a person's click
    /// would, so the press isn't taken as the click that activates it.
    private func press(_ window: NSWindow, _ location: NSPoint, seconds: Double) async {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 200_000_000)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseDown ? 1 : 0)
        }
        if let down = event(.leftMouseDown) { NSApp.postEvent(down, atStart: false) }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
    }

    /// The toolbar's Back, as a navigation stack gives it.
    func back(_ screen: AccessibilityScreen) async -> Bool {
        guard let button = screen.elements.last(where: {
            $0.role == "button" && ($0.label == "Back" || $0.id == "Back" || $0.id == "BackButton")
        })
        else {
            // Nothing pushed in what is presented: back closes it, as
            // Isomer's driver's back closes a sheet at its first page.
            if let top = screen.presented.last, top.style == "sheet" { return await dismiss(screen) }
            return false
        }
        return await activate(button)
    }

    /// Moves SwiftUI's scene phase as the Mac moves it: background when the
    /// app is hidden (NSApp.hide, as ⌘H), inactive when its windows are in
    /// the Dock (miniaturized), active when shown and frontmost again. The
    /// app's deactivation alone (another app frontmost) leaves it active.
    func scene(_ phase: String) async -> String? {
        let windows = NSApp.windows.filter { $0.isMiniaturized || $0.isVisible }
        switch phase {
        case "background":
            NSApp.hide(nil)
        case "inactive":
            if NSApp.isHidden { NSApp.unhide(nil) }
            for window in windows where !window.isMiniaturized && window.canBecomeMain { window.miniaturize(nil) }
        case "active":
            if NSApp.isHidden { NSApp.unhide(nil) }
            for window in windows where window.isMiniaturized { window.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
        default:
            return "no scene phase \(phase)"
        }
        // The window's animation into the Dock or out of it.
        try? await Task.sleep(nanoseconds: 600_000_000)
        return nil
    }

    /// An alert's cancel button (the one Escape presses, whatever its title:
    /// a confirmation dialog's `.cancel` role), else a sheet's Cancel, Done
    /// or OK; else the sheet's cancel, as Escape gives it.
    func dismiss(_ screen: AccessibilityScreen) async -> Bool {
        if let alert = NSApp.windows.last(where: {
            $0.isVisible && String(describing: Swift.type(of: $0)).contains("Alert")
        }) {
            func escape(_ view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.keyEquivalent == "\u{1b}", button.isEnabled { return button }
                for subview in view.subviews { if let found = escape(subview) { return found } }
                return nil
            }
            if let cancel = alert.contentView.flatMap(escape) {
                cancel.performClick(nil)
                return true
            }
        }
        if let cancel = screen.elements.last(where: { $0.role == "button" && ["Cancel", "Done", "OK"].contains($0.label) }) {
            return await activate(cancel)
        }
        let pid = getpid()
        let cancelled = await off {
            let app = AXUIElementCreateApplication(pid)
            guard let window = AXClient.attribute(app, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }),
                  let sheet = AXClient.children(window).last(where: { AXClient.string($0, kAXRoleAttribute) == "AXSheet" })
            else { return false }
            return AXClient.perform(sheet, kAXCancelAction)
        }
        // A sheet with nothing to close it but the key a person presses:
        // Escape's cancel, sent to it (SwiftUI closes its sheets on it).
        guard let sheet = NSApp.windows.last(where: { $0.isVisible && $0.sheetParent != nil }) else { return cancelled }
        func closed() async -> Bool {
            for _ in 0..<20 {
                if !sheet.isVisible || sheet.sheetParent == nil { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }
        if cancelled, await closed() { return true }
        sheet.makeKey()
        let escape = #selector(NSResponder.cancelOperation(_:))
        if sheet.firstResponder?.tryToPerform(escape, with: nil) == true || sheet.tryToPerform(escape, with: nil) {
            if await closed() { return true }
        }
        return false
    }
}

/// An AXUIElement carried to the thread that asks it (CF objects are safe
/// to use from any thread).
private struct UncheckedAX: @unchecked Sendable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}
#endif
