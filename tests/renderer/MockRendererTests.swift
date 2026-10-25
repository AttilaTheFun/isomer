// Exercises the pluggable-renderer contract with a mock: the runtime hands
// every frame's canonical tree to whatever `Renderer.bind(_:)` installed —
// it cannot ask what kind of renderer it is. The mock records the trees; the
// checks assert the render cadence, the canonical (semantic-chrome) shape,
// and the serialized form. A plain executable (no XCTest), exits non-zero
// on failure; wrapped as a sh_test.

import FlatBuffers
import Foundation
import SwiftUI  // IsomerCore, aliased (BUILD.bazel)
import Observation
import IsomerSwiftUI

struct ToggleScreen: View {
    var body: some View {
        VStack {
            Text("Settings")
            Toggle("Enabled", isOn: Binding(get: { flag }, set: { flag = $0 }))
        }
    }
}

nonisolated(unsafe) var flag = false
nonisolated(unsafe) var picked: String? = nil

/// What a view's `.task` did, counted from the tasks themselves.
final class TaskLog: @unchecked Sendable {
    private let lock = NSLock()
    private var startedCount = 0
    private var cancelledCount = 0
    func start() { lock.lock(); startedCount += 1; lock.unlock() }
    func cancel() { lock.lock(); cancelledCount += 1; lock.unlock() }
    var started: Int { lock.lock(); defer { lock.unlock() }; return startedCount }
    var cancelled: Int { lock.lock(); defer { lock.unlock() }; return cancelledCount }
}

let taskLog = TaskLog()
nonisolated(unsafe) var taskShown = true
nonisolated(unsafe) var taskID = 1

/// A view with a task that runs until it is cancelled, as a `for await`
/// loop over a stream does.
struct TaskScreen: View {
    var body: some View {
        VStack {
            Text("Tasks")
            if taskShown {
                Text("Watching").task(id: taskID) {
                    taskLog.start()
                    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
                    taskLog.cancel()
                }
            }
        }
    }
}

/// `.task(id:)` cancels its task when the id changes and when the view
/// disappears, as SwiftUI does.
@MainActor
func checkTaskCancellation(_ mock: MockRenderer) {
    // The tasks run on the main actor, as the view they belong to does: let
    // the main run loop turn so they do.
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
    // What a component-system renderer does with each tree: serialize it,
    // then fire the lifecycle the encoder collected.
    @MainActor
    func frame() {
        Runtime.shared.setNeedsRender()
        Runtime.shared.renderFrame()
        guard let tree = mock.lastTree else { return }
        let encoder = FlatTreeEncoder()
        _ = encoder.encode(root: tree)
        Runtime.shared.fireTreeAppearances(encoder.appearances, disappearances: encoder.disappearances)
    }
    Runtime.shared.installRootView { TaskScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    frame(); settle()
    expect(taskLog.started == 1 && taskLog.cancelled == 0, "a task starts when its view appears (started \(taskLog.started), cancelled \(taskLog.cancelled))")
    taskID = 2
    frame(); frame(); settle()
    expect(taskLog.started == 2 && taskLog.cancelled == 1, "a changed id cancels the task and starts another (started \(taskLog.started), cancelled \(taskLog.cancelled))")
    taskShown = false
    frame(); settle()
    expect(taskLog.started == 2 && taskLog.cancelled == 2, "the task is cancelled when its view disappears (started \(taskLog.started), cancelled \(taskLog.cancelled))")
    taskShown = true
    frame(); settle()
    expect(taskLog.started == 3, "the task starts again when the view comes back (started \(taskLog.started))")
    taskShown = false
    frame(); settle()
}

nonisolated(unsafe) var changeShown = true
nonisolated(unsafe) var changeValue = 0
nonisolated(unsafe) var changesSeen: [String] = []

/// A view with an `.onChange` that can leave the tree and come back, as a
/// pushed screen does.
struct ChangeScreen: View {
    var body: some View {
        VStack {
            Text("Changes")
            if changeShown {
                Text("Watching").onChange(of: changeValue) { old, new in changesSeen.append("\(old)→\(new)") }
            }
        }
    }
}

/// `.onChange` reports a change while its view is in the tree; a view that
/// left and came back starts afresh, as SwiftUI's does, and reports no
/// change against the value its predecessor last saw (Visor's chat, pushed
/// again, took its transcript for one let go of while on screen).
@MainActor
func checkOnChangeAfterReappearing(_ mock: MockRenderer) {
    @MainActor
    func frame() {
        Runtime.shared.setNeedsRender()
        Runtime.shared.renderFrame()
        guard let tree = mock.lastTree else { return }
        let encoder = FlatTreeEncoder()
        _ = encoder.encode(root: tree)
        Runtime.shared.fireTreeAppearances(encoder.appearances, disappearances: encoder.disappearances)
    }
    Runtime.shared.installRootView { ChangeScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    frame()
    expect(changesSeen.isEmpty, "no change on first appearance (\(changesSeen))")
    changeValue = 1
    frame()
    expect(changesSeen == ["0→1"], "a change while shown is reported once (\(changesSeen))")
    changeShown = false
    frame()
    changeValue = 2
    frame()
    changeShown = true
    frame()
    expect(changesSeen == ["0→1"], "a view back in the tree reports no change against the value it saw before it left (\(changesSeen))")
    changeValue = 3
    frame()
    expect(changesSeen == ["0→1", "2→3"], "and reports the next change from the value it came back with (\(changesSeen))")
}

nonisolated(unsafe) var stateMacroMade = 0
nonisolated(unsafe) var stateMacroDidSet: [Int] = []
nonisolated(unsafe) var stateMacroRebuilds = 0

func makeStateMacroValue() -> Int {
    stateMacroMade += 1
    return 7
}

/// `@State` is SwiftUI's macro (Macros.swift): a private state with an
/// initial value is a LazyState, its value made once; an observer runs
/// around the write.
struct StateMacroScreen: View {
    @State private var made = makeStateMacroValue()
    @State var count = 0 {
        didSet { stateMacroDidSet.append(count) }
    }

    var body: some View {
        Text("made \(made) count \(count)")
            .onAppear { count += 1 }
    }
}

struct StateMacroRoot: View {
    var body: some View {
        // Read, so a frame builds this body (and so a new StateMacroScreen) again.
        let _ = stateMacroRebuilds
        VStack { StateMacroScreen() }
    }
}

@MainActor
func checkStateMacro(_ mock: MockRenderer) {
    @MainActor
    func frame() {
        stateMacroRebuilds += 1
        Runtime.shared.setNeedsRender()
        Runtime.shared.renderFrame()
        guard let tree = mock.lastTree else { return }
        let encoder = FlatTreeEncoder()
        _ = encoder.encode(root: tree)
        Runtime.shared.fireTreeAppearances(encoder.appearances, disappearances: encoder.disappearances)
    }
    Runtime.shared.installRootView { StateMacroRoot() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    frame()
    frame()
    frame()
    #if compiler(>=6.4)
    // (The property wrapper, before 6.4, makes it with each view value.)
    expect(stateMacroMade == 1, "a private @State's initial value is made once, however often its view is made (\(stateMacroMade))")
    #endif
    expect(stateMacroDidSet == [1], "didSet runs after the write, with the new value (\(stateMacroDidSet))")
    expect(findTextInTree(mock.lastTree!, "made 7 count 1"), "the view reads both states")
}

/// An alert with a dismissive action, as Visor's "Sign In to Claude" has.
struct RoleAlertScreen: View {
    var body: some View {
        Text("Behind").alert("Sign In", isPresented: .constant(true)) {
            Button("Open Sign-In Page") {}
            Button("Later", role: .cancel) {}
            Button("Remove", role: .destructive) {}
        } message: {
            Text("A session needs signing in.")
        }
    }
}

/// Every value of a param with the key, in tree order.
func allParams(_ node: IsoFlat_Node, key: String) -> [String] {
    var out = node.params.filter { $0.key == key }.compactMap(\.value)
    for child in node.ch { out += allParams(child, key: key) }
    return out
}

/// A button's role travels by its plain name ("cancel", "destructive"),
/// what the hosts read: Compose orders an alert's actions by it, the Apple
/// tree view gives its buttons the role, React styles a destructive one.
@MainActor
func checkButtonRoles(_ mock: MockRenderer) {
    Runtime.shared.installRootView { RoleAlertScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    guard let tree = mock.lastTree else { return expect(false, "an alert renders") }
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: tree))
    let root = getRoot(byteBuffer: &buffer) as IsoFlat_Node
    let roles = allParams(root, key: "role")
    expect(roles == ["cancel", "destructive"], "the alert's buttons carry their roles by name (\(roles))")
}

/// A sheet's bar as Visor's question sheet has it: Skip, and Send disabled
/// until something is answered.
struct DisabledBarScreen: View {
    var answered = false

    var body: some View {
        NavigationStack {
            Text("Which way?")
                .navigationTitle("Question")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Skip") {} }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") {}.disabled(!answered)
                    }
                }
        }
    }
}

/// A disabled bar item says so (params "leadingDisabled"/"trailingDisabled",
/// per item), as the hosts draw the bar from its items' titles alone and
/// would show it enabled otherwise; with none disabled, nothing is added.
@MainActor
func checkDisabledBarItems(_ mock: MockRenderer) {
    func params(answered: Bool) -> (leading: [String], trailing: [String]) {
        Runtime.shared.installRootView { DisabledBarScreen(answered: answered) }
        Runtime.shared.start(host: StubHost(), width: 320, height: 480)
        Runtime.shared.setNeedsRender()
        Runtime.shared.renderFrame()
        guard let tree = mock.lastTree else { return ([], []) }
        var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: tree))
        let root = getRoot(byteBuffer: &buffer) as IsoFlat_Node
        return (allParams(root, key: "leadingDisabled"), allParams(root, key: "trailingDisabled"))
    }
    let waiting = params(answered: false)
    expect(waiting.trailing == ["1"], "Send, disabled, is marked so (\(waiting.trailing))")
    expect(waiting.leading.allSatisfy { $0 != "1" }, "Skip is not (\(waiting.leading))")
    let ready = params(answered: true)
    expect(ready.trailing.allSatisfy { $0.isEmpty } && ready.leading.allSatisfy { $0.isEmpty },
           "with nothing disabled the lists are empty (\(ready.leading), \(ready.trailing))")
}

/// Pickers in and out of a Form's rows, as Visor's New Session has its
/// agent's: one in a section's row, one above the form, and one in a sheet
/// presented from a row.
struct FormPickerScreen: View {
    @State private var agent = 0
    @State private var mode = 0
    var body: some View {
        VStack {
            Picker("Outside", selection: $mode) { Text("One").tag(0); Text("Two").tag(1) }
                .pickerStyle(.segmented)
            Form {
                Section {
                    Picker("Agent", selection: $agent) { Text("Claude Code").tag(0); Text("Codex").tag(1) }
                        .pickerStyle(.menu)
                    Text("Row")
                        .sheet(isPresented: .constant(true)) {
                            Picker("In sheet", selection: $mode) { Text("One").tag(0); Text("Two").tag(1) }
                        }
                }
            }
        }
    }
}

/// A picker in a Form's row is marked `formRow` (the web and Compose then
/// draw its title beside its value, a segmented one across the row, as
/// SwiftUI does there); one outside a form, or in a sheet presented from a
/// row, is not.
@MainActor
func checkPickerInFormRow(_ mock: MockRenderer) {
    Runtime.shared.installRootView { FormPickerScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 760)
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    guard let tree = mock.lastTree else { expect(false, "a tree"); return }
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: tree))
    let root = getRoot(byteBuffer: &buffer) as IsoFlat_Node
    var marks: [String: String] = [:]
    func walk(_ node: IsoFlat_Node) {
        if node.view == "picker" {
            let title = node.params.first { $0.key == "title" }?.value ?? ""
            marks[title] = node.params.first { $0.key == "formRow" }?.value ?? ""
        }
        node.ch.forEach(walk)
    }
    walk(root)
    expect(marks["Agent"] == "1", "the row's picker is marked (\(marks))")
    expect(marks["Outside"] == "", "the one above the form is not (\(marks))")
    expect(marks["In sheet"] == "", "nor the one in a sheet presented from a row (\(marks))")
}

/// Value-based navigation, as Releases' tabs use it: a stack bound to a
/// path of routes, links that push a value, and the destination for the
/// routes' type.
enum ValueRoute: Hashable { case detail(Int) }

@Observable final class ValueNavModel {
    var path: [ValueRoute]
    init(path: [ValueRoute] = []) { self.path = path }
}

struct ValueNavScreen: View {
    @Bindable var model: ValueNavModel
    var body: some View {
        NavigationStack(path: $model.path) {
            VStack {
                NavigationLink("Open 7", value: ValueRoute.detail(7))
            }
            .navigationDestination(for: ValueRoute.self) { route in
                switch route {
                case .detail(let number): ValueDetail(number: number)
                }
            }
        }
    }
}

/// A pushed screen with state of its own, as Releases' build page has
/// (its Install button shows what it is doing).
struct ValueDetail: View {
    let number: Int
    @State private var pressed = false
    var body: some View {
        VStack {
            Text("Detail \(number)")
            Button(pressed ? "Pressed" : "Press") { pressed = true }
        }
    }
}

