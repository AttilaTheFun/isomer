// The driver of an app on Apple's SwiftUI (iOS, macOS), built in with
// --@isomer//drive:headful: the app's screen read through its accessibility
// tree, in process, and used through it (activate, press, select, a text
// field's value, increment, escape), as headless.proto's commands drive an
// Isomer app through its runtime (drive/driver). The same names on the
// screen (`button-3`, `text-2`), the same answers, so one test drives either.
//
// When the app is launched with ISO_DRIVER=<ws://… a hub or a test's own>
// (simctl's SIMCTL_CHILD_ISO_DRIVER, a Mac app's environment), it dials out
// once it runs (iso_apple_drive_attach.c starts it) and is driven over that
// connection (session_service.proto's Driver.Attach), through Foundation's
// URLSession. ISO_DRIVER_TOKEN is the hub's token, if it wants one;
// ISO_DRIVER_NAME the name the hub knows the app by.
//
// Each platform reads the tree its way (an extension of the driver a file):
// iOS walks UIKit's accessibility containers (UIKitAccessibility.swift) once
// SwiftUI's elements are on (libAccessibility's
// _AXSApplicationAccessibilitySetEnabled, as accessibility snapshot tests
// do); the Mac asks its own process as an accessibility client would
// (AXClientAccessibility.swift, AXUIElement off the main thread, which
// answers). A build for driving, never a release.

import Foundation
import IsomerServing
import IsomerWire

/// One frame as the accessibility tree has it.
struct AccessibilityScreen {
    struct Element {
        var role: String
        var label: String
        var id: String?
        var value: String?
        var options: [String] = []
        var name = ""
        /// The element itself: a view or an accessibility element (iOS), an
        /// AXUIElement (the Mac).
        var object: AnyObject
        /// What the tree has it as (its class, its accessibility role).
        var kind = ""
        /// What `inspect` shows beside it: its frame, traits, role, hint.
        var params: [String: String] = [:]
    }

    struct Text {
        var text: String
        var object: AnyObject
        var kind = ""
        var params: [String: String] = [:]
    }

    var texts: [Text] = []
    var elements: [Element] = []
    var presented: [(style: String, title: String, message: String)] = []

    /// The names: each element's role and its place among that role's.
    mutating func name() {
        var counts: [String: Int] = [:]
        for index in elements.indices {
            let role = elements[index].role
            counts[role, default: 0] += 1
            elements[index].name = "\(role)-\(counts[role]!)"
        }
    }

