// The Apple driver on iOS (AccessibilityDriver.swift): the screen read from
// UIKit's accessibility containers (SwiftUI's hosting views vend their
// elements once the app's accessibility is on), used through them as
// VoiceOver uses them, and, where an element takes no activation, through
// what a tap at its activation point reaches (a list's cell, a control).

#if canImport(UIKit)
import Foundation
import IsomerWire
import UIKit

extension AccessibilityScreen {
    /// The screen's bounds, set as each screen is read.
    @MainActor static var screenBounds: CGRect?

    /// The screen under `roots` (the key window, or what it presents).
    @MainActor
    init(roots: [NSObject], presented: [(style: String, title: String, message: String)]) {
        self.presented = presented
        for root in roots { visit(root) }
        recoverIdentifiers(roots)
        name()
    }

    /// An element UIKit stands in for a view with (a navigation bar's button,
    /// as SwiftUI's toolbar makes it) may lack the identifier the view itself
    /// carries: it takes it from an identified view of the same label where
    /// the element is, so a toolbar item is found by its identifier as by
    /// its label.
    @MainActor
    private mutating func recoverIdentifiers(_ roots: [NSObject]) {
        guard elements.contains(where: { $0.id == nil }) else { return }
        var identified: [(id: String, label: String, frame: CGRect)] = []
        func walk(_ view: UIView) {
            if let id = view.accessibilityIdentifier, !id.isEmpty, view.isAccessibilityElement {
                identified.append((id, view.accessibilityLabel ?? "", view.accessibilityFrame))
            }
            for subview in view.subviews where !subview.isHidden { walk(subview) }
        }
        for root in roots { if let view = root as? UIView { walk(view) } }
        guard !identified.isEmpty else { return }
        for index in elements.indices where elements[index].id == nil {
            guard let object = elements[index].object as? NSObject else { continue }
            let frame = object.accessibilityFrame
            let center = CGPoint(x: frame.midX, y: frame.midY)
            if let match = identified.first(where: { $0.label == elements[index].label && $0.frame.contains(center) }) {
                elements[index].id = match.id
            }
        }
    }

    /// A list's or a table's row that holds only texts is a button to a
    /// person (it opens, it selects), as Isomer's renderers give it: its
    /// texts, then a button labelled with them.
    @MainActor
    private mutating func visit(_ object: NSObject) {
        guard object is UICollectionViewCell || object is UITableViewCell else {
            visitObject(object)
            return
        }
        let elementCount = elements.count
        let textCount = texts.count
        visitObject(object)
        if elements.count == elementCount, texts.count > textCount {
            let row = texts[textCount...]
            let first = row.first!
            add(first.object, role: "button", label: row.map(\.text).joined(separator: " "), kind: first.kind,
                params: first.params)
        }
    }

    @MainActor
    private mutating func visitObject(_ object: NSObject) {
        if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return }
        if object.accessibilityElementsHidden { return }
        // A page a navigation slid away (beside the window) is not on the
        // screen; what is below or above the fold of a page that scrolls is,
        // as a person scrolls to it.
        if let view = object as? UIView, let window = view.window {
            let frame = view.convert(view.bounds, to: window)
            if !frame.isEmpty, frame.maxX <= window.bounds.minX || frame.minX >= window.bounds.maxX { return }
        } else if object.isAccessibilityElement, let screen = Self.screenBounds {
            let frame = object.accessibilityFrame
            if !frame.isEmpty, frame.maxX <= screen.minX || frame.minX >= screen.maxX { return }
        }
        if object.isAccessibilityElement {
            let traits = object.accessibilityTraits
            let label = object.accessibilityLabel ?? ""
            let value = object.accessibilityValue
            let id = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier.flatMap { $0.isEmpty ? nil : $0 }
            let kind = String(describing: Swift.type(of: object))
            let frame = object.accessibilityFrame
            var params = ["traits": String(traits.rawValue),
                          "frame": "\(Int(frame.minX)) \(Int(frame.minY)) \(Int(frame.width)) \(Int(frame.height))"]
            if let hint = object.accessibilityHint { params["hint"] = hint }
            func add(_ role: String, _ label: String, _ value: String?, _ options: [String] = []) {
                self.add(object, role: role, label: label, value: value, id: id, options: options, kind: kind, params: params)
            }
            if object is UITextField || (object as? UITextView)?.isEditable == true || traits.contains(.searchField) {
                add("textField", label.isEmpty ? (object as? UITextField)?.placeholder ?? "" : label,
                    (object as? UITextField)?.text ?? (object as? UITextView)?.text ?? value)
            } else if let control = object as? UISegmentedControl {
                add("segmented", label, value, (0..<control.numberOfSegments).map { control.titleForSegment(at: $0) ?? "" })
            } else if #available(iOS 17, *), traits.contains(.toggleButton) {
                add("toggle", label, value)
            } else if object is UISwitch {
                add("toggle", label, value)
            } else if traits.contains(.adjustable) {
                add("slider", label, value)
            } else if traits.contains(.button) || traits.contains(.link) || traits.contains(.keyboardKey)
                        || kind.contains("ContextMenuCell") {
                // A menu's item is a button, whatever its traits.
                add("button", label, value)
            } else if !label.isEmpty {
                add("text", label, nil)
            }
            return
        }
        if let elements = object.accessibilityElements as? [NSObject], !elements.isEmpty {
            for element in elements { visit(element) }
            return
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for index in 0..<count {
                if let element = object.accessibilityElement(at: index) as? NSObject { visit(element) }
            }
            return
        }
        if let view = object as? UIView {
            for subview in view.subviews { visit(subview) }
        }
    }
}