/// A link with a value pushes it onto the bound path and its destination
/// shows; Back takes it off the path; the app setting the path shows its
/// screen; and an app that starts on a path shows its screen at once (the
/// root built once, out of sight, for the destination it declares).
@MainActor
func checkValueNavigation(_ mock: MockRenderer) {
    let model = ValueNavModel()
    Runtime.shared.installRootView { ValueNavScreen(model: model) }
    Runtime.shared.start(host: StubHost(), width: 390, height: 760)
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "Open 7") && !findTextInTree(mock.lastTree!, "Detail 7"), "the root shows first")
    let encoder = FlatTreeEncoder()
    _ = encoder.encode(root: mock.lastTree!)
    guard let tap = encoder.handlers.keys.filter({ $0.hasSuffix(".tap") }).sorted().first else {
        expect(false, "the value link is a tap target")
        return
    }
    Runtime.shared.installTreeHandlers(encoder.handlers)
    Runtime.shared.hostViewEvent(id: tap, value: "")
    Runtime.shared.renderFrame()
    expect(model.path == [.detail(7)], "the link put its value on the path (\(model.path))")
    expect(findTextInTree(mock.lastTree!, "Detail 7"), "the destination for the value shows")
    // The pushed screen's own state: its button pressed, it shows so.
    let pushed = FlatTreeEncoder()
    _ = pushed.encode(root: mock.lastTree!)
    if let press = pushed.handlers.keys.filter({ $0.hasSuffix(".tap") }).sorted().first {
        Runtime.shared.installTreeHandlers(pushed.handlers)
        Runtime.shared.hostViewEvent(id: press, value: "")
        Runtime.shared.renderFrame()
        expect(findTextInTree(mock.lastTree!, "Pressed"), "a pushed screen's state changes show")
    } else {
        expect(false, "the pushed screen's button is a tap target")
    }
    expect(Runtime.shared.handleBackButton(), "Back is taken")
    Runtime.shared.renderFrame()
    expect(model.path.isEmpty, "Back took the value off the path (\(model.path))")
    expect(findTextInTree(mock.lastTree!, "Open 7"), "the root shows again")
    model.path = [.detail(3)]
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "Detail 3"), "the app setting the path shows its screen")

    let started = ValueNavModel(path: [.detail(5)])
    Runtime.shared.installRootView { ValueNavScreen(model: started) }
    Runtime.shared.start(host: StubHost(), width: 390, height: 760)
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "Detail 5"), "an app started on a path shows its screen")
}

/// A List's sections with footers, as Releases' build page has them (the
/// footer says why an install did not go through).
struct ListFooterScreen: View {
    var body: some View {
        List {
            Section {
                Text("First row")
            } header: {
                Text("Heading")
            } footer: {
                Text("Footer words")
            }
            Section {
                Text("Second row")
            }
        }
    }
}

/// A List's section footer is built, after its rows, as a cell of its own
/// ("footer" on hosts that draw their own lists).
@MainActor
func checkListSectionFooter(_ mock: MockRenderer) {
    Runtime.shared.installRootView { ListFooterScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 760)
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    guard let tree = mock.lastTree else { expect(false, "a tree"); return }
    expect(findTextInTree(tree, "Footer words"), "the section's footer is built")
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: tree))
    let root = getRoot(byteBuffer: &buffer) as IsoFlat_Node
    var order: [String] = []
    func walk(_ node: IsoFlat_Node) {
        if let cell = node.params.first(where: { $0.key == "cell" })?.value { order.append(cell) }
        node.ch.forEach(walk)
    }
    walk(root)
    expect(order.contains("footer"), "a footer cell (\(order))")
    if let footer = order.firstIndex(of: "footer"), let firstRow = order.firstIndex(of: "row") {
        expect(firstRow < footer, "the footer after its section's row (\(order))")
    }
}

/// A menu floated above its box by its top guide, as AgentUI's composer
/// floats its suggestions: `.overlay(alignment: .topLeading) { menu
/// .alignmentGuide(.top) { $0[.bottom] + 8 } }`.
struct GuidedOverlayScreen: View {
    var body: some View {
        Color.blue.frame(width: 200, height: 50)
            .overlay(alignment: .topLeading) {
                Text("Menu").alignmentGuide(.top) { $0[.bottom] + 8 }
            }
    }
}

/// The guide moves the menu by its default top (0) less the value computed
/// (its height and 8) once its size is measured, hidden until then; a size
/// the host reports before the frame that registers the reader is kept.
@MainActor
func checkAlignmentGuideInOverlay(_ mock: MockRenderer) {
    Runtime.shared.installRootView { GuidedOverlayScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 760)
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    // One encoder across frames, as a host's renderer keeps (its cache of
    // flattened subtrees with them).
    let encoder = FlatTreeEncoder()
    func flat() -> IsoFlat_Node? {
        guard let tree = mock.lastTree else { return nil }
        var buffer = ByteBuffer(bytes: encoder.encode(root: tree))
        return getRoot(byteBuffer: &buffer) as IsoFlat_Node
    }
    func find(_ node: IsoFlat_Node, _ match: (IsoFlat_Node) -> Bool) -> IsoFlat_Node? {
        if match(node) { return node }
        for index in 0..<node.ch.count { if let found = find(node.ch[index], match) { return found } }
        return nil
    }
    guard let before = flat(), let reader = find(before, { node in node.params.contains { $0.key == "geo" } }),
          let id = reader.params.first(where: { $0.key == "geo" })?.value else {
        expect(false, "the guided menu has a geometry reader")
        return
    }
    expect(find(before, { ($0.offsetY ?? 0) != 0 }) == nil, "no shift before the menu is measured")
    Runtime.shared.hostViewEvent(id: id, value: "60x20@0,0")
    // A reader's content is built as the tree is encoded (as a host's frame
    // encodes it): its state written there shows in the frame after.
    var after: IsoFlat_Node?
    for round in 0..<4 {
        Runtime.shared.renderFrame()
        after = flat()
        print("  guide round \(round): offsetY \(String(describing: after.flatMap { find($0, { $0.offsetY != nil }) }?.offsetY))")
    }
    guard let after else { expect(false, "a tree after the measurement"); return }
    let shifted = find(after, { $0.offsetY != nil })
    expect(shifted?.offsetY == -28, "the menu moved up by its height and 8 (\(String(describing: shifted?.offsetY)))")
    expect(shifted?.params.contains { $0.key == "float" && $0.value == "1" } == true,
           "moved out of its overlay, it floats above the screen's chrome")

    // In a stack a guide moves its view within the stack: it does not float.
    Runtime.shared.installRootView {
        VStack(alignment: .leading) {
            Text("One")
            Text("Two").alignmentGuide(.leading) { $0[.trailing] }
        }
    }
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    if let stack = flat() {
        expect(find(stack, { node in node.params.contains { $0.key == "float" } }) == nil, "a guided view in a stack does not float")
    }
}

/// The floating probe's screen (examples' shared/floating_probe_application),
/// in a navigation stack: builds and encodes.
struct FloatingProbeLike: View {
    @State private var picked = "none"
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 44)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            Button("/compact") { picked = "/compact" }.padding(.horizontal, 12).padding(.vertical, 10)
                            Button("/goal") { picked = "/goal" }.padding(.horizontal, 12).padding(.vertical, 10)
                        }
                        .frame(width: 200, alignment: .leading)
                        .background(Color.yellow.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
                        .alignmentGuide(.top) { $0[.bottom] + 6 }
                    }
                Text("picked=\(picked)")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("Floating Probe")
        }
    }
}

@MainActor
func checkFloatingProbeBuilds(_ mock: MockRenderer) {
    Runtime.shared.installRootView { FloatingProbeLike() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 760)
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    expect(mock.lastTree != nil, "the floating probe builds")
    if let tree = mock.lastTree { _ = FlatTreeEncoder().encode(root: tree) }
}

/// A screen with its inspector open, as Visor's chat has the session's.
struct InspectorScreen: View {
    var body: some View {
        Text("Chat").inspector(isPresented: .constant(true)) { Text("Details") }
    }
}

/// The inspector is a column where there is room for one (wide and tall
/// enough: an iPad, a desktop window) and a sheet elsewhere, a phone in
/// landscape included (wide, but short).
@MainActor
func checkInspectorPlacement(_ mock: MockRenderer) {
    func presented(width: Double, height: Double) -> Bool {
        Runtime.shared.installRootView { InspectorScreen() }
        Runtime.shared.start(host: StubHost(), width: width, height: height)
        Runtime.shared.setNeedsRender()
        Runtime.shared.renderFrame()
        guard let tree = mock.lastTree else { return false }
        var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: tree))
        let root = getRoot(byteBuffer: &buffer) as IsoFlat_Node
        func sheet(_ node: IsoFlat_Node) -> Bool { node.kind == .presentation || node.ch.contains(where: sheet) }
        return sheet(root)
    }
    expect(!presented(width: 1024, height: 768), "an iPad's inspector is a column")
    expect(presented(width: 760, height: 390), "a phone's in landscape is a sheet")
    expect(presented(width: 390, height: 760), "and in portrait")
}

/// A sheet whose stack's toolbar puts it away with `dismiss`, as Visor's
/// question sheet does with Skip and Send.
struct DismissSheetScreen: View {
    @State private var shown = true
    var body: some View {
        Text(shown ? "Shown" : "Gone").sheet(isPresented: $shown) { DismissingSheet() }
    }
}

struct DismissingSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Text("In the sheet")
                .navigationTitle("Question")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Skip") { dismiss() } } }
        }
    }
}

/// `dismiss` called from a sheet's toolbar puts the sheet away.
@MainActor
func checkDismissFromSheetToolbar(_ mock: MockRenderer) {
    Runtime.shared.installRootView { DismissSheetScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 760)
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    let handlers = FlatTreeEncoder()
    var buffer = ByteBuffer(bytes: handlers.encode(root: mock.lastTree!))
    let root = getRoot(byteBuffer: &buffer) as IsoFlat_Node
    func bar(_ node: IsoFlat_Node) -> IsoFlat_Node? {
        if node.view == "navstack", node.params.contains(where: { $0.key == "leading" && $0.value == "Skip" }) { return node }
        for child in node.ch { if let found = bar(child) { return found } }
        return nil
    }
    guard let stack = bar(root), let edit = stack.edit else { return expect(false, "the sheet's bar has Skip") }
    Runtime.shared.installTreeHandlers(handlers.handlers)
    Runtime.shared.hostViewEvent(id: edit, value: "leading:0")
    Runtime.shared.renderFrame()
    var after = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
    func sheet(_ node: IsoFlat_Node) -> Bool { node.kind == .presentation || node.ch.contains(where: sheet) }
    expect(!sheet(getRoot(byteBuffer: &after) as IsoFlat_Node), "Skip's dismiss() put the sheet away")
    expect(findTextInTree(mock.lastTree!, "Gone"), "and the screen under it knows")

}

/// A selectable list whose row carries its tag behind row-action modifiers,
/// as apps write it: the tag must still make the row a selection target.
struct RowScreen: View {
    struct Project: Identifiable { var id: String; var names: [String] }
    let projects = [Project(id: "p", names: ["Alpha", "Beta"])]

    var body: some View {
        List(selection: Binding(get: { picked }, set: { picked = $0 })) {
            // The section behind an app's own view, as apps factor it.
            ComputerSection(projects: projects)
        }
    }
}

struct ComputerSection: View {
    let projects: [RowScreen.Project]

    var body: some View {
            Section {
                ForEach(projects) { project in
                    HStack { Text(project.id); Spacer(); Button("compose") {} }
                    ForEach(project.names, id: \.self) { name in
                        Label(name, systemImage: "circle")
                            .tag(name)
                            .swipeActions(edge: .trailing) { Button("Archive") {} }
                            .contextMenu { Button("Rename", systemImage: "pencil") {}; Button("Archive") {} }
                    }
                }
                Button("New Project") {}
            } header: {
                HStack { Text("Computer") }
            }
    }
}

/// A chat-like list of identified rows, each tappable.
struct ThreadScreen: View {
    struct Message: Identifiable { var id: String; var text: String }
    var body: some View {
        List {
            ForEach(thread) { message in
                Text(message.text).onTapGesture {}
            }
        }
    }
}

nonisolated(unsafe) var thread: [ThreadScreen.Message] = (0..<40).map { .init(id: "m\($0)", text: "Message \($0)") }

/// Op counts in a `Patch`: reorders (and the nodes they insert), subtree
/// replaces and attribute updates.
func patchStats(_ bytes: [UInt8]) -> (reorders: Int, inserts: Int, replaces: Int, attrs: Int) {
    var buffer = ByteBuffer(bytes: bytes)
    let patch = getRoot(byteBuffer: &buffer) as IsoFlat_Patch
    var stats = (reorders: 0, inserts: 0, replaces: 0, attrs: 0)
    for index in 0..<patch.ops.count {
        let op = patch.ops[index]
        if op.order.count > 0 { stats.reorders += 1; stats.inserts += op.inserts.count }
        else if op.attrsOnly { stats.attrs += 1 }
        else { stats.replaces += 1 }
    }
    return stats
}