    mutating func add(_ object: AnyObject, role: String, label: String, value: String? = nil, id: String? = nil,
                      options: [String] = [], kind: String = "", params: [String: String] = [:]) {
        if role == "text" {
            if !label.isEmpty { texts.append(Text(text: label, object: object, kind: kind, params: params)) }
            return
        }
        elements.append(Element(role: role, label: label, id: id, value: value, options: options, object: object,
                                kind: kind, params: params))
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

    /// The element a target names: its name on the screen, its identifier,
    /// its label exactly, then the last whose label holds it.
    func element(_ target: String, roles: Set<String>? = nil) -> Element? {
        if let (role, number) = Self.parseName(target), role.lowercased() != "text" {
            guard let element = elements.filter({ $0.role.lowercased() == role.lowercased() }).dropFirst(number - 1).first
            else { return nil }
            return roles == nil || roles!.contains(element.role) ? element : nil
        }
        let candidates = elements.filter { roles == nil || roles!.contains($0.role) }
        return candidates.first { $0.id == target }
            ?? candidates.last { $0.label == target }
            ?? candidates.last { $0.label.contains(target) }
    }

    /// `tap` on a text (`text-<n>`, or a text's exact words): the button
    /// holding it, else the text's own element (iOS gives a List's rows as
    /// texts that take activation).
    func textTarget(_ target: String) -> Element? {
        let found: Text?
        if let (role, number) = Self.parseName(target), role.lowercased() == "text" {
            found = number <= texts.count ? texts[number - 1] : nil
        } else {
            found = texts.last { $0.text == target }
        }
        guard let found else { return nil }
        if let button = elements.last(where: { $0.role == "button" && $0.label.contains(found.text) }) { return button }
        return Element(role: "text", label: found.text, object: found.object, kind: found.kind, params: found.params)
    }

    var wire: Wire_Screen {
        var screen = Wire_Screen()
        screen.texts = texts.map(\.text)
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

    /// `inspect`: an element or a text as the accessibility tree has it.
    func inspection(_ target: String) -> Wire_Inspection? {
        var inspection = Wire_Inspection()
        if let (role, number) = Self.parseName(target), role.lowercased() == "text" {
            guard number <= texts.count else { return nil }
            let text = texts[number - 1]
            inspection.name = "text-\(number)"
            inspection.role = "text"
            inspection.label = text.text
            inspection.kind = text.kind
            inspection.params = text.params
            return inspection
        }
        guard let element = element(target) else { return nil }
        inspection.name = element.name
        inspection.role = element.role
        inspection.label = element.label
        if let id = element.id { inspection.id = id }
        if let value = element.value { inspection.value = value }
        inspection.options = element.options
        inspection.kind = element.kind
        inspection.params = element.params
        // What it takes, as Isomer's driver names it.
        switch element.role {
        case "textField", "slider", "stepper", "picker", "segmented": inspection.actions = ["edit"]
        case "button", "toggle": inspection.actions = ["tap"]
        default: inspection.actions = []
        }
        return inspection
    }
}

/// Drives the app running in this process through its accessibility tree.
/// Each platform's file gives it `screen()`, `transitioning()`, `reveal`, and
/// the actions (`activate`, `type`, `set`, `select`, `swipe`, `back`,
/// `dismiss`).
@MainActor
final class AccessibilityDriver {
    var info: Wire_Info

    init() {
        let bundle = Bundle.main
        var info = Wire_Info()
        info.name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
        info.bundleIdentifier = bundle.bundleIdentifier ?? ""
        info.version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        info.platform = Self.platform
        info.renderer = "SwiftUI"
        self.info = info
        Self.enableAccessibility()
    }

    /// Frames until the screen holds still (five readings alike, or the
    /// timeout): animations, transitions and the app's tasks run meanwhile.
    func settle(timeout: Double = 3, after action: Bool = false) async -> AccessibilityScreen {
        // What an action starts (a navigation's push, a sheet) begins on the
        // next turns of the run loop: a moment before reading the screen.
        if action { try? await Task.sleep(nanoseconds: 300_000_000) }
        let deadline = Date().addingTimeInterval(timeout)
        // A navigation's push or pop, a sheet's coming or going: the screen
        // is the one it ends on.
        while Date() < deadline, transitioning() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        var current = await screen()
        var last = current.wire
        var still = 0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            current = await screen()
            let reading = current.wire
            if reading == last {
                still += 1
                if still >= 5 { break }
            } else {
                still = 0
                last = reading
            }
        }
        return current
    }

    func handle(_ command: Wire_Command) async -> Wire_Answer {
        var error: String?
        let target = command.target
        let before = await settle()
        switch command.cmd {
        case "ls", "info", "quit":
            break
        case "inspect":
            if let inspection = before.inspection(target) {
                var answer = Wire_Answer()
                answer.ok = true
                answer.inspection = inspection
                answer.screen = before.wire
                return answer
            }
            error = "no element \(target)"
        case "tap":
            // A button (or toggle) by its name, label or identifier, scrolled
            // to if need be; else a text of exactly those words.
            var element = await reveal(before, { $0.element(target, roles: ["button", "toggle"]) })
            if element == nil { element = await reveal(before, { $0.textTarget(target) }) }
            if let element {
                if !(await activate(element)) { error = "\(element.name.isEmpty ? target : element.name) didn't take the tap" }
            } else {
                error = "no button \(target)"
            }
        case "type":
            if let element = await reveal(before, { $0.element(target, roles: ["textField"]) }) {
                if !(await type(command.text, into: element)) { error = "\(element.name) takes no text" }
            } else {
                error = "no text field \(target)"
            }
        case "set":
            if let element = await reveal(before, { $0.element(target) }) {
                error = await set(element, command.value)
            } else {
                error = "no control \(target)"
            }
        case "select":
            if let element = await reveal(before, { $0.element(target, roles: ["picker", "segmented", "button"]) }) {
                error = await select(element, command.value)
            } else {
                error = "no picker \(target)"
            }
        case "swipe":
            error = await swipe(before, target, command.direction)
        case "back":
            if !(await back(before)) { error = "nothing to go back from" }
        case "dismiss":
            if before.presented.isEmpty {
                error = "nothing presented"
            } else if !(await dismiss(before)) {
                error = "\(before.presented.last!.style) didn't close"
            }
        case "wait":
            let text = command.text
            let deadline = Date().addingTimeInterval(command.timeout > 0 ? command.timeout : 5)
            var shown = false
            while Date() < deadline {
                let frame = await settle(timeout: 0.5)
                if frame.texts.contains(where: { $0.text.contains(text) })
                    || frame.elements.contains(where: { $0.label.contains(text) || ($0.value ?? "").contains(text) }) {
                    shown = true
                    break
                }
            }
            if !shown { error = "\(text) didn't show" }
        default:
            error = "unknown command: \(command.cmd)"
        }
        var answer = Wire_Answer()
        answer.ok = error == nil
        if let error { answer.error = error }
        let after = await settle(after: !["ls", "info", "quit", "wait"].contains(command.cmd))
        answer.screen = after.wire
        if command.cmd == "info" { answer.info = info }
        return answer
    }

    /// Dials out to `connection` (a hub, a test) and is driven over it until
    /// the call ends.
    func dialOut(_ connection: any IsomerConnection, context: IsomerCallContext) async throws {
        let call = try await connection.attach(context: context)
        _ = await screen()
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

/// Started once the app runs (iso_apple_drive_attach.c): the app's own
/// driver, for a test bundle hosted in it (IsomerLocalServer, synchronous);
/// and, when ISO_DRIVER names where to dial, attached there too.
@_cdecl("iso_apple_drive_attach")
public func isoAppleDriveAttach() {
    let environment = ProcessInfo.processInfo.environment
    let driver = MainActor.assumeIsolated {
        let driver = AccessibilityDriver()
        IsomerLocalServer.register(IsomerLocalServer { await driver.handle($0) })
        return driver
    }
    guard let address = environment["ISO_DRIVER"], let url = URL(string: address) else { return }
    MainActor.assumeIsolated {
        Task { @MainActor in
            do {
                try await driver.dialOut(
                    IsomerURLSessionConnection(url),
                    context: .authorized(environment["ISO_DRIVER_TOKEN"],
                                         metadata: environment["ISO_DRIVER_NAME"].map { ["iso-target": $0] } ?? [:])
                )
            } catch {
                print("[iso] driver at \(address): \(error)")
            }
        }
    }
}