extension AccessibilityDriver {
    static let platform = "iOS"

    /// iOS vends SwiftUI's accessibility elements only once accessibility is
    /// on for the app.
    static func enableAccessibility() {
        guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(library, "_AXSApplicationAccessibilitySetEnabled") else { return }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(symbol, to: SetEnabled.self)(1)
    }

    /// The key window's topmost presented view controller (an alert, a
    /// sheet), or the window itself: what can be used.
    func roots() -> ([NSObject], [(style: String, title: String, message: String)]) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !$0.isHidden }
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return ([], []) }
        AccessibilityScreen.screenBounds = window.screen.bounds
        info.width = Double(window.bounds.width)
        info.height = Double(window.bounds.height)
        // An open menu (a Menu, a picker's menu): UIKit's context menu, a view
        // of the window's own beside its content, which the window's
        // accessibility containers don't lead to. While it's open it is all
        // that can be used, as a person sees it.
        // A menu that has closed can leave its container behind a moment,
        // empty: only one still showing its menu counts.
        func showsMenu(_ view: UIView) -> Bool {
            if view.isHidden || view.alpha < 0.01 { return false }
            if String(describing: Swift.type(of: view)).contains("ContextMenuListView") { return view.window != nil }
            return view.subviews.contains(where: showsMenu)
        }
        if let menu = window.subviews.last(where: {
            String(describing: Swift.type(of: $0)).contains("ContextMenuContainer") && showsMenu($0)
        }) {
            return ([menu], [])
        }
        var presented: [(style: String, title: String, message: String)] = []
        var top = window.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed {
            if let alert = next as? UIAlertController {
                presented.append(("alert", alert.title ?? "", alert.message ?? ""))
            } else {
                presented.append((next.modalPresentationStyle == .popover ? "popover" : "sheet", next.title ?? "", ""))
            }
            top = next
        }
        if !presented.isEmpty, let view = top?.view { return ([view], presented) }
        return ([window], presented)
    }

    func screen() async -> AccessibilityScreen {
        let (roots, presented) = roots()
        return AccessibilityScreen(roots: roots, presented: presented)
    }

    /// Whether a view controller is mid-transition (pushed, popped,
    /// presented or dismissed).
    func transitioning() -> Bool {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        func busy(_ controller: UIViewController?) -> Bool {
            guard let controller else { return false }
            if controller.transitionCoordinator != nil || controller.isBeingPresented || controller.isBeingDismissed { return true }
            return controller.children.contains(where: busy) || busy(controller.presentedViewController)
        }
        return windows.contains { busy($0.rootViewController) }
    }

    /// What `find` finds on the screen, or, as a person would scroll to it,
    /// once the screen's scroll view has paged to it (from its top down): a
    /// phone lists only the rows on screen.
    func reveal(_ screen: AccessibilityScreen, _ find: (AccessibilityScreen) -> AccessibilityScreen.Element?) async
        -> AccessibilityScreen.Element? {
        if let found = find(screen) { return found }
        guard let scroll = Self.scrollViews(roots().0).max(by: { $0.bounds.height < $1.bounds.height }) else {
            // No scroll view to page: as VoiceOver scrolls, a page at a time
            // through what is on screen, down, then back up.
            var current = screen
            for direction in [UIAccessibilityScrollDirection.down, .up] {
                for _ in 0..<40 {
                    guard Self.scroll(current, direction) else { break }
                    current = await settle(timeout: 1)
                    if let found = find(current) { return found }
                }
            }
            return nil
        }
        let top = -scroll.adjustedContentInset.top
        let bottom = max(top, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        var offset = top
        while offset <= bottom {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
            if let found = find(await settle(timeout: 1)) { return found }
            if offset == bottom { break }
            offset = min(bottom, offset + scroll.bounds.height * 0.8)
        }
        return nil
    }

    /// A page's scroll, asked of what is on screen (an element, then its
    /// containers, until one scrolls).
    static func scroll(_ screen: AccessibilityScreen, _ direction: UIAccessibilityScrollDirection) -> Bool {
        let objects = screen.texts.map(\.object) + screen.elements.map(\.object)
        for object in objects.reversed() {
            var current = object as? NSObject
            while let candidate = current {
                if candidate.accessibilityScroll(direction) { return true }
                current = (candidate as? UIView)?.superview ?? (candidate as? UIAccessibilityElement)?.accessibilityContainer as? NSObject
            }
        }
        return false
    }

    /// The scroll views on the screen that scroll vertically, outermost first.
    static func scrollViews(_ roots: [NSObject]) -> [UIScrollView] {
        var found: [UIScrollView] = []
        func visit(_ view: UIView) {
            if view.isHidden { return }
            if let scroll = view as? UIScrollView, scroll.isScrollEnabled,
               scroll.contentSize.height > scroll.bounds.height + 1 { found.append(scroll) }
            for subview in view.subviews { visit(subview) }
        }
        for root in roots { if let view = root as? UIView { visit(view) } }
        return found
    }

    // MARK: Actions

    /// As VoiceOver activates it; else what a tap at its activation point
    /// reaches: a list's or a table's cell (selected, its delegate told, as
    /// a tap selects it), or a control (its touch-up action).
    func activate(_ element: AccessibilityScreen.Element) async -> Bool {
        guard let object = element.object as? NSObject else { return false }
        if object.accessibilityActivate() { return true }
        if let control = object as? UIControl {
            control.sendActions(for: .touchUpInside)
            return true
        }
        guard let window = roots().0.compactMap({ ($0 as? UIWindow) ?? ($0 as? UIView)?.window }).first else { return false }
        let point = window.convert(object.accessibilityActivationPoint, from: window.screen.coordinateSpace)
        var view = window.hitTest(point, with: nil)
        while let current = view {
            if let cell = current as? UICollectionViewCell, let collection = Self.enclosing(UICollectionView.self, cell),
               let path = collection.indexPath(for: cell) {
                let should = collection.delegate?.collectionView?(collection, shouldSelectItemAt: path)
                if should == false {
                    // A list whose cells don't select (a menu's) takes a tap
                    // as its primary action, as UIKit's menus do.
                    guard let delegate = collection.delegate else { return false }
                    if delegate.responds(to: #selector(UICollectionViewDelegate.collectionView(_:performPrimaryActionForItemAt:))) {
                        delegate.collectionView?(collection, performPrimaryActionForItemAt: path)
                        return true
                    }
                    guard String(describing: Swift.type(of: delegate)).contains("ContextMenu") else { return false }
                    return Self.performMenuItem(element.label, list: delegate as AnyObject, in: window)
                }
                collection.selectItem(at: path, animated: false, scrollPosition: [])
                collection.delegate?.collectionView?(collection, didSelectItemAt: path)
                return true
            }
            if let cell = current as? UITableViewCell, let table = Self.enclosing(UITableView.self, cell),
               let path = table.indexPath(for: cell) {
                table.selectRow(at: path, animated: false, scrollPosition: .none)
                table.delegate?.tableView?(table, didSelectRowAt: path)
                return true
            }
            if let control = current as? UIControl, control.isEnabled {
                control.sendActions(for: .touchUpInside)
                return true
            }
            view = current.superview
        }
        return false
    }

    static func enclosing<V: UIView>(_ kind: V.Type, _ view: UIView) -> V? {
        var current = view.superview
        while let candidate = current {
            if let found = candidate as? V { return found }
            current = candidate.superview
        }
        return nil
    }

    func type(_ text: String, into element: AccessibilityScreen.Element) async -> Bool {
        if let field = element.object as? UITextField {
            field.becomeFirstResponder()
            if let all = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument) {
                field.replace(all, withText: text)
            } else {
                field.text = text
            }
            field.sendActions(for: .editingChanged)
            return true
        }
        if let view = element.object as? UITextView {
            view.becomeFirstResponder()
            if let all = view.textRange(from: view.beginningOfDocument, to: view.endOfDocument) {
                view.replace(all, withText: text)
            } else {
                view.text = text
            }
            return true
        }
        return false
    }

    func set(_ element: AccessibilityScreen.Element, _ value: String) async -> String? {
        guard let object = element.object as? NSObject else { return "\(element.name) can't be set" }
        switch element.role {
        case "toggle":
            let on = ["1", "on", "true"].contains(value.lowercased())
            let isOn = ["1", "on", "true"].contains((object.accessibilityValue ?? "").lowercased())
            if on != isOn, !(await activate(element)) { return "\(element.name) didn't toggle" }
            return nil
        case "slider", "stepper":
            // An adjustable element moves a step at a time: up or down until
            // its value reads as asked.
            for _ in 0..<100 {
                let current = object.accessibilityValue ?? ""
                if current == value { return nil }
                guard let have = Double(current.filter { $0.isNumber || $0 == "." || $0 == "-" }),
                      let want = Double(value) else { return "\(element.name)'s value \(current) isn't a number" }
                if have < want { object.accessibilityIncrement() } else { object.accessibilityDecrement() }
                if object.accessibilityValue == current { return "\(element.name) stopped at \(current)" }
            }
            return "\(element.name) didn't reach \(value)"
        case "textField":
            return await type(value, into: element) ? nil : "\(element.name) takes no text"
        default:
            return "\(element.name) can't be set"
        }
    }

    /// A UIKit menu's item, chosen: its menu cells take no activation and no
    /// selection (UIKit's menu acts on a touch alone), so the item's action
    /// is found in the menu the list shows, by title, and performed, and the
    /// menu dismissed, as a touch on it does. UIKit's own SPI
    /// (`displayedMenu`, `performWithSender:target:`): the driver is linked
    /// into debug and test builds only (docs/driver_in_apps.md).
    @MainActor
    static func performMenuItem(_ title: String, list: AnyObject, in window: UIWindow) -> Bool {
        guard let object = list as? NSObject, object.responds(to: NSSelectorFromString("displayedMenu")),
              let menu = object.value(forKey: "displayedMenu") as? UIMenu
        else { return false }
        func find(_ menu: UIMenu) -> UIAction? {
            for child in menu.children {
                if let action = child as? UIAction, action.title == title { return action }
                if let submenu = child as? UIMenu, let found = find(submenu) { return found }
            }
            return nil
        }
        guard let action = find(menu) else { return false }
        let perform = NSSelectorFromString("performWithSender:target:")
        guard action.responds(to: perform) else { return false }
        action.perform(perform, with: nil, with: nil)
        // Closed, as a touch on the item closes it.
        func dismiss(_ view: UIView) {
            for interaction in view.interactions {
                (interaction as? UIContextMenuInteraction)?.dismissMenu()
            }
            for subview in view.subviews { dismiss(subview) }
        }
        dismiss(window)
        return true
    }

    func select(_ element: AccessibilityScreen.Element, _ option: String) async -> String? {
        if let control = element.object as? UISegmentedControl {
            guard let index = (0..<control.numberOfSegments).first(where: { control.titleForSegment(at: $0) == option }) else {
                return "\(element.name) has no option \(option)"
            }
            control.selectedSegmentIndex = index
            control.sendActions(for: .valueChanged)
            return nil
        }
        // A menu: opened, then its option activated.
        guard await activate(element) else { return "\(element.name) didn't open" }
        let menu = await settle(after: true)
        guard let choice = menu.elements.last(where: { $0.role == "button" && $0.label == option }) else {
            return "\(element.name) has no option \(option)"
        }
        return await activate(choice) ? nil : "\(option) didn't take the tap"
    }

    func swipe(_ screen: AccessibilityScreen, _ target: String, _ direction: String) async -> String? {
        let scroll: UIAccessibilityScrollDirection
        switch direction {
        case "up": scroll = .down
        case "down": scroll = .up
        case "left": scroll = .right
        case "right": scroll = .left
        default: return "swipe up, down, left or right"
        }
        let objects = target.isEmpty ? screen.elements.map(\.object) : screen.element(target).map { [$0.object] } ?? []
        for object in objects.reversed() {
            var current = object as? NSObject
            while let candidate = current {
                if candidate.accessibilityScroll(scroll) { return nil }
                current = (candidate as? UIView)?.superview ?? (candidate as? UIAccessibilityElement)?.accessibilityContainer as? NSObject
            }
        }
        return "nothing scrolls \(direction)"
    }

    func back(_ screen: AccessibilityScreen) async -> Bool {
        guard let window = roots().0.compactMap({ ($0 as? UIWindow) ?? ($0 as? UIView)?.window }).first else { return false }
        func top(_ controller: UIViewController?) -> UINavigationController? {
            guard let controller else { return nil }
            for child in controller.children.reversed() {
                if let found = top(child) { return found }
            }
            if let navigation = controller as? UINavigationController, navigation.viewControllers.count > 1 { return navigation }
            return nil
        }
        if let navigation = top(window.rootViewController) {
            navigation.popViewController(animated: false)
            return true
        }
        return false
    }

    func dismiss(_ screen: AccessibilityScreen) async -> Bool {
        guard let view = roots().0.first as? UIView else { return false }
        return view.accessibilityPerformEscape()
    }
}
#endif