/// Rows keep their identity through inserts, appends and removals: each
/// ships as the rows that changed, not the list, and a row's tap handler id
/// holds while rows move around it.
@MainActor
func checkKeyedList(_ mock: MockRenderer) {
    Runtime.shared.installRootView { ThreadScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    let encoder = FlatTreeEncoder()
    var root: PatchNode?
    _ = applyPatch(encoder.encodePatch(root: mock.lastTree!), into: &root)
    let tapOfFirst = encoder.handlers.keys.filter { $0.hasSuffix(".tap") }.sorted()

    @MainActor
    func step(_ change: () -> Void, _ label: String, inserts: Int) {
        change()
        Runtime.shared.setNeedsRender()
        Runtime.shared.renderFrame()
        let tree = mock.lastTree!
        let bytes = encoder.encodePatch(root: tree)
        let stats = patchStats(bytes)
        _ = applyPatch(bytes, into: &root)
        expect(describeTree(root!) == fullDescribe(tree), "\(label): applied patch == full encode")
        // (One attribute update is the list's own: it carries its row count.)
        expect(stats.reorders == 1 && stats.inserts == inserts && stats.replaces == 0 && stats.attrs <= 1,
               "\(label): one reorder carrying \(inserts) node(s), nothing else (got \(stats))")
    }
    // The mock host draws list chrome itself (no separator nodes): a new
    // row ships as its one cell.
    step({ thread.insert(.init(id: "new", text: "New"), at: 0) }, "insert at top", inserts: 1)
    let tapsAfter = Set(encoder.handlers.keys.filter { $0.hasSuffix(".tap") })
    expect(tapOfFirst.allSatisfy(tapsAfter.contains), "rows keep their tap handler ids when a row is inserted above them")
    step({ thread.append(.init(id: "end", text: "End")) }, "append", inserts: 1)
    step({ thread.remove(at: 5) }, "remove", inserts: 0)
}

/// Rows as their own views (as apps write them): value inputs, some with
/// state of their own or an observed object.
@available(macOS 14.0, iOS 17.0, *)
struct ReuseScreen: View {
    var body: some View {
        List {
            ForEach(reuseThread) { message in
                ReuseRow(message: message)
            }
            ForEach(0..<3) { index in
                ObservingRow(model: ReuseModel.shared, index: index)
            }
        }
        .font(reuseLarge ? .title : .body)
    }
}

struct ReuseRow: View {
    let message: ThreadScreen.Message
    @State private var taps = 0
    var body: some View {
        HStack {
            Text(message.text)
            Text("\(taps)")
        }
        .onTapGesture { taps += 1 }
    }
}

@available(macOS 14.0, iOS 17.0, *)
@Observable final class ReuseModel {
    var label = "a"
    nonisolated(unsafe) static let shared = ReuseModel()
}

@available(macOS 14.0, iOS 17.0, *)
struct ObservingRow: View {
    let model: ReuseModel
    let index: Int
    var body: some View { Text(model.label + "\(index)") }
}

nonisolated(unsafe) var reuseThread: [ThreadScreen.Message] = (0..<30).map { .init(id: "r\($0)", text: "Row \($0)") }
nonisolated(unsafe) var reuseLarge = false

/// A view whose inputs are unchanged is not rebuilt: an update to one row of
/// a list rebuilds that row; a row's own state rebuilds only it; rows that
/// observe an object are reused until it changes, and rebuilt when it does;
/// an environment change above rebuilds what it reaches. The patch stream
/// stays exact throughout.
@MainActor
func checkSubtreeReuse(_ mock: MockRenderer) {
    guard #available(macOS 14.0, iOS 17.0, *) else { return }
    Runtime.shared.installRootView { ReuseScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    let encoder = FlatTreeEncoder()
    var root: PatchNode?
    _ = applyPatch(encoder.encodePatch(root: mock.lastTree!), into: &root)

    @MainActor
    func frame(_ label: String, reused expected: Int, _ change: () -> Void) {
        change()
        let before = Runtime.shared.reusedSubtrees
        Runtime.shared.setNeedsRender()
        Runtime.shared.renderFrame()
        let reused = Runtime.shared.reusedSubtrees - before
        let tree = mock.lastTree!
        _ = applyPatch(encoder.encodePatch(root: tree), into: &root)
        expect(describeTree(root!) == fullDescribe(tree), "\(label): applied patch == full encode")
        expect(reused == expected, "\(label): \(expected) row(s) reused (got \(reused))")
    }
    frame("one row's text changes", reused: 32) { reuseThread[29].text = "Changed" }
    expect(findTextInTree(mock.lastTree!, "Changed"), "the changed row shows its new text")
    frame("a row is added", reused: 33) { reuseThread.append(.init(id: "r30", text: "Row 30")) }
    // A row's own state: tap the first row.
    let tapIDs = FlatTreeEncoder().handlersAfterEncode(mock.lastTree!).filter { $0.hasSuffix(".tap") }
    if let first = tapIDs.first {
        Runtime.shared.installTreeHandlers(encoder.handlers)
        Runtime.shared.hostViewEvent(id: first, value: "")
        frame("a row's own state changes", reused: 33) {}
        expect(findTextInTree(mock.lastTree!, "1"), "the tapped row shows its new count")
    } else {
        expect(false, "rows register tap handlers")
    }
    frame("an observed object changes", reused: 31) { ReuseModel.shared.label = "b" }
    expect(findTextInTree(mock.lastTree!, "b0"), "rows observing an object rebuild when it changes")
    frame("the environment changes above", reused: 0) { reuseLarge = true }
}

/// A screen whose layout follows the size class, as Visor's root does
/// (`sizeClass == .compact` read each build), under a container with state
/// of its own, so the frame after a resize can reuse it.
struct SizeClassScreen: View {
    var body: some View {
        SizeClassBody()
    }
}

struct SizeClassBody: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var count = 0
    var body: some View {
        VStack {
            Text(sizeClass == .compact ? "layout compact" : "layout regular")
            Text("count \(count)")
        }
    }
}

/// A host that starts its guest before it knows its size (900 wide) and
/// then reports the real one (a phone's 393): the frame after the resize
/// is a whole build, and a view that reads the size class is rebuilt with
/// the new one, not reused as it was (Visor Isomer drew its two-column
/// layout on an iPhone until a reconnect rebuilt it).
@MainActor
func checkSizeClassResize(_ mock: MockRenderer) {
    Runtime.shared.installRootView { SizeClassScreen() }
    Runtime.shared.start(host: StubHost(), width: 900, height: 680)
    expect(findTextInTree(mock.lastTree!, "layout regular"), "900 wide is regular")
    Runtime.shared.resize(width: 393, height: 852)
    expect(findTextInTree(mock.lastTree!, "layout compact"), "after a resize to 393 the layout is compact")
    Runtime.shared.resize(width: 900, height: 680)
    expect(findTextInTree(mock.lastTree!, "layout regular"), "and regular again at 900")
}

/// A long list builds only the rows near what the host shows: the rest are
/// keyed placeholders, and a reported window builds around itself.
struct LongListScreen: View {
    var body: some View {
        List {
            ForEach(0..<200) { index in
                ReuseRow(message: .init(id: "l\(index)", text: "Line \(index)"))
            }
        }
    }
}

func countParam(_ node: IsoFlat_Node, key: String, value: String? = nil) -> Int {
    var count = node.params.contains { $0.key == key && (value == nil || $0.value == value) } ? 1 : 0
    for child in node.ch { count += countParam(child, key: key, value: value) }
    return count
}

@MainActor
func checkLazyRows(_ mock: MockRenderer) {
    Runtime.shared.installRootView { LongListScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    let encoder = FlatTreeEncoder()
    var root: PatchNode?
    _ = applyPatch(encoder.encodePatch(root: mock.lastTree!), into: &root)
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
    let tree = getRoot(byteBuffer: &buffer) as IsoFlat_Node
    expect(countParam(tree, key: "placeholder") == 140, "first frame builds 30 rows at each end (placeholders: \(countParam(tree, key: "placeholder")))")
    expect(findText(tree, "Line 0") && findText(tree, "Line 199") && !findText(tree, "Line 100"), "the ends are built, the middle is not")
    guard let window = findParam(tree, key: "window") else { expect(false, "a lazy list names where the host reports its window"); return }
    Runtime.shared.installTreeHandlers(encoder.handlers)
    Runtime.shared.hostViewEvent(id: window, value: "150,160")
    Runtime.shared.renderFrame()
    // The rows shown at once, the rest of the window a few at a time (a
    // frame never builds a whole page of new rows).
    let first = mock.lastTree!
    expect(findTextInTree(first, "Line 150") && findTextInTree(first, "Line 160") && !findTextInTree(first, "Line 80"),
           "a jump builds the rows shown first, the far window later")
    for _ in 0..<12 { Runtime.shared.setNeedsRender(); Runtime.shared.renderFrame() }
    let next = mock.lastTree!
    _ = applyPatch(encoder.encodePatch(root: next), into: &root)
    expect(describeTree(root!) == fullDescribe(next), "lazy rows: applied patch == full encode")
    expect(findTextInTree(next, "Line 150") && findTextInTree(next, "Line 80") && !findTextInTree(next, "Line 0"),
           "a reported window builds around itself (and lets the far rows go)")
    // Rows keep their keys built or not: the list's children keys don't change.
    Runtime.shared.hostViewEvent(id: window, value: "0,10")
    Runtime.shared.renderFrame()
    _ = applyPatch(encoder.encodePatch(root: mock.lastTree!), into: &root)
    expect(describeTree(root!) == fullDescribe(mock.lastTree!), "lazy rows back at the top: applied patch == full encode")
    expect(findTextInTree(mock.lastTree!, "Line 0"), "scrolling back builds the rows again")
}

func findTextInTree(_ node: RenderNode, _ value: String) -> Bool {
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: node))
    return findText(getRoot(byteBuffer: &buffer) as IsoFlat_Node, value)
}

extension FlatTreeEncoder {
    func handlersAfterEncode(_ tree: RenderNode) -> [String] {
        _ = encode(root: tree)
        return handlers.keys.sorted()
    }
}

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

/// `.onKeyPress` on a field: the host reports keys through
/// `keyPressEvent`, which answers whether the app took the key (so the host
/// keeps it from the field).
nonisolated(unsafe) var keyLog: [String] = []
struct KeyScreen: View {
    @State private var text = ""
    var body: some View {
        TextField("", text: $text)
            .onKeyPress(.upArrow) { keyLog.append("up"); return .handled }
            .onKeyPress(phases: .down) { press in
                guard press.modifiers.contains(.control) else { return .ignored }
                keyLog.append("ctrl-\(press.key.character) \(press.characters.unicodeScalars.first!.value)")
                return .handled
            }
    }
}

