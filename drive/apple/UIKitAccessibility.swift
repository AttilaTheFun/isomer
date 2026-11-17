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
    /// The window the screen is read in, and how accessibility's screen
    /// coordinates (an element's frame, its activation point) map into it,
    /// set as each screen is read (`AccessibilityDriver.toWindow`).
    @MainActor static var window: (bounds: CGRect, fromScreen: CGAffineTransform)?

    /// The screen under `roots` (the key window, or what it presents); an
    /// alert on top read from its controller too (`addAlert`).
    @MainActor
    init(roots: [NSObject], presented: [(style: String, title: String, message: String)], alert: UIAlertController? = nil) {
        self.presented = presented
        for root in roots { visit(root) }
        recoverIdentifiers(roots)
        if let alert { addAlert(alert) }
        name()
    }

    /// An alert's (or a confirmation dialog's) title and message, buttons
    /// and text fields, as Isomer's driver lists an alert's: what its
    /// view's accessibility gave (its action views, its fields), and what it
    /// didn't, from the controller itself (its actions, by title, enabled or
    /// not; its text fields), so an alert whose views give the walk nothing
    /// (as one of an app's did, listed with no buttons, its title alone) is
    /// listed and used all the same.
    @MainActor
    private mutating func addAlert(_ alert: UIAlertController) {
        for text in [alert.title, alert.message] {
            if let text, !text.isEmpty, !texts.contains(where: { $0.text == text }) {
                texts.append(Text(text: text, object: alert, kind: "UIAlertController"))
            }
        }
        for field in alert.textFields ?? [] where !elements.contains(where: { $0.object === field }) {
            add(field, role: "textField", label: field.placeholder ?? field.accessibilityLabel ?? "", value: field.text,
                kind: String(describing: Swift.type(of: field)))
        }
        for action in alert.actions {
            guard let title = action.title, !title.isEmpty,
                  !elements.contains(where: { $0.role == "button" && $0.label == title }) else { continue }
            add(action, role: "button", label: title, kind: "UIAlertAction",
                params: ["style": action.style == .cancel ? "cancel" : action.style == .destructive ? "destructive" : "default"],
                disabled: !action.isEnabled)
        }
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
    /// texts, then a button labelled with them, with the identifier its
    /// content carries (a `List(selection:)` row found by its content's
    /// identifier, as Isomer's driver finds it).
    @MainActor
    private mutating func visit(_ object: NSObject, depth: Int = 0) {
        guard object is UICollectionViewCell || object is UITableViewCell else {
            visitObject(object, depth: depth)
            return
        }
        let elementCount = elements.count
        let textCount = texts.count
        visitObject(object, depth: depth)
        if elements[elementCount...].allSatisfy({ $0.role == "staticText" }), texts.count > textCount {
            // The texts' identifiers are the row's: not elements of their own.
            elements.removeSubrange(elementCount...)
            let row = texts[textCount...]
            let first = row.first!
            add(first.object, role: "button", label: row.map(\.text).joined(separator: " "),
                id: row.first(where: { $0.id != nil })?.id, kind: first.kind, params: first.params)
        }
    }

    /// An element's accessibility identifier, however it carries it: a
    /// UIView adopts UIAccessibilityIdentification, but SwiftUI's own
    /// elements (the nodes a List's, a Form's rows and its controls are)
    /// answer `accessibilityIdentifier` without declaring the protocol, so a
    /// cast to it finds nothing where XCUITest, which asks the selector,
    /// finds them all.
    @MainActor
    static func identifier(_ object: NSObject) -> String? {
        let id: String?
        if let identified = object as? UIAccessibilityIdentification {
            id = identified.accessibilityIdentifier
        } else if object.responds(to: #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)) {
            id = object.value(forKey: "accessibilityIdentifier") as? String
        } else {
            id = nil
        }
        return id.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A text field's title where it has no accessibility label: a
    /// UITextField's placeholder; a UITextView's (SwiftUI's multi-line
    /// `TextField(_:text:axis:)`, which UIKit gives no placeholder of its
    /// own) what its accessibility says of its placeholder while it is
    /// empty, else the label it draws as one (kept, hidden, once there is
    /// text), else its identifier.
    @MainActor
    static func fieldTitle(_ object: NSObject) -> String? {
        if let field = object as? UITextField { return field.placeholder }
        let placeholder = NSSelectorFromString("accessibilityPlaceholderValue")
        if object.responds(to: placeholder), let text = object.value(forKey: "accessibilityPlaceholderValue") as? String,
           !text.isEmpty {
            return text
        }
        if let view = object as? UIView {
            func label(_ view: UIView) -> String? {
                for subview in view.subviews {
                    if let text = (subview as? UILabel)?.text, !text.isEmpty { return text }
                    if let text = label(subview) { return text }
                }
                return nil
            }
            if let text = label(view) { return text }
        }
        return identifier(object)
    }

    /// ISO_DRIVE_TRACE=1: each reading's walk printed, an object a line
    /// (its class, whether it is an element, its traits, label, identifier
    /// and frame), for finding what the tree holds where the driver lists
    /// nothing.
    static let tracing = ProcessInfo.processInfo.environment["ISO_DRIVE_TRACE"] == "1"

    @MainActor
    private mutating func visitObject(_ object: NSObject, depth: Int = 0) {
        if Self.tracing {
            let frame = object.accessibilityFrame
            print("[iso trace] \(String(repeating: "  ", count: depth))\(Swift.type(of: object))"
                + " element=\(object.isAccessibilityElement) traits=\(object.accessibilityTraits.rawValue)"
                + " label=\(object.accessibilityLabel ?? "-") id=\(Self.identifier(object) ?? "-")"
                + " children=\((object.accessibilityElements?.count).map(String.init) ?? "-")/\(object.accessibilityElementCount())"
                + " frame=\(AccessibilityScreen.describe(frame, separator: ","))")
        }
        if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return }
        if object.accessibilityElementsHidden { return }
        // A page a navigation slid away (beside the window) is not on the
        // screen; what is below or above the fold of a page that scrolls is,
        // as a person scrolls to it.
        if let view = object as? UIView, let window = view.window {
            let frame = view.convert(view.bounds, to: window)
            if !frame.isEmpty, frame.maxX <= window.bounds.minX || frame.minX >= window.bounds.maxX { return }
        } else if object.isAccessibilityElement, let window = Self.window {
            let frame = object.accessibilityFrame.applying(window.fromScreen)
            if !frame.isEmpty, frame.maxX <= window.bounds.minX || frame.minX >= window.bounds.maxX { return }
        }
        if object.isAccessibilityElement {
            let traits = object.accessibilityTraits
            let label = object.accessibilityLabel ?? ""
            let value = object.accessibilityValue
            let id = Self.identifier(object)
            let kind = String(describing: Swift.type(of: object))
            let frame = object.accessibilityFrame
            var params = ["traits": String(traits.rawValue),
                          "frame": AccessibilityScreen.describe(frame)]
            if let hint = object.accessibilityHint { params["hint"] = hint }
            let disabled = traits.contains(.notEnabled)
            func add(_ role: String, _ label: String, _ value: String?, _ options: [String] = []) {
                self.add(object, role: role, label: label, value: value, id: id, options: options, kind: kind, params: params,
                         disabled: disabled)
            }
            if object is UITextField || (object as? UITextView)?.isEditable == true || traits.contains(.searchField) {
                add("textField", label.isEmpty ? Self.fieldTitle(object) ?? "" : label,
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
            for element in elements { visit(element, depth: depth + 1) }
            return
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for index in 0..<count {
                if let element = object.accessibilityElement(at: index) as? NSObject { visit(element, depth: depth + 1) }
            }
            return
        }
        if let view = object as? UIView {
            for subview in view.subviews { visit(subview, depth: depth + 1) }
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
        // (And the scenes' phases followed from here on: `scene`.)
        ScenePhases.follow()
    }

    /// Accessibility's screen coordinates into `window`'s: the inverse of
    /// what UIKit maps the window's into them with, read from three points.
    /// They needn't be the window's turned only by the screen's own
    /// coordinate space: on an app that turns itself to landscape on an
    /// upright phone they are the device's, so a point converted from
    /// `UIScreen.coordinateSpace` missed the row it was meant for.
    static func fromScreen(_ window: UIWindow) -> CGAffineTransform {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let rect = UIAccessibility.convertToScreenCoordinates(CGRect(x: x, y: y, width: 0, height: 0), in: window)
            return rect.origin
        }
        let origin = point(0, 0), right = point(100, 0), down = point(0, 100)
        let toScreen = CGAffineTransform(a: (right.x - origin.x) / 100, b: (right.y - origin.y) / 100,
                                         c: (down.x - origin.x) / 100, d: (down.y - origin.y) / 100,
                                         tx: origin.x, ty: origin.y)
        return toScreen.inverted()
    }

    /// An interface orientation as headless.proto's Info names it.
    static func orientationName(_ orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait: "portrait"
        case .portraitUpsideDown: "portrait-upside-down"
        case .landscapeLeft: "landscape-left"
        case .landscapeRight: "landscape-right"
        default: ""
        }
    }

    /// The key window's topmost presented view controller (an alert, a
    /// sheet), or the window itself: what can be used.
    func roots() -> ([NSObject], [(style: String, title: String, message: String)]) {
        guard let window = Self.keyWindow() else { return ([], []) }
        AccessibilityScreen.window = (window.bounds, Self.fromScreen(window))
        info.width = Double(window.bounds.width)
        info.height = Double(window.bounds.height)
        info.orientation = window.windowScene.map { Self.orientationName($0.effectiveGeometry.interfaceOrientation) } ?? ""
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
        // ISO_DRIVE_ALERT_FROM_CONTROLLER=1: an alert read from its
        // controller alone (`addAlert`), as when its views can't be reached:
        // the driver probe's check of that path.
        if top is UIAlertController, Self.alertFromController { return ([], presented) }
        if !presented.isEmpty, let view = top?.view { return ([view], presented) }
        return ([window], presented)
    }

    func screen() async -> AccessibilityScreen {
        let (roots, presented) = roots()
        return AccessibilityScreen(roots: roots, presented: presented, alert: presented.last?.style == "alert" ? Self.topAlert() : nil)
    }

    static let alertFromController = ProcessInfo.processInfo.environment["ISO_DRIVE_ALERT_FROM_CONTROLLER"] == "1"

    /// The alert (or confirmation dialog) on top of the key window, if one is.
    static func topAlert() -> UIAlertController? {
        var top = keyWindow()?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top as? UIAlertController
    }

    /// An alert's action, chosen as its button's tap chooses it: the alert
    /// dismissed with it, its handler run (UIKit's `_dismissWithAction:`;
    /// else the handler run once the alert has gone, as UIKit runs it).
    static func perform(_ action: UIAlertAction) -> Bool {
        guard let alert = topAlert(), alert.actions.contains(where: { $0 === action }), action.isEnabled else { return false }
        let dismiss = NSSelectorFromString("_dismissWithAction:")
        if alert.responds(to: dismiss) {
            alert.perform(dismiss, with: action)
            return true
        }
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        let handler = action.responds(to: NSSelectorFromString("handler"))
            ? (action.value(forKey: "handler") as AnyObject?).map { unsafeBitCast($0, to: Handler.self) } : nil
        alert.presentingViewController?.dismiss(animated: true) { handler?(action) }
        return true
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
        if let action = element.object as? UIAlertAction { return Self.perform(action) }
        guard let object = element.object as? NSObject else { return false }
        if object.accessibilityActivate() { return true }
        if let control = object as? UIControl {
            control.sendActions(for: .touchUpInside)
            return true
        }
        guard let window = roots().0.compactMap({ ($0 as? UIWindow) ?? ($0 as? UIView)?.window }).first else { return false }
        let point = object.accessibilityActivationPoint.applying(Self.fromScreen(window))
        if let view = window.hitTest(point, with: nil), use(from: view, element, window) { return true }
        // Where the point reaches nothing that takes a tap: the view the
        // element belongs to (its accessibility containers, up to a view),
        // whatever the coordinates say.
        var container: NSObject? = object
        while let current = container, !(current is UIView) {
            let key = "accessibilityContainer"
            container = current.responds(to: NSSelectorFromString(key)) ? current.value(forKey: key) as? NSObject : nil
        }
        if let view = container as? UIView, view.window === window { return use(from: view, element, window) }
        return false
    }

    /// The tap on `element` that `view` (where it stands) or a view around
    /// it takes: a list's or a table's cell selected, a control's action.
    private func use(from view: UIView, _ element: AccessibilityScreen.Element, _ window: UIWindow) -> Bool {
        var view: UIView? = view
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
        let closed = await screen()
        guard await activate(element) else { return "\(element.name) didn't open" }
        let menu = await settle(after: closed)
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
        // What is presented on top (a sheet) first: its own navigation's
        // page goes back, as the sheet's bar's Back does, not the window's
        // under it.
        var presenting = window.rootViewController
        while let next = presenting?.presentedViewController, !next.isBeingDismissed { presenting = next }
        func top(_ controller: UIViewController?) -> UINavigationController? {
            guard let controller else { return nil }
            for child in controller.children.reversed() {
                if let found = top(child) { return found }
            }
            if let navigation = controller as? UINavigationController, navigation.viewControllers.count > 1 { return navigation }
            return nil
        }
        if let navigation = top(presenting) {
            navigation.popViewController(animated: false)
            return true
        }
        // Nothing pushed in what is presented: back closes it, as Isomer's
        // driver's back closes a sheet at its first page.
        if let presented = presenting, presented !== window.rootViewController, !(presented is UIAlertController) {
            return await dismiss(screen)
        }
        return false
    }

    /// A row's swipe action, by its title: SwiftUI gives a List row's
    /// `.swipeActions` to VoiceOver as the row's custom actions, performed
    /// here as VoiceOver performs them (on the element, or the cell it is in).
    func swipeAction(_ screen: AccessibilityScreen, _ target: String, _ action: String) async -> String? {
        guard let element = screen.element(target) ?? screen.textTarget(target), let object = element.object as? NSObject else {
            return "no row \(target)"
        }
        var current: NSObject? = object
        while let candidate = current {
            if let custom = candidate.accessibilityCustomActions?.first(where: { $0.name == action }) {
                if let handler = custom.actionHandler { return handler(custom) ? nil : "\(action) didn't take" }
                if let receiver = custom.target as? NSObject, receiver.responds(to: custom.selector) {
                    _ = receiver.perform(custom.selector, with: custom)
                    return nil
                }
            }
            current = (candidate as? UIView)?.superview ?? (candidate as? UIAccessibilityElement)?.accessibilityContainer as? NSObject
        }
        return "\(target) has no swipe action \(action)"
    }

    /// A long press, as a finger gives it: the view under the element's
    /// activation point touched, held (a second, past SwiftUI's half-second
    /// `onLongPressGesture` and the half-second a context menu waits for)
    /// and lifted, through UIKit's own touch delivery (`SyntheticTouch`), so
    /// the gesture recognizers that see a person's long press see this one:
    /// a `.contextMenu` opens (its items then the screen's buttons, as an
    /// open menu's are), an `onLongPressGesture` fires. Should the touches
    /// open nothing and the view have a context menu, its interaction
    /// presents it as the long press would. A press that changes nothing on
    /// the screen took no long press: an error, as Isomer's driver's.
    func longPress(_ screen: AccessibilityScreen, _ target: String) async -> String? {
        guard let element = await reveal(screen, { $0.element(target) ?? $0.textTarget(target) }),
              let object = element.object as? NSObject else { return "no view \(target)" }
        guard let window = Self.keyWindow() else { return "no window" }
        let point = object.accessibilityActivationPoint.applying(Self.fromScreen(window))
        let before = await self.screen()
        if let touch = SyntheticTouch(at: point, in: window) {
            touch.send(.began)
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                touch.send(.stationary)
            }
            touch.send(.ended)
            if await settle(after: before).wire != before.wire { return nil }
        }
        if Self.presentContextMenu(at: point, in: window), await settle(after: before).wire != before.wire { return nil }
        return "\(element.name.isEmpty ? target : element.name) takes no long press"
    }

    /// The context menu of the view at `point` (its own interaction's, or a
    /// list's cell's), presented as a long press there presents it: UIKit's
    /// SPI (`_presentMenuAtLocation:`), the driver being linked into debug
    /// and test builds only.
    static func presentContextMenu(at point: CGPoint, in window: UIWindow) -> Bool {
        var view = window.hitTest(point, with: nil)
        let present = NSSelectorFromString("_presentMenuAtLocation:")
        while let current = view {
            for case let interaction as UIContextMenuInteraction in current.interactions
            where interaction.responds(to: present) {
                typealias Present = @convention(c) (NSObject, Selector, CGPoint) -> Void
                let location = window.convert(point, to: interaction.view ?? current)
                unsafeBitCast(interaction.method(for: present), to: Present.self)(interaction, present, location)
                return true
            }
            view = current.superview
        }
        return false
    }

    /// Closes what is presented on top, as a person would: escape (what
    /// VoiceOver's two-finger scrub does: an alert's Cancel, a menu, a
    /// popover); else a sheet a person may swipe away, closed as the swipe
    /// closes it (its presentation controller's delegate asked and told, so
    /// SwiftUI's `isPresented` and `onDismiss` follow); else its own Cancel,
    /// Close or Done. Each tried until the presentation is gone.
    func dismiss(_ screen: AccessibilityScreen) async -> Bool {
        guard let window = Self.keyWindow() else { return false }
        var top: UIViewController? = window.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        guard let presented = top, presented !== window.rootViewController else {
            // An open menu, nothing presented: escape alone.
            return (roots().0.first as? UIView)?.accessibilityPerformEscape() ?? false
        }
        func closed() async -> Bool {
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if presented.presentingViewController == nil || presented.isBeingDismissed { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }
        if presented.view.accessibilityPerformEscape(), await closed() { return true }
        if !(presented is UIAlertController), let controller = presented.presentationController,
           !presented.isModalInPresentation,
           controller.delegate?.presentationControllerShouldDismiss?(controller) != false {
            let delegate = controller.delegate
            delegate?.presentationControllerWillDismiss?(controller)
            presented.presentingViewController?.dismiss(animated: true) {
                delegate?.presentationControllerDidDismiss?(controller)
            }
            if await closed() { return true }
        }
        let names = ["cancel", "close", "done"]
        for name in names {
            if let button = screen.elements.last(where: {
                $0.role == "button" && !$0.disabled && ($0.label.lowercased() == name || $0.id?.lowercased() == name)
            }), await activate(button), await closed() {
                return true
            }
        }
        return false
    }

    /// Moves SwiftUI's scene phase (`@Environment(\.scenePhase)`, its
    /// `.onChange`) as leaving the app and coming back does: SwiftUI's own
    /// scene delegate told, a step at a time, what UIKit tells it then
    /// (`sceneWillResignActive`, `sceneDidEnterBackground`,
    /// `sceneWillEnterForeground`, `sceneDidBecomeActive`), and UIKit's
    /// notifications of each step posted after it for what observes them.
    /// The app stays on screen and is still driven (a simulator's real trip
    /// to the home screen takes seconds and suspends the app). Posting the
    /// notifications alone moves nothing: SwiftUI's phase follows its
    /// delegate. Each step is from the phase SwiftUI was last told
    /// (`ScenePhases`: by iOS, or by the driver), so a phase it already
    /// has moves nothing, and one iOS left short of it is finished: a scene
    /// the launcher brought back from the home screen that iOS leaves
    /// inactive (as a simulator with no Simulator.app showing it does) is
    /// made active.
    func scene(_ phase: String) async -> String? {
        let order = ["background": 0, "inactive": 1, "active": 2]
        guard let wanted = order[phase] else { return "no scene phase \(phase)" }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard !scenes.isEmpty else { return "no scene" }
        let center = NotificationCenter.default
        let application = UIApplication.shared
        for scene in scenes {
            var current = ScenePhases.shared.phase(scene)
            while current != wanted {
                let delegate = scene.delegate
                switch (current, wanted > current) {
                case (2, false):
                    delegate?.sceneWillResignActive?(scene)
                    center.post(name: UIScene.willDeactivateNotification, object: scene)
                    center.post(name: UIApplication.willResignActiveNotification, object: application)
                    current = 1
                case (1, false):
                    delegate?.sceneDidEnterBackground?(scene)
                    center.post(name: UIScene.didEnterBackgroundNotification, object: scene)
                    center.post(name: UIApplication.didEnterBackgroundNotification, object: application)
                    current = 0
                case (0, true):
                    delegate?.sceneWillEnterForeground?(scene)
                    center.post(name: UIScene.willEnterForegroundNotification, object: scene)
                    center.post(name: UIApplication.willEnterForegroundNotification, object: application)
                    current = 1
                default:
                    delegate?.sceneDidBecomeActive?(scene)
                    center.post(name: UIScene.didActivateNotification, object: scene)
                    center.post(name: UIApplication.didBecomeActiveNotification, object: application)
                    current = 2
                }
                // A turn of the run loop between steps, as UIKit's come.
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return nil
    }

    /// The window the app is shown in: the key one, else the first.
    static func keyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !$0.isHidden }
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}

/// The phase each scene's delegate was last told, as SwiftUI's scene phase
/// follows it: from UIKit's notifications of each step, which iOS posts as
/// it moves the scene (the app sent home and brought back, another app
/// opened over it) and the driver after each step it tells the delegate
/// (`scene`). A scene not heard of since the driver started is as UIKit
/// has it. (UIKit's own activation state alone isn't SwiftUI's phase once
/// the driver has moved it, and a memo of what the driver last set goes
/// stale as soon as iOS moves the scene: then `scene(.active)` did nothing
/// for a scene iOS had left inactive on its way back.)
@MainActor
final class ScenePhases: NSObject {
    static let shared = ScenePhases()
    private var phases: [ObjectIdentifier: Int] = [:]

    override private init() {
        super.init()
        let center = NotificationCenter.default
        for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
                     UIScene.willEnterForegroundNotification, UIScene.didActivateNotification,
                     UIScene.didDisconnectNotification] {
            center.addObserver(self, selector: #selector(moved(_:)), name: name, object: nil)
        }
    }

    /// Follows the scenes from now on (the driver's start).
    static func follow() { _ = shared }

    func phase(_ scene: UIScene) -> Int {
        if let phase = phases[ObjectIdentifier(scene)] { return phase }
        switch scene.activationState {
        case .foregroundActive: return 2
        case .foregroundInactive: return 1
        default: return 0
        }
    }

    @objc private func moved(_ notification: Notification) {
        guard let scene = notification.object as? UIScene else { return }
        let key = ObjectIdentifier(scene)
        switch notification.name {
        case UIScene.willDeactivateNotification, UIScene.willEnterForegroundNotification: phases[key] = 1
        case UIScene.didEnterBackgroundNotification: phases[key] = 0
        case UIScene.didActivateNotification: phases[key] = 2
        default: phases[key] = nil
        }
    }
}

/// One finger on the screen, delivered as UIKit delivers a person's: a
/// UITouch on the view the point hits (SwiftUI's gesture container there,
/// iOS 18's hit test), in the application's touches event, with the
/// IOHIDEvent UIKit reads its digitizer data from, sent through
/// `UIApplication.sendEvent`. UIKit's and IOKit's SPI, as KIF's touches are
/// made (github.com/kif-framework/KIF, UITouch-KIFAdditions,
/// IOHIDEvent+KIF); nil where this iOS lacks any of it. In process, never
/// the device's own screen; the driver is linked into debug and test builds
/// only.
@MainActor
final class SyntheticTouch {
    private let touch: UITouch
    private let window: UIWindow
    private let point: CGPoint

    init?(at point: CGPoint, in window: UIWindow) {
        guard let hid = Self.hid else { return nil }
        let touch = UITouch()
        for name in ["setWindow:", "setView:", "setPhase:", "setTimestamp:", "setTapCount:",
                     "_setLocationInWindow:resetPrevious:", "_setHidEvent:"]
        where !touch.responds(to: NSSelectorFromString(name)) {
            return nil
        }
        self.touch = touch
        self.window = window
        self.point = point
        // The window first: setting it clears what else was set.
        touch.perform(NSSelectorFromString("setWindow:"), with: window)
        Self.call(touch, "setTapCount:", Int(1))
        Self.call(touch, "_setLocationInWindow:resetPrevious:", point, true)
        let view = Self.hitTest(window, point)
        touch.perform(NSSelectorFromString("setView:"), with: view)
        Self.call(touch, "setPhase:", UITouch.Phase.began.rawValue)
        if touch.responds(to: NSSelectorFromString("_setIsFirstTouchForView:")) {
            Self.call(touch, "_setIsFirstTouchForView:", true)
        }
        Self.call(touch, "setTimestamp:", ProcessInfo.processInfo.systemUptime)
        if touch.responds(to: NSSelectorFromString("setGestureView:")) {
            touch.perform(NSSelectorFromString("setGestureView:"), with: view)
        }
        touch.perform(NSSelectorFromString("_setHidEvent:"), with: hid.event(point, touching: true, moved: false))
    }

    /// The touch in `phase`, delivered.
    func send(_ phase: UITouch.Phase) {
        guard let hid = Self.hid,
              let event = UIApplication.shared.perform(NSSelectorFromString("_touchesEvent"))?.takeUnretainedValue() as? UIEvent
        else { return }
        Self.call(touch, "setTimestamp:", ProcessInfo.processInfo.systemUptime)
        Self.call(touch, "setPhase:", phase.rawValue)
        event.perform(NSSelectorFromString("_clearTouches"))
        event.perform(NSSelectorFromString("_setHIDEvent:"),
                      with: hid.event(point, touching: phase != .ended && phase != .cancelled, moved: phase == .moved))
        let add = NSSelectorFromString("_addTouch:forDelayedDelivery:")
        typealias Add = @convention(c) (NSObject, Selector, UITouch, Bool) -> Void
        unsafeBitCast(event.method(for: add), to: Add.self)(event, add, touch, false)
        UIApplication.shared.sendEvent(event)
    }

    /// The responder a touch at `point` goes to: the hit view, or what
    /// iOS 18's hit test with a context finds in it (SwiftUI's gesture
    /// containers, which a plain hit test passes over).
    private static func hitTest(_ window: UIWindow, _ point: CGPoint) -> NSObject? {
        let hit = window.hitTest(point, with: nil)
        let make = NSSelectorFromString("contextWithPoint:radius:")
        let test = NSSelectorFromString("_hitTestWithContext:")
        guard let contextClass = NSClassFromString("_UIHitTestContext") as? NSObject.Type,
              contextClass.responds(to: make), UIView.instancesRespond(to: test) else { return hit }
        typealias Make = @convention(c) (AnyClass, Selector, CGPoint, CGFloat) -> NSObject?
        let makeIMP = unsafeBitCast(contextClass.method(for: make), to: Make.self)
        guard let context = makeIMP(contextClass, make, point, 0) else { return hit }
        var view = hit
        while let current = view {
            if let found = current.perform(test, with: context)?.takeUnretainedValue() as? NSObject { return found }
            view = current.superview
        }
        return hit
    }

    private static func call(_ object: NSObject, _ name: String, _ value: Int) {
        let selector = NSSelectorFromString(name)
        typealias Set = @convention(c) (NSObject, Selector, Int) -> Void
        unsafeBitCast(object.method(for: selector), to: Set.self)(object, selector, value)
    }

    private static func call(_ object: NSObject, _ name: String, _ value: Bool) {
        let selector = NSSelectorFromString(name)
        typealias Set = @convention(c) (NSObject, Selector, Bool) -> Void
        unsafeBitCast(object.method(for: selector), to: Set.self)(object, selector, value)
    }

    private static func call(_ object: NSObject, _ name: String, _ value: Double) {
        let selector = NSSelectorFromString(name)
        typealias Set = @convention(c) (NSObject, Selector, Double) -> Void
        unsafeBitCast(object.method(for: selector), to: Set.self)(object, selector, value)
    }

    private static func call(_ object: NSObject, _ name: String, _ point: CGPoint, _ flag: Bool) {
        let selector = NSSelectorFromString(name)
        typealias Set = @convention(c) (NSObject, Selector, CGPoint, Bool) -> Void
        unsafeBitCast(object.method(for: selector), to: Set.self)(object, selector, point, flag)
    }

    /// IOKit's digitizer events, as a touch screen's: a hand, one finger.
    struct HID {
        typealias CreateHand = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32, Double, Double,
                                               Double, Double, Double, UInt8, UInt8, UInt32) -> UnsafeMutableRawPointer?
        typealias CreateFinger = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, Double, Double, Double, Double,
                                                 Double, Double, Double, Double, Double, Double, UInt8, UInt8,
                                                 UInt32) -> UnsafeMutableRawPointer?
        typealias SetInteger = @convention(c) (UnsafeMutableRawPointer, UInt32, Int32) -> Void
        typealias Append = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Void
        let hand: CreateHand
        let finger: CreateFinger
        let setInteger: SetInteger
        let append: Append

        /// kIOHIDEventFieldDigitizerIsDisplayIntegrated:
        /// IOHIDEventFieldBase(kIOHIDEventTypeDigitizer, 11) + 25.
        static let isDisplayIntegrated: UInt32 = (11 << 16) + 25

        /// The event (an IOHIDEventRef, a CF object) for a finger at `point`.
        func event(_ point: CGPoint, touching: Bool, moved: Bool) -> AnyObject? {
            let time = mach_absolute_time()
            // A hand (kIOHIDDigitizerTransducerTypeHand), touching
            // (kIOHIDDigitizerEventTouch).
            guard let hand = hand(nil, time, 3, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1, 0) else { return nil }
            setInteger(hand, Self.isDisplayIntegrated, 1)
            // Its finger: its position when it moves, else in range and
            // touching (or lifted).
            let mask: UInt32 = moved ? 4 : 1 | 2
            let down: UInt8 = touching ? 1 : 0
            if let finger = finger(nil, time, 1, 2, mask, Double(point.x), Double(point.y), 0, 0, 0, 5, 5, 1, 1, 1,
                                   down, down, 0) {
                setInteger(finger, Self.isDisplayIntegrated, 1)
                append(hand, finger)
                Unmanaged<AnyObject>.fromOpaque(finger).release()
            }
            return Unmanaged<AnyObject>.fromOpaque(hand).takeRetainedValue()
        }
    }

    static let hid: HID? = {
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        guard let hand = symbol("IOHIDEventCreateDigitizerEvent", HID.CreateHand.self),
              let finger = symbol("IOHIDEventCreateDigitizerFingerEventWithQuality", HID.CreateFinger.self),
              let setInteger = symbol("IOHIDEventSetIntegerValue", HID.SetInteger.self),
              let append = symbol("IOHIDEventAppendEvent", HID.Append.self)
        else { return nil }
        return HID(hand: hand, finger: finger, setInteger: setInteger, append: append)
    }()
}
#endif