@MainActor
func checkKeyPress(_ mock: MockRenderer) {
    Runtime.shared.installRootView { KeyScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    let encoder = FlatTreeEncoder()
    _ = encoder.encode(root: mock.lastTree!)
    Runtime.shared.installTreeHandlers(encoder.handlers)
    guard let id = encoder.handlers.keys.first(where: { $0.hasSuffix(".keys") }) else {
        return expect(false, "a field under .onKeyPress registers its key handler")
    }
    let unit = "\u{1F}"
    expect(Runtime.shared.keyPressEvent(id: id, value: "d\(unit)\u{F700}\(unit)\u{F700}"), "the up arrow is taken")
    expect(Runtime.shared.keyPressEvent(id: id, value: "r\(unit)\u{F700}\(unit)\u{F700}"), "a held up arrow repeats")
    expect(!Runtime.shared.keyPressEvent(id: id, value: "d\(unit)a\(unit)a"), "a plain letter is left to the field")
    expect(Runtime.shared.keyPressEvent(id: id, value: "dc\(unit)c\(unit)\u{3}"), "control-c is taken")
    expect(!Runtime.shared.keyPressEvent(id: id, value: "rc\(unit)c\(unit)\u{3}"), "a down-only handler ignores repeats")
    expect(keyLog == ["up", "up", "ctrl-c 3"], "the actions saw the keys (got \(keyLog))")
}

/// A modifier over several views applies to each, which stay the stack's
/// children (SwiftUI's rule); it was one box stacking them on each other.
struct GroupPaddingScreen: View {
    var body: some View {
        HStack {
            Group {
                Text("one")
                Text("two")
                Text("three")
            }
            .padding(.top, 4)
        }
    }
}

@MainActor
func checkModifierOverGroup(_ mock: MockRenderer) {
    Runtime.shared.installRootView { GroupPaddingScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
    func stack(_ n: IsoFlat_Node) -> IsoFlat_Node? {
        if n.kind == .stack, n.axis == .horizontal { return n }
        for i in 0..<n.ch.count { if let s = stack(n.ch[i]) { return s } }
        return nil
    }
    guard let row = stack(getRoot(byteBuffer: &buffer) as IsoFlat_Node) else { return expect(false, "an HStack was built") }
    expect(row.ch.count == 3, "a modifier over a group leaves its three views in the stack (got \(row.ch.count))")
}

/// `.scrollEdgeEffectStyle` set on a container reaches the scroll views
/// inside it (as SwiftUI's does: a split view's column, a whole screen),
/// and an inner one overrides it.
struct EdgeStyleScreen: View {
    var body: some View {
        HStack {
            VStack {
                Text("Sidebar")
                List { Text("a") }
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
            VStack {
                ScrollView { Text("b") }.scrollEdgeEffectStyle(.soft, for: .top)
                ScrollView { Text("c") }
            }
            .scrollEdgeEffectStyle(.hard, for: [.top, .bottom])
            ScrollView { Text("d") }
        }
    }
}

@MainActor
func checkScrollEdgeStyle(_ mock: MockRenderer) {
    Runtime.shared.installRootView { EdgeStyleScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
    let root = getRoot(byteBuffer: &buffer) as IsoFlat_Node
    let tops = countParam(root, key: "edgeTop", value: "hard")
    let bottoms = countParam(root, key: "edgeBottom", value: "hard")
    let softTops = countParam(root, key: "edgeTop", value: "soft")
    expect(tops == 2, "a hard top edge on a container reaches its list and scroll, not an overridden or unstyled one (got \(tops))")
    expect(bottoms == 2, "a hard bottom edge reaches both scrolls inside, the top override aside (got \(bottoms))")
    expect(softTops == 1, "an inner soft top edge overrides the container's, and is sent (got \(softTops))")
}

/// An app's view whose body is several views is those views in its
/// container: two sections in a Form are two cards, two texts in a VStack
/// two rows (they used to overlap as one ZStack node).
struct TwoSections: View {
    let show: Bool
    var body: some View {
        if show { Section("Usage") { Text("Tokens") } }
        Section("Limits") { Text("Weekly") }
    }
}
struct TwoTexts: View {
    var body: some View {
        Text("first")
        Text("second")
    }
}
struct MultiBodyScreen: View {
    var body: some View {
        VStack {
            Form {
                Section("About") { Text("Title") }
                TwoSections(show: true)
                TwoSections(show: false)
                Section { Text("End") }
            }
            VStack { TwoTexts() }
        }
    }
}

@MainActor
func checkMultiViewBody(_ mock: MockRenderer) {
    Runtime.shared.installRootView { MultiBodyScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
    let root = getRoot(byteBuffer: &buffer) as IsoFlat_Node
    var depthStacks = 0
    func walk(_ n: IsoFlat_Node) {
        // (The Form's own ZStack, its grouped ground behind its scroll, aside.)
        if n.kind == .stack, n.axis == .depth, !(n.ch.count == 2 && n.ch[0].kind == .shape) { depthStacks += 1 }
        for i in 0..<n.ch.count { walk(n.ch[i]) }
    }
    walk(root)
    expect(depthStacks == 0, "a body of several views is not drawn as one ZStack (got \(depthStacks))")
    // The inner VStack holds TwoTexts' two texts side by side in its rows.
    func vstackWithTexts(_ n: IsoFlat_Node) -> IsoFlat_Node? {
        if n.kind == .stack, n.axis == .vertical, n.ch.count == 2, n.ch[0].kind == .text, n.ch[1].kind == .text { return n }
        for i in 0..<n.ch.count { if let s = vstackWithTexts(n.ch[i]) { return s } }
        return nil
    }
    expect(vstackWithTexts(root) != nil, "a VStack of a two-text view has the two texts as its rows")
}

/// `.textSelection` marks the view it is on for the host ("select": 1 or 0).
struct SelectableScreen: View {
    var body: some View {
        VStack {
            VStack {
                Text("selectable")
                Text("not").textSelection(.disabled)
            }
            .textSelection(.enabled)
            Text("plain")
        }
    }
}

@MainActor
func checkTextSelection(_ mock: MockRenderer) {
    Runtime.shared.installRootView { SelectableScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
    var values: [String] = []
    func walk(_ n: IsoFlat_Node) {
        for kv in n.params where kv.key == "select" { values.append(kv.value ?? "") }
        for i in 0..<n.ch.count { walk(n.ch[i]) }
    }
    walk(getRoot(byteBuffer: &buffer) as IsoFlat_Node)
    expect(values.sorted() == ["0", "1"], "an enabled container and a disabled text inside it are marked (got \(values))")
}

/// A linear ProgressView takes the tint in scope, set on it or around it.
struct TintedProgressScreen: View {
    var body: some View {
        VStack {
            ProgressView(value: 0.4).tint(.red)
            VStack { ProgressView(value: 0.9) }.tint(.orange)
            ProgressView(value: 0.1)
        }
    }
}

/// An app's own `Shape`: its `path(in:)` travels to the host as the shape
/// node's `path` param, evaluated in the unit square.
struct CheckerShape: Shape {
    func path(in rect: SwiftUI.CGRect) -> Path {
        var path = Path()
        let cell = rect.width / 2
        path.addRect(SwiftUI.CGRect(x: rect.minX, y: rect.minY, width: cell, height: cell))
        path.addRect(SwiftUI.CGRect(x: rect.minX + cell, y: rect.minY + cell, width: cell, height: cell))
        return path
    }
}
struct CustomShapeScreen: View {
    var body: some View {
        VStack {
            CheckerShape().fill(Color.black).aspectRatio(1, contentMode: .fit).frame(maxWidth: 100)
            CheckerShape()
        }
    }
}

@MainActor
func checkCustomShape(_ mock: MockRenderer) {
    Runtime.shared.installRootView { CustomShapeScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
    var paths: [String] = []
    func collect(_ n: IsoFlat_Node) {
        if n.kind == .shape, let path = n.params.first(where: { $0.key == "path" })?.value { paths.append(path) }
        for i in 0..<n.ch.count { collect(n.ch[i]) }
    }
    collect(getRoot(byteBuffer: &buffer) as IsoFlat_Node)
    expect(paths.count == 2, "both custom shapes carry a path (got \(paths.count))")
    expect(paths.first == "R 0 0 0.5 0.5 R 0.5 0.5 0.5 0.5", "the path is the unit-square outline (got \(paths.first ?? "nil"))")
}

/// `.onOpenURL`: a URL delivered to the runtime reaches the handler a view
/// registered, and a change it makes is rendered.
nonisolated(unsafe) var openedURLs: [String] = []
struct OpenURLScreen: View {
    @State private var opened = 0
    var body: some View {
        Text("Opened \(opened)")
            .onOpenURL { url in
                openedURLs.append(url.absoluteString)
                opened += 1
            }
    }
}

@MainActor
func checkOpenURL(_ mock: MockRenderer) {
    openedURLs = []
    Runtime.shared.installRootView { OpenURLScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    Runtime.shared.openURL(external: "visor://connect?code=abc")
    Runtime.shared.renderFrame()
    Runtime.shared.renderFrame()
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
    var texts: [String] = []
    func collect(_ n: IsoFlat_Node) {
        if n.kind == .text, let t = n.v { texts.append(t) }
        for i in 0..<n.ch.count { collect(n.ch[i]) }
    }
    collect(getRoot(byteBuffer: &buffer) as IsoFlat_Node)
    expect(openedURLs == ["visor://connect?code=abc"], "the handler got the URL (got \(openedURLs))")
    expect(texts.contains("Opened 1"), "the change the handler made is rendered (got \(texts))")
}

/// `Link`: a button with its title, whose tap asks the host to open the
/// destination (visor's onboarding has three in a Form).
struct LinkScreen: View {
    var body: some View {
        Form {
            Section {
                Link("Get Tailscale", destination: URL(string: "https://tailscale.com/download")!)
            }
        }
    }
}

@MainActor
func checkLink(_ mock: MockRenderer) {
    hostOpenedURLs = []
    Runtime.shared.installRootView { LinkScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    expect(findTextInTree(mock.lastTree!, "Get Tailscale"), "the link shows its title")
    let encoder = FlatTreeEncoder()
    _ = encoder.encode(root: mock.lastTree!)
    let taps = encoder.handlers.keys.filter { $0.hasSuffix(".tap") }
    expect(taps.count == 1, "the link is one tap target (got \(taps.count))")
    if let tap = taps.first {
        Runtime.shared.installTreeHandlers(encoder.handlers)
        Runtime.shared.hostViewEvent(id: tap, value: "")
    }
    expect(hostOpenedURLs == ["https://tailscale.com/download"], "a tap asks the host to open the destination (got \(hostOpenedURLs))")
}

/// Toolbar content of an app's own (`@ToolbarContentBuilder`), as visor's
/// MigrationSheet has it: a `switch` over a phase with an associated value,
/// blocks of two items, an `if`; and `ProgressView(value:label:)`.
enum SheetPhase { case ready, moving, done(String), failed }
nonisolated(unsafe) var sheetPhase = SheetPhase.ready
nonisolated(unsafe) var sheetShowsHelp = false
struct MigrationLikeSheet: View {
    var body: some View {
        NavigationStack {
            Form {
                if case .moving = sheetPhase {
                    ProgressView(value: 0.5) { Text("Copying files") }
                }
                Text("Sheet")
            }
            .navigationTitle("Migrate")
            .toolbar { toolbar }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        switch sheetPhase {
        case .done(let session):
            ToolbarItem(placement: .confirmationAction) { Button("Open \(session)") {} }
        case .failed:
            ToolbarItem(placement: .cancellationAction) { Button("Close") {} }
            ToolbarItem(placement: .confirmationAction) { Button("Try Again") {} }
        case .moving:
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") {}.disabled(true) }
        case .ready:
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") {} }
            ToolbarItem(placement: .confirmationAction) { Button("Migrate") {} }
        }
        if sheetShowsHelp {
            ToolbarItem(placement: .primaryAction) { Button("Help") {} }
        }
    }
}

@MainActor
func checkToolbarContent(_ mock: MockRenderer) {
    sheetPhase = .ready
    sheetShowsHelp = false
    Runtime.shared.installRootView { MigrationLikeSheet() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    func bar() -> (leading: String, trailing: String) {
        var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
        let tree = getRoot(byteBuffer: &buffer) as IsoFlat_Node
        return (findParam(tree, key: "leading") ?? "", findParam(tree, key: "trailingItems") ?? "")
    }
    func frame() {
        Runtime.shared.setNeedsRender()
        Runtime.shared.renderFrame()
    }
    var items = bar()
    expect(items.leading == "Cancel" && items.trailing == "Migrate", "ready: Cancel and Migrate (got \(items))")
    sheetPhase = .moving
    frame()
    items = bar()
    expect(items.leading == "Cancel" && items.trailing == "", "moving: Cancel alone (got \(items))")
    expect(findTextInTree(mock.lastTree!, "Copying files"), "a progress bar's label of the app's")
    sheetPhase = .done("chat")
    sheetShowsHelp = true
    frame()
    items = bar()
    expect(items.leading == "" && items.trailing.contains("Open chat") && items.trailing.contains("Help"),
           "done: Open, and the if's Help (got \(items))")
    sheetPhase = .failed
    sheetShowsHelp = false
    frame()
    items = bar()
    expect(items.leading == "Close" && items.trailing == "Try Again", "failed: Close and Try Again (got \(items))")
}

/// A view whose build registers what its navigation stack reads (a title,
/// a toolbar item, a URL handler) is reused like any other: its
/// registrations are made again, once, when it is.
nonisolated(unsafe) var replayTick = 0
nonisolated(unsafe) var titledPaneBuilds = 0
struct TitledPane: View {
    var body: some View {
        titledPaneBuilds += 1
        return Text("Pane")
            .navigationTitle("Hello")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Add") {} } }
            .onOpenURL { _ in replayURLsOpened += 1 }
    }
}
nonisolated(unsafe) var replayURLsOpened = 0
struct ReplayScreen: View {
    var body: some View {
        NavigationStack {
            VStack {
                Text("tick \(replayTick)")
                TitledPane()
            }
        }
    }
}

@MainActor
func checkRegistrationReplay(_ mock: MockRenderer) {
    titledPaneBuilds = 0
    replayTick = 0
    Runtime.shared.installRootView { ReplayScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    func bar() -> (title: Int, items: Int) {
        var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
        let tree = getRoot(byteBuffer: &buffer) as IsoFlat_Node
        return (countParam(tree, key: "title", value: "Hello"), countParam(tree, key: "trailingItems", value: "Add"))
    }
    let first = bar()
    expect(first.title == 1 && first.items == 1, "the bar has the pane's title and item (got \(first))")
    let builds = titledPaneBuilds
    for tick in 1...2 {
        replayTick = tick
        Runtime.shared.setNeedsRender()
        Runtime.shared.renderFrame()
        expect(findTextInTree(mock.lastTree!, "tick \(tick)"), "the frame was built (tick \(tick))")
    }
    expect(titledPaneBuilds == builds, "the pane was reused (built \(titledPaneBuilds - builds) more times)")
    let later = bar()
    expect(later.title == 1 && later.items == 1, "the reused pane's title and item are in the bar, once (got \(later))")
    replayURLsOpened = 0
    Runtime.shared.openURL(external: "visor://x")
    Runtime.shared.renderFrame()
    expect(replayURLsOpened == 1, "its URL handler is registered once (ran \(replayURLsOpened) times)")
}

/// A self-drawing renderer's navigation (no semantic navigation): the large
/// title goes into the content's scroll once, frame after frame, though the
/// scroll is in a reused subtree (it was put in again every frame: the web
/// GPU renderer's sidebar showed "Isomer" once per frame drawn).
final class DrawingMockRenderer: TreeRenderer {
    let semanticNavigation = false
    private(set) var lastTree: RenderNode?

    func render(tree: RenderNode) {
        lastTree = tree
    }
}

nonisolated(unsafe) var largeTitleTick = 0
struct TitledList: View {
    var body: some View {
        List { Text("Row") }.navigationTitle("Sidebar")
    }
}
struct LargeTitleScreen: View {
    var body: some View {
        NavigationStack {
            VStack {
                Text("tick \(largeTitleTick)")
                TitledList()
            }
        }
    }
}

func countTexts(_ node: RenderNode, _ value: String) -> Int {
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: node))
    return countFlatTexts(getRoot(byteBuffer: &buffer) as IsoFlat_Node, value)
}

func countFlatTexts(_ node: IsoFlat_Node, _ value: String) -> Int {
    var count = node.kind == .text && node.v == value ? 1 : 0
    for child in node.ch { count += countFlatTexts(child, value) }
    return count
}

@MainActor
func checkLargeTitleOnce(_ previous: MockRenderer) {
    let drawing = DrawingMockRenderer()
    Renderer.bind(drawing)
    defer { Renderer.bind(previous) }
    largeTitleTick = 0
    Runtime.shared.installRootView { LargeTitleScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    expect(countTexts(drawing.lastTree!, "Sidebar") == 1, "the large title is in the first frame once (got \(countTexts(drawing.lastTree!, "Sidebar")))")
    for tick in 1...3 {
        largeTitleTick = tick
        Runtime.shared.setNeedsRender()
        Runtime.shared.renderFrame()
    }
    expect(findTextInTree(drawing.lastTree!, "tick 3"), "the frames were built")
    expect(countTexts(drawing.lastTree!, "Sidebar") == 1, "the large title is there once after three frames (got \(countTexts(drawing.lastTree!, "Sidebar")))")
}

/// A drawn compact split (a phone under the GPU renderer) shows its detail
/// column's back to the sidebar, however the detail's stack is made: the
/// Gallery's page is a view whose body is a NavigationStack(path:), under an
/// `.id`.
nonisolated(unsafe) var compactSplitCase = 0
struct CompactSplitPage: View {
    @State private var path: [Int] = []
    var body: some View {
        NavigationStack(path: $path) {
            Text("Page body").navigationTitle("Page")
        }
    }
}
struct CompactSplitScreen: View {
    @State private var column: NavigationSplitViewColumn = .detail
    var body: some View {
        NavigationSplitView(preferredCompactColumn: $column) {
            List { Text("Row") }.navigationTitle("Sidebar")
        } detail: {
            switch compactSplitCase {
            case 0: NavigationStack { Text("Page body").navigationTitle("Page") }
            case 1: CompactSplitPage()
            default: CompactSplitPage().id(1)
            }
        }
    }
}

func flatNavbarParam(_ node: IsoFlat_Node, _ key: String) -> String? {
    if node.view == "navbar" { for kv in node.params where kv.key == key { return kv.value } }
    for child in node.ch { if let found = flatNavbarParam(child, key) { return found } }
    return nil
}

@MainActor
func checkCompactSplitBack(_ previous: MockRenderer) {
    let drawing = DrawingMockRenderer()
    Renderer.bind(drawing)
    defer { Renderer.bind(previous) }
    for (index, label) in ["a NavigationStack", "a view whose body is a NavigationStack(path:)", "that view under an id"].enumerated() {
        compactSplitCase = index
        Runtime.shared.installRootView { CompactSplitScreen() }
        Runtime.shared.start(host: StubHost(), width: 390, height: 800)
        var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: drawing.lastTree!))
        let back = flatNavbarParam(getRoot(byteBuffer: &buffer) as IsoFlat_Node, "back")
        expect(back == "1", "a drawn compact split's detail that is \(label) goes back to the sidebar (its bar's back: \(back ?? "no bar"))")
    }
}

/// A binding read stops reuse only between the state's owner and the
/// reader: the owner is reused while nothing of its changed, and a change
/// to the state reaches the reader.
nonisolated(unsafe) var bindingOwnerBuilds = 0
nonisolated(unsafe) var bindingOwnerText: Binding<String>?
nonisolated(unsafe) var scopedReaderBuilds = 0
nonisolated(unsafe) var bindingOwnerCount: Binding<Int>?
struct ScopedBindingReader: View {
    @Binding var text: String
    var body: some View {
        scopedReaderBuilds += 1
        return Text("text \(text)")
    }
}
struct BindingOwner: View {
    @State private var text = "a"
    @State private var count = 0
    var body: some View {
        bindingOwnerBuilds += 1
        bindingOwnerText = $text
        bindingOwnerCount = $count
        return VStack {
            Text("owner \(count)")
            ScopedBindingReader(text: $text)
        }
    }
}
struct BindingOwnerScreen: View {
    var body: some View {
        VStack {
            Text("tick \(replayTick)")
            BindingOwner()
        }
    }
}

@MainActor
func checkBindingReadScope(_ mock: MockRenderer) {
    bindingOwnerBuilds = 0
    replayTick = 0
    Runtime.shared.installRootView { BindingOwnerScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    let builds = bindingOwnerBuilds
    replayTick = 1
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    expect(bindingOwnerBuilds == builds, "the owner of the state its child reads is reused (built \(bindingOwnerBuilds - builds) more times)")
    bindingOwnerText?.wrappedValue = "b"
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "text b"), "a change to the state reaches the reader")
    let readerBuilds = scopedReaderBuilds
    bindingOwnerCount?.wrappedValue = 1
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "owner 1"), "the owner's other state changes")
    expect(scopedReaderBuilds == readerBuilds, "the reader is reused while the state it reads is unchanged (built \(scopedReaderBuilds - readerBuilds) more times)")
}

/// A list inside a view that is reused: the view is reused while nothing
/// changes, and a window the host reports still builds its rows (the list's
/// state marks it changed), the far ones over the next frames.
nonisolated(unsafe) var windowPaneBuilds = 0
struct WindowPane: View {
    var body: some View {
        windowPaneBuilds += 1
        return List {
            ForEach(0..<200) { index in
                ReuseRow(message: .init(id: "w\(index)", text: "Win \(index)"))
            }
        }
    }
}
struct WindowScreen: View {
    var body: some View {
        VStack {
            Text("tick \(replayTick)")
            WindowPane()
        }
    }
}

@MainActor
func checkListInReusedView(_ mock: MockRenderer) {
    windowPaneBuilds = 0
    replayTick = 0
    Runtime.shared.installRootView { WindowScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    let encoder = FlatTreeEncoder()
    var root: PatchNode?
    _ = applyPatch(encoder.encodePatch(root: mock.lastTree!), into: &root)
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
    let tree = getRoot(byteBuffer: &buffer) as IsoFlat_Node
    guard let window = findParam(tree, key: "window") else { expect(false, "the list names its window"); return }
    let builds = windowPaneBuilds
    replayTick = 1
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    expect(windowPaneBuilds == builds, "the view holding the list is reused (built \(windowPaneBuilds - builds) more times)")
    Runtime.shared.installTreeHandlers(encoder.handlers)
    Runtime.shared.hostViewEvent(id: window, value: "150,160")
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "Win 155"), "a reported window builds its rows inside the reused view")
    for _ in 0..<12 { Runtime.shared.setNeedsRender(); Runtime.shared.renderFrame() }
    let next = mock.lastTree!
    _ = applyPatch(encoder.encodePatch(root: next), into: &root)
    expect(describeTree(root!) == fullDescribe(next), "list in a reused view: applied patch == full encode")
    expect(findTextInTree(next, "Win 80"), "the far rows of the window follow over the next frames")
    let settled = windowPaneBuilds
    replayTick = 2
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    expect(windowPaneBuilds == settled, "once the window is built, the view is reused again")
}

/// A view holding `@FocusState` is reused like any other, and the host
/// moving focus reaches it (the state underneath is marked changed).
nonisolated(unsafe) var focusPaneBuilds = 0
struct FocusPane: View {
    @FocusState private var focused: Bool
    @State private var text = ""
    var body: some View {
        focusPaneBuilds += 1
        return VStack {
            Text(focused ? "focus on" : "focus off")
            TextField("Message", text: $text).focused($focused)
        }
    }
}
struct FocusScreen: View {
    var body: some View {
        VStack {
            Text("tick \(replayTick)")
            FocusPane()
        }
    }
}

@MainActor
func checkFocusStateReuse(_ mock: MockRenderer) {
    focusPaneBuilds = 0
    replayTick = 0
    Runtime.shared.installRootView { FocusScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    let builds = focusPaneBuilds
    replayTick = 1
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    expect(focusPaneBuilds == builds, "the view holding @FocusState is reused (built \(focusPaneBuilds - builds) more times)")
    let encoder = FlatTreeEncoder()
    var buffer = ByteBuffer(bytes: encoder.encode(root: mock.lastTree!))
    let tree = getRoot(byteBuffer: &buffer) as IsoFlat_Node
    guard let focusID = findParam(tree, key: "focusId") else { expect(false, "the field names its focus handler"); return }
    Runtime.shared.installTreeHandlers(encoder.handlers)
    Runtime.shared.hostViewEvent(id: focusID, value: "1")
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "focus on"), "the host focusing the field reaches the view")
}

/// `scrollTo` a row the list has not built, inside a view that is reused:
/// the list builds it (the request marks the list changed).
nonisolated(unsafe) var scrollPaneProxy: ScrollViewProxy?
struct ScrollTargetPane: View {
    var body: some View {
        ScrollViewReader { proxy in
            let _ = (scrollPaneProxy = proxy)
            List {
                ForEach(0..<200) { index in
                    ReuseRow(message: .init(id: "s\(index)", text: "Target \(index)"))
                }
            }
        }
    }
}
struct ScrollTargetScreen: View {
    var body: some View {
        VStack {
            Text("tick \(replayTick)")
            ScrollTargetPane()
        }
    }
}

@MainActor
func checkScrollToUnbuiltRow(_ mock: MockRenderer) {
    scrollPaneProxy = nil
    replayTick = 0
    Runtime.shared.installRootView { ScrollTargetScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    replayTick = 1
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    expect(!findTextInTree(mock.lastTree!, "Target 100"), "the middle row is not built at first")
    guard let proxy = scrollPaneProxy else { expect(false, "the reader hands out its proxy"); return }
    proxy.scrollTo(100)
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "Target 100"), "scrolling to it builds the row, in a reused view")
}

/// A navigation stack inside a view that is reused: a push marks the
/// stack changed, so the pushed screen is built.
nonisolated(unsafe) var stackPaneBuilds = 0
struct StackPane: View {
    var body: some View {
        stackPaneBuilds += 1
        return NavigationStack {
            NavigationLink(destination: Text("Pushed screen")) { Text("Open") }
                .navigationTitle("Stack")
        }
    }
}
struct StackScreen: View {
    var body: some View {
        VStack {
            Text("tick \(replayTick)")
            StackPane()
        }
    }
}

@MainActor
func checkPushInReusedStack(_ mock: MockRenderer) {
    stackPaneBuilds = 0
    replayTick = 0
    Runtime.shared.installRootView { StackScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    let builds = stackPaneBuilds
    replayTick = 1
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    expect(stackPaneBuilds == builds, "the view holding the stack is reused (built \(stackPaneBuilds - builds) more times)")
    let encoder = FlatTreeEncoder()
    _ = encoder.encode(root: mock.lastTree!)
    let taps = encoder.handlers.keys.filter { $0.hasSuffix(".tap") }
    guard let tap = taps.first else { expect(false, "the link is a tap target"); return }
    Runtime.shared.installTreeHandlers(encoder.handlers)
    Runtime.shared.hostViewEvent(id: tap, value: "")
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "Pushed screen"), "the push reaches the reused stack")
}

/// A value mid-animation moves each frame while the views beside it are
/// reused.
nonisolated(unsafe) var fadeShown: Binding<Bool>?
nonisolated(unsafe) var fadeSiblingBuilds = 0
struct FadePane: View {
    @State private var shown = false
    var body: some View {
        fadeShown = $shown
        return Text("Fading").opacity(shown ? 1 : 0)
    }
}
struct FadeSibling: View {
    var body: some View {
        fadeSiblingBuilds += 1
        return Text("Sibling")
    }
}
struct FadeScreen: View {
    var body: some View {
        VStack {
            FadePane()
            FadeSibling()
        }
    }
}

@MainActor
func checkAnimationInReusedTree(_ mock: MockRenderer) {
    fadeSiblingBuilds = 0
    stubHostNow = 0
    Runtime.shared.installRootView { FadeScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    // A text's opacity is its colour's alpha, relative to an unfaded one's.
    func alpha(of text: String) -> Double? {
        var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
        func find(_ n: IsoFlat_Node) -> Double?? {
            if n.v == text { return .some(n.color.map { Double($0.a) } ?? n.opacity) }
            for i in 0..<n.ch.count { if let found = find(n.ch[i]) { return found } }
            return nil
        }
        return find(getRoot(byteBuffer: &buffer) as IsoFlat_Node) ?? nil
    }
    func opacity() -> Double? {
        guard let faded = alpha(of: "Fading"), let full = alpha(of: "Sibling"), full > 0 else { return nil }
        return faded / full
    }
    expect((opacity() ?? 1) == 0, "it starts hidden (opacity \(String(describing: opacity())))")
    let builds = fadeSiblingBuilds
    withAnimation(.linear(duration: 1)) { fadeShown?.wrappedValue = true }
    Runtime.shared.renderFrame()
    stubHostNow = 0.5
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    let middle = opacity() ?? 1
    expect(middle > 0.3 && middle < 0.7, "half way through, the value is half way (\(middle))")
    stubHostNow = 1.2
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    expect(abs((opacity() ?? 0) - 1) < 0.001, "it ends at its target (\(String(describing: opacity())))")
    expect(fadeSiblingBuilds == builds, "the view beside it is reused throughout (built \(fadeSiblingBuilds - builds) more times)")
    stubHostNow = 0
}

/// The encoder keeps a reused subtree holding a text field and a list as
/// it was while their live values hold, and flattens it again when one
/// changes (the text, the focus, a scroll request): every frame's patch
/// applied is the full encoding.
nonisolated(unsafe) var liveFieldText: Binding<String>?
nonisolated(unsafe) var liveFieldFocus: FocusState<Bool>.Binding?
nonisolated(unsafe) var liveListProxy: ScrollViewProxy?
struct LiveFieldPane: View {
    @State private var text = "draft"
    var body: some View {
        liveFieldText = $text
        return VStack {
            ScrollViewReader { proxy in
                let _ = (liveListProxy = proxy)
                List {
                    ForEach(0..<40) { index in
                        ReuseRow(message: .init(id: "lf\(index)", text: "Live \(index)"))
                    }
                }
            }
            LiveField(text: $text)
        }
    }
}
/// The field in a view of its own, given the binding: reused when the text
/// changes (it does not read it while building), so only the encoder sees.
nonisolated(unsafe) var liveFieldBuilds = 0
struct LiveField: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        liveFieldBuilds += 1
        liveFieldFocus = $focused
        return TextField("Message", text: $text).focused($focused)
    }
}
struct LiveFieldScreen: View {
    var body: some View {
        VStack {
            Text("tick \(replayTick)")
            LiveFieldPane()
        }
    }
}

@MainActor
func checkEncoderLiveValues(_ mock: MockRenderer) {
    replayTick = 0
    Runtime.shared.installRootView { LiveFieldScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    let encoder = FlatTreeEncoder()
    var root: PatchNode?
    _ = applyPatch(encoder.encodePatch(root: mock.lastTree!), into: &root)
    func frame(_ label: String, _ change: () -> Void) {
        change()
        Runtime.shared.setNeedsRender()
        Runtime.shared.renderFrame()
        let tree = mock.lastTree!
        _ = applyPatch(encoder.encodePatch(root: tree), into: &root)
        expect(describeTree(root!) == fullDescribe(tree), "\(label): applied patch == full encode")
    }
    frame("nothing of it changes") { replayTick = 1 }
    let fieldBuilds = liveFieldBuilds
    frame("the text changes") { liveFieldText?.wrappedValue = "changed" }
    expect(liveFieldBuilds == fieldBuilds, "the field's view is reused across the change (built \(liveFieldBuilds - fieldBuilds) more times)")
    expect(describeTree(root!).contains("changed"), "the field shows its new text")
    frame("the focus changes") { liveFieldFocus?.wrappedValue = true }
    frame("a scroll request") { liveListProxy?.scrollTo(30) }
    frame("nothing changes again") { replayTick = 2 }
}

/// A scroll view capped by `.frame(maxHeight:)` is greedy up to the cap
/// only: the stacks above it are not greedy for it (Visor's composer, its
/// suggestions list so capped, filled the screen when the list came in).
struct CappedScrollScreen: View {
    var body: some View {
        VStack {
            Text("Transcript")
            VStack {
                ScrollView { Text("/compact") }.frame(maxHeight: 92)
                TextField("Message", text: .constant("/c"))
            }
        }
    }
}

@MainActor
func checkCappedScrollGreediness(_ mock: MockRenderer) {
    Runtime.shared.installRootView { CappedScrollScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let tree = lastFlatTree(mock)
    func holds(_ node: IsoFlat_Node, _ kind: IsoFlat_Kind) -> Bool {
        !flatNodes(node) { $0.kind == kind }.isEmpty
    }
    let stacks = flatNodes(tree) { $0.kind == .stack && holds($0, .scroll) && holds($0, .textfield) }
    expect(!stacks.isEmpty, "the composer's stacks are in the tree")
    expect(stacks.allSatisfy { !$0.growH }, "no stack above the capped scroll view grows in height (\(stacks.filter(\.growH).count) of \(stacks.count) do)")
    expect(flatNodes(tree) { $0.kind == .scroll }.first?.growH == true, "the scroll view still fills its cap")
}

/// `.scrollDisabled(true)` reaches the scroll it is around (a List here,
/// as AgentUI's held empty state is) and not a sibling's; the environment
/// reads it as SwiftUI's `\.isScrollEnabled`.
nonisolated(unsafe) var readScrollEnabled: [Bool] = []
struct ScrollEnabledProbe: View {
    @Environment(\.isScrollEnabled) private var enabled
    var body: some View {
        readScrollEnabled.append(enabled)
        return Text(enabled ? "scrolls" : "still")
    }
}
struct ScrollDisabledScreen: View {
    var body: some View {
        VStack {
            List { ScrollEnabledProbe() }.scrollDisabled(true)
            ScrollView { ScrollEnabledProbe() }
        }
    }
}

@MainActor
func checkScrollDisabled(_ mock: MockRenderer) {
    readScrollEnabled = []
    Runtime.shared.installRootView { ScrollDisabledScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
    var disabled: [Bool] = []
    func collect(_ n: IsoFlat_Node) {
        if n.kind == .scroll { disabled.append(n.params.contains { $0.key == "scrollDisabled" && $0.value == "1" }) }
        for i in 0..<n.ch.count { collect(n.ch[i]) }
    }
    collect(getRoot(byteBuffer: &buffer) as IsoFlat_Node)
    expect(disabled == [true, false], "the disabled List's scroll carries scrollDisabled, the other scroll not (got \(disabled))")
    expect(readScrollEnabled.prefix(2) == [false, true], "\\.isScrollEnabled reads false inside, true outside (got \(readScrollEnabled))")
}

/// The chrome a native host draws itself, carried as what it is: a list
/// section header's `.textCase(nil)`, a tinted swipe button (the tint is
/// an environment modifier around the button), the bottom bar's items, and
/// a split view's style and column bounds.
struct NativeChromeScreen: View {
    @State private var search = ""
    var body: some View {
        NavigationSplitView {
            List {
                Section {
                    Text("Row").swipeActions {
                        Button("Archive") {}.tint(.orange)
                    }
                } header: {
                    Text("Head").textCase(nil)
                }
            }
            .searchable(text: $search, prompt: "Find")
            .toolbar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("New", systemImage: "square.and.pencil") {}
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 440)
        } detail: {
            Text("Detail")
        }
        .navigationSplitViewStyle(.balanced)
    }
}

@MainActor
func checkNativeChrome(_ mock: MockRenderer) {
    Runtime.shared.installRootView { NativeChromeScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
    let root = getRoot(byteBuffer: &buffer) as IsoFlat_Node
    var cases: [String] = []
    var swipe: String?
    var bar: String?
    var split: [String: String] = [:]
    func collect(_ n: IsoFlat_Node) {
        if n.kind == .text, n.v == "Head" { cases.append(n.params.first { $0.key == "textCase" }?.value ?? "") }
        if let value = n.params.first(where: { $0.key == "swipeTrailing" })?.value { swipe = value }
        if let value = n.params.first(where: { $0.key == "bottomBar" })?.value { bar = value }
        if n.kind == .hostview, n.view == "navsplit" { for kv in n.params { split[kv.key] = kv.value } }
        for i in 0..<n.ch.count { collect(n.ch[i]) }
    }
    collect(root)
    expect(cases == ["none"], "a header's .textCase(nil) rides its text (got \(cases))")
    let fields = swipe?.split(separator: "\u{1E}", omittingEmptySubsequences: false).map(String.init) ?? []
    expect(fields.count == 5 && fields[1] == "Archive" && fields[4].hasPrefix("#"),
           "a tinted swipe button is collected through .tint, with its colour (got \(fields))")
    expect(bar == "search\nfixed\nbutton", "the bottom bar names its items (got \(bar ?? "nil"))")
    expect(split["style"] == "balanced" && split["sidebarWidth"] == "300" && split["sidebarWidthMin"] == "240"
           && split["sidebarWidthMax"] == "440", "the split carries its style and the sidebar's bounds (got \(split))")
}

/// A string literal given to Text is a LocalizedStringKey: its markdown
/// styles the text and its links (bracketed and bare) are links; a String
/// variable stays as it is, and so does what is interpolated.
struct MarkdownLiteralScreen: View {
    let plain = "**not bold**"
    let name = "a_b*c"
    var body: some View {
        VStack {
            Text("See **this** and [notes](https://example.com/n) or http://192.168.1.20:7433, `code`.")
            Text(plain)
            Text("Hi \(name)!")
        }
    }
}

@MainActor
func checkMarkdownLiteral(_ mock: MockRenderer) {
    Runtime.shared.installRootView { MarkdownLiteralScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
    var texts: [(String, String?, String?)] = []
    func collect(_ n: IsoFlat_Node) {
        if n.kind == .text { texts.append((n.v ?? "", n.params.first { $0.key == "runs" }?.value, n.params.first { $0.key == "runLinks" }?.value)) }
        for i in 0..<n.ch.count { collect(n.ch[i]) }
    }
    collect(getRoot(byteBuffer: &buffer) as IsoFlat_Node)
    let first = texts.first { $0.0.hasPrefix("See") }
    expect(first?.0 == "See this and notes or http://192.168.1.20:7433, code.", "the literal's markup is gone from its words (got \(first?.0 ?? "nil"))")
    expect(first?.1?.contains(":b") == true && first?.1?.contains(":m") == true && first?.1?.contains("l") == true,
           "its runs are bold, monospaced and links (got \(first?.1 ?? "nil"))")
    expect(first?.2 == "https://example.com/n\u{1F}http://192.168.1.20:7433", "its links carry their URLs (got \(first?.2 ?? "nil"))")
    expect(texts.contains { $0.0 == "**not bold**" && $0.1 == nil }, "a String variable is not markdown")
    expect(texts.contains { $0.0 == "Hi a_b*c!" && $0.1 == nil }, "an interpolated value is taken as it is")
}

/// An `@Observable` model (the Observation module), as SwiftUI takes it:
/// held by a view, put in the environment, bound with `@Bindable`.
@available(macOS 14.0, iOS 17.0, *)
@Observable final class CounterModel {
    var count = 0
    var title = "Counter"
    var unread = 0
}

@available(macOS 14.0, iOS 17.0, *)
struct ObservationScreen: View {
    let model: CounterModel
    var body: some View {
        VStack {
            CountLabel(model: model)
            TitleLabel()
            Text("\(Text("Joined").bold()) \(model.title)!")
        }
        .environment(model)
    }
}

@available(macOS 14.0, iOS 17.0, *)
struct CountLabel: View {
    let model: CounterModel
    var body: some View { Text("Count \(model.count)") }
}

@available(macOS 14.0, iOS 17.0, *)
struct TitleLabel: View {
    @Environment(CounterModel.self) private var model
    var body: some View { Text(model.title) }
}

/// A view re-evaluates when a property its body read changes, and only
/// then: a view that read another is reused, and a property no body read
/// asks for no frame. `@Environment(Model.self)` finds the model
/// `.environment(_:)` put there; `@Bindable` binds to its properties; a Text
/// interpolated into a literal keeps its styles.
@MainActor
func checkObservation(_ mock: MockRenderer) {
    guard #available(macOS 14.0, iOS 17.0, *) else { return }
    let model = CounterModel()
    Runtime.shared.installRootView { ObservationScreen(model: model) }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    expect(findTextInTree(mock.lastTree!, "Count 0"), "a model's property shows")
    expect(findTextInTree(mock.lastTree!, "Counter"), "@Environment(Model.self) reads the model .environment(_:) put there")
    expect(!Runtime.shared.wantsFrame, "nothing is pending after the first frame")

    model.unread = 1
    expect(!Runtime.shared.wantsFrame, "a property no body read asks for no frame")

    model.count = 3
    expect(Runtime.shared.wantsFrame, "a property a body read asks for a frame")
    var before = Runtime.shared.reusedSubtrees
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "Count 3"), "the view that read it shows the new value")
    expect(Runtime.shared.reusedSubtrees - before >= 1, "the view that read another property is reused")

    model.title = "Renamed"
    before = Runtime.shared.reusedSubtrees
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "Renamed"), "the environment's reader shows the new value")

    let title = Bindable(model).title
    title.wrappedValue = "Bound"
    expect(model.title == "Bound", "a @Bindable binding writes the model")
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "Bound"), "and the views that read it follow")

    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
    var joined: (String, String?)?
    func collect(_ n: IsoFlat_Node) {
        if n.kind == .text, (n.v ?? "").hasPrefix("Joined") { joined = (n.v ?? "", n.params.first { $0.key == "runs" }?.value) }
        for i in 0..<n.ch.count { collect(n.ch[i]) }
    }
    collect(getRoot(byteBuffer: &buffer) as IsoFlat_Node)
    expect(joined?.0 == "Joined Bound!", "a Text interpolated into a literal joins it where it stands (got \(joined?.0 ?? "nil"))")
    expect(joined?.1?.hasPrefix("6:b") == true, "and keeps its own styles (got \(joined?.1 ?? "nil"))")
}

/// A split view's detail that brings its own NavigationStack — behind a
/// modifier, a `switch`, a `Group` and an `if`, as an app's detail often is —
/// keeps that one bar; a detail that brings none gets the split's.
nonisolated(unsafe) var splitDetailCase = 0

struct SplitDetailScreen: View {
    var body: some View {
        NavigationSplitView {
            List { Text("Row") }.navigationTitle("Sidebar")
        } detail: {
            detail.detailChrome()
        }
    }

    @ViewBuilder var detail: some View {
        switch splitDetailCase {
        case 0: NavigationStack { Text("Overview").navigationTitle("Overview") }
        case 1: Group { if splitDetailCase == 1 { NavigationStack { Text("Login").navigationTitle("Login") } } }
        case 2: ProviderPane(connected: false)
        case 3: ProviderPane(connected: true)
        default: Text("Plain").navigationTitle("Plain")
        }
    }
}

/// An app's own view in the detail, its stacks in its body (an app's
/// provider panes): a TabView of stacks when connected, a stack otherwise.
struct ProviderPane: View {
    let connected: Bool
    @State private var showSettings = false
    var body: some View {
        Group {
            if connected {
                TabView {
                    NavigationStack { Text("Costs").navigationTitle("Costs") }.tabItem { Text("Costs") }
                    NavigationStack { Text("Resources").navigationTitle("Resources") }.tabItem { Text("Resources") }
                }
            } else {
                NavigationStack { Text("Sign in").navigationTitle("AWS") }
            }
        }
        .sheet(isPresented: $showSettings) { Text("Settings") }
    }
}

/// A sidebar that brings its own NavigationStack: one bar, its own.
struct SplitSidebarStackScreen: View {
    var body: some View {
        NavigationSplitView {
            NavigationStack { List { Text("Row") }.navigationTitle("Sidebar") }
        } detail: {
            Text("Detail").navigationTitle("Detail")
        }
    }
}

extension View {
    @ViewBuilder func detailChrome() -> some View {
        if splitDetailCase >= 0 { self.scrollEdgeEffectStyle(.hard, for: .top) } else { self }
    }
}

@MainActor
func checkSplitDetailStack(_ mock: MockRenderer) {
    func stacksInDetail() -> Int {
        var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
        func find(_ n: IsoFlat_Node) -> IsoFlat_Node? {
            if n.view == "navsplit" { return n }
            for i in 0..<n.ch.count { if let f = find(n.ch[i]) { return f } }
            return nil
        }
        func count(_ n: IsoFlat_Node) -> Int {
            var c = n.view == "navstack" ? 1 : 0
            for i in 0..<n.ch.count { c += count(n.ch[i]) }
            return c
        }
        guard let split = find(getRoot(byteBuffer: &buffer) as IsoFlat_Node), split.ch.count >= 2 else { return -1 }
        return count(split.ch[split.ch.count - 1])
    }
    func stacksInColumn(_ index: Int) -> Int {
        var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
        func find(_ n: IsoFlat_Node) -> IsoFlat_Node? {
            if n.view == "navsplit" { return n }
            for i in 0..<n.ch.count { if let f = find(n.ch[i]) { return f } }
            return nil
        }
        func count(_ n: IsoFlat_Node) -> Int {
            var c = n.view == "navstack" ? 1 : 0
            for i in 0..<n.ch.count { c += count(n.ch[i]) }
            return c
        }
        guard let split = find(getRoot(byteBuffer: &buffer) as IsoFlat_Node), split.ch.count > index else { return -1 }
        return count(split.ch[index])
    }
    let cases = [(0, "a NavigationStack", 1), (1, "a NavigationStack in a Group's if", 1),
                 (2, "an app's view whose body is a NavigationStack", 1),
                 (3, "an app's view whose body is a TabView of stacks (its selected tab's)", 1), (4, "a plain view", 1)]
    for (detailCase, label, expected) in cases {
        splitDetailCase = detailCase
        Runtime.shared.installRootView { SplitDetailScreen() }
        Runtime.shared.start(host: StubHost(), width: 1200, height: 800)
        let stacks = stacksInDetail()
        expect(stacks == expected, "a split's detail that is \(label) has \(expected) navigation bar(s), none of the split's (got \(stacks))")
    }
    Runtime.shared.installRootView { SplitSidebarStackScreen() }
    Runtime.shared.start(host: StubHost(), width: 1200, height: 800)
    let sidebarStacks = stacksInColumn(0)
    expect(sidebarStacks == 1, "a sidebar that brings its own NavigationStack has one navigation bar (got \(sidebarStacks))")
}

@MainActor
func checkProgressTint(_ mock: MockRenderer) {
    Runtime.shared.installRootView { TintedProgressScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
    var bars: [IsoFlat_Node] = []
    func collect(_ n: IsoFlat_Node) {
        if n.kind == .progress { bars.append(n) }
        for i in 0..<n.ch.count { collect(n.ch[i]) }
    }
    collect(getRoot(byteBuffer: &buffer) as IsoFlat_Node)
    let tints = bars.map { bar in bar.params.first { $0.key == "tint" }?.value }
    expect(bars.count == 3, "three bars (got \(bars.count))")
    expect(tints.count == 3 && tints[0] != nil && tints[1] != nil && tints[0] != tints[1] && tints[2] == nil,
           "a bar carries the tint set on it or around it, and an untinted one none (got \(tints))")
}

/// Rows handed a `$state` binding are reused while only the state changes
/// (a binding to the same state is the same binding); a row that reads the
/// binding's value is rebuilt with it.
nonisolated(unsafe) var bindingTick = 0
struct BindingRow: View {
    let index: Int
    let opened: Binding<Int>
    var body: some View {
        Text("Row \(index)").onTapGesture { opened.wrappedValue = index }
    }
}
struct BindingReader: View {
    let opened: Binding<Int>
    var body: some View { Text("Opened \(opened.wrappedValue)") }
}
struct BindingScreen: View {
    @State private var opened = 0
    @State private var other = 0
    var body: some View {
        VStack {
            Text("Other \(other)")
            BindingReader(opened: $opened)
            ForEach(1..<21, id: \.self) { BindingRow(index: $0, opened: $opened) }
        }
    }
}

@MainActor
func checkBindingReuse(_ mock: MockRenderer) {
    Runtime.shared.installRootView { BindingScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    let encoder = FlatTreeEncoder()
    _ = encoder.encode(root: mock.lastTree!)
    Runtime.shared.installTreeHandlers(encoder.handlers)
    let taps = encoder.handlers.keys.filter { $0.hasSuffix(".tap") }.sorted()
    guard let rowTap = taps.first else { return expect(false, "rows register taps") }
    // Tap a row: `opened` changes; the reader shows it, the rows are reused.
    let before = Runtime.shared.reusedSubtrees
    Runtime.shared.hostViewEvent(id: rowTap, value: "")
    Runtime.shared.renderFrame()
    let reused = Runtime.shared.reusedSubtrees - before
    expect(reused >= 18, "rows holding $opened are reused when it changes (got \(reused))")
    expect(!findTextInTree(mock.lastTree!, "Opened 0"), "the row reading $opened shows its new value")
}

/// A view whose own state changes is built again alone, where it stands:
/// the views above it and beside it are not built (InPlace.swift).
nonisolated(unsafe) var inPlaceScreenBuilds = 0
nonisolated(unsafe) var inPlaceSiblingBuilds = 0
@available(macOS 14.0, iOS 17.0, *)
@Observable final class InPlaceModel {
    var name = "m0"
    nonisolated(unsafe) static let shared = InPlaceModel()
}

/// Each pass at a place of its own (state is kept by place).
@available(macOS 14.0, iOS 17.0, *)
struct InPlaceRoot: View {
    let pass: Int
    var body: some View {
        if pass == 0 { InPlaceScreen() } else { InPlaceScreen() }
    }
}

@available(macOS 14.0, iOS 17.0, *)
struct InPlaceScreen: View {
    var body: some View {
        let _ = inPlaceScreenBuilds += 1
        VStack {
            Text("Header")
            InPlaceCounter(title: "A")
                .accessibilityIdentifier("counter")
            InPlaceSibling(action: {})
            InPlaceObserver(model: InPlaceModel.shared)
        }
    }
}

struct InPlaceCounter: View {
    let title: String
    @State private var count = 0
    var body: some View {
        if count == 2 {
            // Registers for the stack above: built with what is around it.
            Button("\(title) \(count)") { count += 1 }
                .navigationTitle("Two")
        } else if count >= 3 {
            // Sizes differently from before at 3 (the stack above reads it).
            Button("\(title) \(count)") { count += 1 }
                .frame(maxWidth: .infinity)
        } else {
            Button("\(title) \(count)") { count += 1 }
        }
    }
}

/// Holds a closure: built whenever the view around it is.
struct InPlaceSibling: View {
    let action: () -> Void
    var body: some View {
        let _ = inPlaceSiblingBuilds += 1
        Text("Sibling")
    }
}

@available(macOS 14.0, iOS 17.0, *)
struct InPlaceObserver: View {
    let model: InPlaceModel
    var body: some View { Text("Model \(model.name)") }
}

@MainActor
func checkInPlaceRebuild(_ mock: MockRenderer) {
    guard #available(macOS 14.0, iOS 17.0, *) else { return }
    let verifying = Runtime.shared.verifyPartialFrames
    defer { Runtime.shared.verifyPartialFrames = verifying }
    for verify in [true, false] {
        Runtime.shared.verifyPartialFrames = verify
        InPlaceModel.shared.name = "m0"
        Runtime.shared.installRootView { InPlaceRoot(pass: verify ? 0 : 1) }
        Runtime.shared.start(host: StubHost(), width: 320, height: 480)
        let encoder = FlatTreeEncoder()
        var root: PatchNode?
        _ = applyPatch(encoder.encodePatch(root: mock.lastTree!), into: &root)
        let label = verify ? " (checked against a whole build)" : ""

        @MainActor
        func frame(_ step: String, inPlace: Bool, _ change: () -> Void) {
            let screens = inPlaceScreenBuilds, siblings = inPlaceSiblingBuilds
            let partials = Runtime.shared.partialFrameCount, mismatches = Runtime.shared.partialMismatches
            change()
            Runtime.shared.renderFrame()
            let tree = mock.lastTree!
            _ = applyPatch(encoder.encodePatch(root: tree), into: &root)
            expect(describeTree(root!) == fullDescribe(tree), "\(step)\(label): applied patch == full encode")
            expect(Runtime.shared.partialMismatches == mismatches, "\(step)\(label): the frame built in place is the whole build's")
            expect((Runtime.shared.partialFrameCount > partials) == inPlace,
                   "\(step)\(label): \(inPlace ? "built in place" : "built whole")")
            if inPlace, !verify {
                expect(inPlaceScreenBuilds == screens && inPlaceSiblingBuilds == siblings,
                       "\(step): the views above and beside it are not built (\(inPlaceScreenBuilds - screens), \(inPlaceSiblingBuilds - siblings))")
            }
        }
        @MainActor
        func tapCounter() {
            let handlers = FlatTreeEncoder()
            _ = handlers.encode(root: mock.lastTree!)
            guard let tap = handlers.handlers.keys.first(where: { $0.hasSuffix(".tap") }) else {
                return expect(false, "the counter is tappable")
            }
            Runtime.shared.installTreeHandlers(handlers.handlers)
            Runtime.shared.hostViewEvent(id: tap, value: "")
        }
        frame("a view's own state", inPlace: true) { tapCounter() }
        expect(findTextInTree(mock.lastTree!, "A 1"), "the counter shows its new count\(label)")
        var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
        expect(findParam(getRoot(byteBuffer: &buffer) as IsoFlat_Node, key: "a11yId") == "counter",
               "what the modifier around it did to its node is made again\(label)")
        frame("a view that now registers a title", inPlace: false) { tapCounter() }
        expect(findTextInTree(mock.lastTree!, "A 2"), "the counter shows 2\(label)")
        frame("a view that sizes differently", inPlace: false) { tapCounter() }
        frame("the same again", inPlace: true) { tapCounter() }
        expect(findTextInTree(mock.lastTree!, "A 4"), "the counter shows 4\(label)")
        // An @Observable model: built in place on wasm and Android, where
        // the Observation scope around a view is set aside while it builds;
        // on this host the views above are marked too (ObservationSupport.swift).
        frame("an observed model", inPlace: false) { InPlaceModel.shared.name = "m1" }
        expect(findTextInTree(mock.lastTree!, "Model m1"), "the observing view shows the change\(label)")
    }
}

/// A state passed down as a binding (a composer's draft): a change rebuilds
/// the views that read it, not the view owning it nor its other children;
/// a state that no build reads rebuilds nothing.
nonisolated(unsafe) var draftOwnerBuilds = 0
nonisolated(unsafe) var draftSiblingBuilds = 0
nonisolated(unsafe) var draftBinding: Binding<String>?
nonisolated(unsafe) var draftUnreadBinding: Binding<Int>?

struct DraftRoot: View {
    let pass: Int
    var body: some View {
        if pass == 0 { DraftOwner() } else { DraftOwner() }
    }
}

struct DraftOwner: View {
    @State private var draft = ""
    @State private var unread = 0
    var body: some View {
        let _ = draftOwnerBuilds += 1
        let _ = (draftBinding = $draft)
        let _ = (draftUnreadBinding = $unread)
        VStack {
            DraftSibling(action: {})
            TextField("Message", text: $draft)
            DraftSend(text: $draft)
        }
    }
}

struct DraftSibling: View {
    let action: () -> Void
    var body: some View {
        let _ = draftSiblingBuilds += 1
        Text("Sibling")
    }
}

struct DraftSend: View {
    @Binding var text: String
    var body: some View { Text(text.isEmpty ? "Mic" : "Send") }
}

@MainActor
func checkStateReaders(_ mock: MockRenderer) {
    let verifying = Runtime.shared.verifyPartialFrames
    defer { Runtime.shared.verifyPartialFrames = verifying }
    for verify in [true, false] {
        Runtime.shared.verifyPartialFrames = verify
        Runtime.shared.installRootView { DraftRoot(pass: verify ? 0 : 1) }
        Runtime.shared.start(host: StubHost(), width: 320, height: 480)
        let encoder = FlatTreeEncoder()
        var root: PatchNode?
        _ = applyPatch(encoder.encodePatch(root: mock.lastTree!), into: &root)
        let label = verify ? " (checked against a whole build)" : ""
        @MainActor
        func frame(_ step: String, _ change: () -> Void) {
            let owners = draftOwnerBuilds, siblings = draftSiblingBuilds
            let partials = Runtime.shared.partialFrameCount, mismatches = Runtime.shared.partialMismatches
            change()
            Runtime.shared.renderFrame()
            let tree = mock.lastTree!
            _ = applyPatch(encoder.encodePatch(root: tree), into: &root)
            expect(describeTree(root!) == fullDescribe(tree), "\(step)\(label): applied patch == full encode")
            expect(Runtime.shared.partialFrameCount > partials, "\(step)\(label): built in place")
            expect(Runtime.shared.partialMismatches == mismatches, "\(step)\(label): as a whole build")
            if !verify {
                expect(draftOwnerBuilds == owners && draftSiblingBuilds == siblings,
                       "\(step): the owner and its other child are not built (\(draftOwnerBuilds - owners), \(draftSiblingBuilds - siblings))")
            }
        }
        frame("the draft typed into") { draftBinding?.wrappedValue = "h" }
        expect(findTextInTree(mock.lastTree!, "Send"), "the view reading the draft shows it\(label)")
        frame("a state no build reads") { draftUnreadBinding?.wrappedValue = 5 }
        frame("the draft cleared") { draftBinding?.wrappedValue = "" }
        expect(findTextInTree(mock.lastTree!, "Mic"), "the view reading the draft shows it cleared\(label)")
    }
}

/// A modifier's own `@State` belongs to the view it modifies, kept from
/// frame to frame (its properties are found in the view's fields).
struct CountingModifier: ViewModifier {
    @State private var taps = 0
    func body(content: Content) -> some View {
        VStack {
            content
            Button("Taps \(taps)") { taps += 1 }
        }
    }
}

struct ModifierStateScreen: View {
    var body: some View { Text("Modified").modifier(CountingModifier()) }
}

@MainActor
func checkModifierState(_ mock: MockRenderer) {
    Runtime.shared.installRootView { ModifierStateScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    for expected in ["Taps 1", "Taps 2"] {
        let encoder = FlatTreeEncoder()
        _ = encoder.encode(root: mock.lastTree!)
        guard let tap = encoder.handlers.keys.first(where: { $0.hasSuffix(".tap") }) else {
            return expect(false, "the modifier's button is tappable")
        }
        Runtime.shared.installTreeHandlers(encoder.handlers)
        Runtime.shared.hostViewEvent(id: tap, value: "")
        Runtime.shared.renderFrame()
        expect(findTextInTree(mock.lastTree!, expected), "a modifier's own state counts: \(expected)")
    }
}

/// A List row's onAppear fires as it comes on screen (within a screen of
/// what the host shows), not when the list builds it ahead; onDisappear as
/// it scrolls away.
nonisolated(unsafe) var appearedRows: Set<Int> = []
struct AppearListScreen: View {
    var body: some View {
        List {
            ForEach(0..<200, id: \.self) { index in
                Text("Row \(index)")
                    .onAppear { appearedRows.insert(index) }
                    .onDisappear { appearedRows.remove(index) }
            }
        }
    }
}

@MainActor
func checkRowAppearance(_ mock: MockRenderer) {
    appearedRows = []
    Runtime.shared.installRootView { AppearListScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    let encoder = FlatTreeEncoder()
    var buffer = ByteBuffer(bytes: encoder.encode(root: mock.lastTree!))
    guard let window = findParam(getRoot(byteBuffer: &buffer) as IsoFlat_Node, key: "window") else {
        return expect(false, "a lazy list names where the host reports its window")
    }
    Runtime.shared.installTreeHandlers(encoder.handlers)
    // The host shows rows 100–109: those and a screen around them appear,
    // though the list builds a hundred rows either way.
    Runtime.shared.hostViewEvent(id: window, value: "100,109")
    for _ in 0..<12 {
        Runtime.shared.setNeedsRender()
        Runtime.shared.renderFrame()
        // What a component-system renderer does with each tree.
        let frameEncoder = FlatTreeEncoder()
        _ = frameEncoder.encode(root: mock.lastTree!)
        Runtime.shared.fireTreeAppearances(frameEncoder.appearances, disappearances: frameEncoder.disappearances)
    }
    expect(appearedRows.contains(100) && appearedRows.contains(109) && appearedRows.contains(92),
           "the rows shown and a screen around them appeared")
    expect(!appearedRows.contains(60) && !appearedRows.contains(150), "rows built ahead have not appeared (\(appearedRows.count))")
    // Scrolling (a report alone, no render): rows come and go.
    Runtime.shared.hostViewEvent(id: window, value: "140,149")
    expect(appearedRows.contains(145) && !appearedRows.contains(100), "scrolling appears the rows reached and disappears those left")
}

@main
struct Main {
    static func main() {
        let mock = MockRenderer()
        Renderer.bind(mock)
        // Every frame built in place is checked against the whole build of
        // the same changes, all through (InPlace.swift).
        Runtime.shared.verifyPartialFrames = true
        // What kind of view each type is, read from its `Body`, checked
        // against the casts it replaced.
        _verifyViewKinds = true
        Runtime.shared.installRootView { ToggleScreen() }
        Runtime.shared.start(host: StubHost(), width: 320, height: 480)

        expect(mock.renderCount >= 1, "start renders through the bound renderer")
        guard let tree = mock.lastTree else {
            print("FAIL: no tree delivered")
            exit(1)
        }

        // The canonical tree carries chrome as semantic host views — the
        // renderer decides how to visualize them; the core does not. The
        // wire format is the tree.fbs FlatBuffer.
        let encoder = FlatTreeEncoder()
        let bytes = encoder.encode(root: tree)
        expect(!bytes.isEmpty, "encoder produces a buffer")
        expect(
            encoder.handlers.keys.contains { $0.hasSuffix(".host") },
            "toggle onChange registers a host handler")
        var buffer = ByteBuffer(bytes: bytes)
        let root = getRoot(byteBuffer: &buffer) as IsoFlat_Node
        expect(findToggle(root)?.v == "0", "toggle serializes off as a semantic host view")
        expect(findText(root, "Settings"), "text serializes")

        // A state change re-renders through the same opaque API.
        let before = mock.renderCount
        flag = true
        Runtime.shared.setNeedsRender()
        Runtime.shared.renderFrame()
        expect(mock.renderCount == before + 1, "state change renders exactly once more")
        let encoder2 = FlatTreeEncoder()
        var buffer2 = ByteBuffer(bytes: encoder2.encode(root: mock.lastTree!))
        let root2 = getRoot(byteBuffer: &buffer2) as IsoFlat_Node
        expect(findToggle(root2)?.v == "1", "flipped toggle serializes as on")

        checkDiffAwarePatches(mock)
        checkKeyedList(mock)
        checkSubtreeReuse(mock)
        checkSizeClassResize(mock)
        checkLazyRows(mock)
        checkTaskCancellation(mock)
        checkOnChangeAfterReappearing(mock)
        checkStateMacro(mock)
        checkButtonRoles(mock)
        checkDisabledBarItems(mock)
        checkInspectorPlacement(mock)
        checkDismissFromSheetToolbar(mock)
        checkPickerInFormRow(mock)
        checkValueNavigation(mock)
        checkListSectionFooter(mock)
        checkAlignmentGuideInOverlay(mock)
        checkFloatingProbeBuilds(mock)
        checkKeyPress(mock)
        checkModifierOverGroup(mock)
        checkScrollEdgeStyle(mock)
        checkProgressTint(mock)
        checkCustomShape(mock)
        checkOpenURL(mock)
        checkLink(mock)
        checkRegistrationReplay(mock)
        checkToolbarContent(mock)
        checkLargeTitleOnce(mock)
        checkBindingReadScope(mock)
        checkListInReusedView(mock)
        checkFocusStateReuse(mock)
        checkScrollToUnbuiltRow(mock)
        checkPushInReusedStack(mock)
        checkAnimationInReusedTree(mock)
        checkEncoderLiveValues(mock)
        checkScrollDisabled(mock)
        checkCappedScrollGreediness(mock)
        checkScrollPhaseOnAppear(mock)
        checkNativeChrome(mock)
        checkMarkdownLiteral(mock)
        checkObservation(mock)
        checkSplitDetailStack(mock)
        checkMultiViewBody(mock)
        checkTextSelection(mock)
        checkBindingReuse(mock)
        checkRowAppearance(mock)
        checkInPlaceRebuild(mock)
        checkModifierState(mock)
        checkStateReaders(mock)
        checkAPIAdditions(mock)
        checkCompactSplitBack(mock)

        // Row actions: the tagged row is a tap target and carries its menu.
        Runtime.shared.installRootView { RowScreen() }
        Runtime.shared.start(host: StubHost(), width: 320, height: 480)
        if let rowTree = mock.lastTree {
            let rowEncoder = FlatTreeEncoder()
            var rowBuffer = ByteBuffer(bytes: rowEncoder.encode(root: rowTree))
            let rowRoot = getRoot(byteBuffer: &rowBuffer) as IsoFlat_Node
            expect(findTappableAncestor(rowRoot, ofText: "Alpha"), "a tagged row behind swipeActions/contextMenu is selectable")
            expect(rowEncoder.handlers.keys.contains { $0.hasSuffix(".ctx") }, "the context menu registers its handler")
            expect(findParam(rowRoot, key: "ctxitems")?.contains("Rename") == true, "a Label's title, not its glyph, names the menu item")
            expect(rowEncoder.handlers.keys.contains { $0.hasSuffix(".swipe") }, "the swipe actions register their handler")
        } else {
            expect(false, "row screen rendered")
        }

        expect(Runtime.shared.partialMismatches == 0,
               "frames built in place match the whole builds (\(Runtime.shared.partialMismatches) of \(Runtime.shared.partialFrameCount) differ)")
        print("frames built in place: \(Runtime.shared.partialFrameCount)")
        expect(_viewKindMismatches.isEmpty, "view kinds read from Body match the casts (\(_viewKindMismatches.prefix(5)))")

        if failures > 0 {
            print("FAILED: \(failures) check(s)")
            exit(1)
        }
        print("OK: mock renderer checks passed")
    }
}


/// Depth-first search for the toggle host-view node.
func findToggle(_ node: IsoFlat_Node) -> IsoFlat_Node? {
    if node.kind == .hostview, node.view == "toggle" { return node }
    for child in node.ch {
        if let found = findToggle(child) { return found }
    }
    return nil
}

/// The first value of a param with the key, anywhere in the tree.
func findParam(_ node: IsoFlat_Node, key: String) -> String? {
    for kv in node.params where kv.key == key { return kv.value }
    for child in node.ch {
        if let found = findParam(child, key: key) { return found }
    }
    return nil
}

/// Whether a node with the text has a tappable node above (or at) it.
func findTappableAncestor(_ node: IsoFlat_Node, ofText value: String, tapAbove: Bool = false) -> Bool {
    let tappable = tapAbove || node.tap != nil
    if node.kind == .text, node.v == value { return tappable }
    for child in node.ch {
        if findTappableAncestor(child, ofText: value, tapAbove: tappable) { return true }
    }
    return false
}

/// Depth-first search for a text node with the given value.
func findText(_ node: IsoFlat_Node, _ value: String) -> Bool {
    if node.kind == .text, node.v == value { return true }
    for child in node.ch {
        if findText(child, value) { return true }
    }
    return false
}

// MARK: - Diff-aware patch round-trip

/// The host's retained node: own-attribute description + children. Mirrors what
/// a component-system host (Compose UNode / SwiftUI) keeps and patches in place.
final class PatchNode {
    var desc: String
    var children: [PatchNode]
    init(_ desc: String, _ children: [PatchNode]) {
        self.desc = desc
        self.children = children
    }
}

/// Own attributes (children excluded) the round-trip compares on.
func ownDescribe(_ n: IsoFlat_Node) -> String {
    "k=\(n.kind.rawValue);key=\(n.key ?? "");v=\(n.v ?? "");num=\(n.num ?? -1);edit=\(n.edit ?? "");"
        + "tap=\(n.tap ?? "");color=\(n.color.map { "\($0.r),\($0.g),\($0.b),\($0.a)" } ?? "")"
}

func buildPatchNode(_ n: IsoFlat_Node) -> PatchNode {
    PatchNode(ownDescribe(n), (0..<n.ch.count).map { buildPatchNode(n.ch[$0]) })
}

func describeTree(_ n: PatchNode) -> String {
    "[" + n.desc + n.children.map(describeTree).joined() + "]"
}

func describeTreeFB(_ n: IsoFlat_Node) -> String {
    "[" + ownDescribe(n) + (0..<n.ch.count).map { describeTreeFB(n.ch[$0]) }.joined() + "]"
}

func countFB(_ n: IsoFlat_Node) -> Int {
    1 + (0..<n.ch.count).reduce(0) { $0 + countFB(n.ch[$1]) }
}

/// The full-encode of a tree, described canonically — the oracle the applied
/// patch stream must reproduce.
func fullDescribe(_ tree: RenderNode) -> String {
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: tree))
    return describeTreeFB(getRoot(byteBuffer: &buffer) as IsoFlat_Node)
}

/// Applies a `Patch` buffer to the retained `root`, returning the op count. The
/// reference implementation of what every host does (Compose FlatTree.applyPatch,
/// etc.): `attrsOnly` keeps the retained children; otherwise rebuild the subtree.
func applyPatch(_ bytes: [UInt8], into root: inout PatchNode?) -> Int {
    var buffer = ByteBuffer(bytes: bytes)
    let patch = getRoot(byteBuffer: &buffer) as IsoFlat_Patch
    for index in 0..<patch.ops.count {
        let op = patch.ops[index]
        guard let path = op.path else { continue }
        let segments = path.split(separator: ".").dropFirst().map { Int($0)! } // drop "n"
        if op.order.count > 0 {
            var target = root!
            for segment in segments { target = target.children[segment] }
            let old = target.children
            var inserted = 0
            target.children = op.order.map { index -> PatchNode in
                if index >= 0 { return old[Int(index)] }
                defer { inserted += 1 }
                return buildPatchNode(op.inserts[inserted])
            }
            continue
        }
        guard let node = op.node else { continue }
        if segments.isEmpty {
            root = op.attrsOnly
                ? PatchNode(ownDescribe(node), root?.children ?? [])
                : buildPatchNode(node)
            continue
        }
        var cursor = root!
        for segment in segments.dropLast() { cursor = cursor.children[segment] }
        let index = segments.last!
        cursor.children[index] = op.attrsOnly
            ? PatchNode(ownDescribe(node), cursor.children[index].children)
            : buildPatchNode(node)
    }
    return patch.ops.count
}

/// End-to-end: encoding a tree as patches and applying them reproduces the
/// full-encode, the first patch is one root op, and a state flip ships a small
/// patch (not a full re-send).
@MainActor
func checkDiffAwarePatches(_ mock: MockRenderer) {
    let encoder = FlatTreeEncoder()

    flag = false
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    let tree0 = mock.lastTree!
    var root: PatchNode?
    let ops0 = applyPatch(encoder.encodePatch(root: tree0), into: &root)
    expect(ops0 == 1, "first patch is a single root op carrying the full tree")
    expect(describeTree(root!) == fullDescribe(tree0), "applied first patch == full encode")

    flag = true
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    let tree1 = mock.lastTree!
    var full1 = ByteBuffer(bytes: FlatTreeEncoder().encode(root: tree1))
    let nodeCount = countFB(getRoot(byteBuffer: &full1) as IsoFlat_Node)
    let ops1 = applyPatch(encoder.encodePatch(root: tree1), into: &root)
    expect(ops1 >= 1, "a state change emits at least one op")
    expect(ops1 < nodeCount, "the patch is smaller than a full re-send (\(ops1) < \(nodeCount))")
    expect(describeTree(root!) == fullDescribe(tree1), "applied patch == full encode of changed tree")
}

/// `onScrollPhaseChange` runs once as its scroll view appears, idle to idle,
/// as SwiftUI's does (Apple's, logged on a simulator: `idle -> idle` at the
/// first frame), and not again for the same scroll view.
nonisolated(unsafe) var scrollPhaseCalls: [String] = []
struct ScrollPhaseAppearScreen: View {
    var body: some View {
        ScrollView { Text("Row") }
            .onScrollPhaseChange { oldPhase, newPhase in scrollPhaseCalls.append("\(oldPhase) -> \(newPhase)") }
    }
}

@MainActor
func checkScrollPhaseOnAppear(_ mock: MockRenderer) {
    scrollPhaseCalls = []
    Runtime.shared.installRootView { ScrollPhaseAppearScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    for _ in 0..<3 {
        Runtime.shared.setNeedsRender()
        Runtime.shared.renderFrame()
        let encoder = FlatTreeEncoder()
        _ = encoder.encode(root: mock.lastTree!)
        Runtime.shared.fireTreeAppearances(encoder.appearances, disappearances: encoder.disappearances)
    }
    expect(scrollPhaseCalls == ["idle -> idle"], "the action ran once as the scroll view appeared, idle to idle (\(scrollPhaseCalls))")
}
