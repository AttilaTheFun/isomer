// navigationDestination(isPresented:) and (item:): a binding pushes a
// screen onto the enclosing stack, Back sets it false (or nil), another
// item replaces the screen, and the app clearing the binding while the
// screen shows takes it off (its declaring screen unbuilt then).

import FlatBuffers
import Foundation
import SwiftUI  // IsomerCore, aliased (BUILD.bazel)
import IsomerSwiftUI

nonisolated(unsafe) var presentedShowSettings = false
nonisolated(unsafe) var presentedItem: Int?

struct PresentedScreen: View {
    @Binding var showSettings: Bool
    @Binding var item: Int?

    var body: some View {
        NavigationStack {
            VStack {
                Text("Root")
                Button("Settings") { showSettings = true }
            }
            .navigationDestination(isPresented: $showSettings) { Text("Settings page") }
            .navigationDestination(item: $item) { value in Text("Item \(value)") }
        }
    }
}

@MainActor
func checkPresentedDestinations(_ mock: MockRenderer) {
    presentedShowSettings = false
    presentedItem = nil
    let showSettings = Binding(get: { presentedShowSettings }, set: { presentedShowSettings = $0; Runtime.shared.setNeedsRender() })
    let item = Binding<Int?>(get: { presentedItem }, set: { presentedItem = $0; Runtime.shared.setNeedsRender() })
    Runtime.shared.installRootView { PresentedScreen(showSettings: showSettings, item: item) }
    Runtime.shared.start(host: StubHost(), width: 390, height: 760)
    @MainActor func settle() {
        for _ in 0..<4 {
            Runtime.shared.setNeedsRender()
            Runtime.shared.renderFrame()
        }
    }
    settle()
    expect(findTextInTree(mock.lastTree!, "Root"), "presented: the root shows first")

    // isPresented: true pushes; Back pops and sets it false.
    presentedShowSettings = true
    settle()
    expect(findTextInTree(mock.lastTree!, "Settings page"), "isPresented true pushes its destination")
    expect(Runtime.shared.handleBackButton(), "Back is taken on the presented screen")
    settle()
    expect(!presentedShowSettings, "Back set isPresented false")
    expect(findTextInTree(mock.lastTree!, "Root"), "the root shows again after Back")

    // item: a value pushes, another replaces it, nil (while it shows) takes it off.
    presentedItem = 3
    settle()
    expect(findTextInTree(mock.lastTree!, "Item 3"), "item 3 pushes its destination")
    presentedItem = 4
    settle()
    expect(findTextInTree(mock.lastTree!, "Item 4") && !findTextInTree(mock.lastTree!, "Item 3"), "another item replaces the screen")
    presentedItem = nil
    settle()
    expect(findTextInTree(mock.lastTree!, "Root") && !findTextInTree(mock.lastTree!, "Item 4"), "item nil takes the screen off")

    // Back on an item's screen sets it nil.
    presentedItem = 7
    settle()
    expect(findTextInTree(mock.lastTree!, "Item 7"), "item 7 pushes")
    expect(Runtime.shared.handleBackButton(), "Back is taken on the item's screen")
    settle()
    expect(presentedItem == nil, "Back set the item nil (\(String(describing: presentedItem)))")
}

// confirmationDialog about an item, and about presented data with a message.

nonisolated(unsafe) var dialogItem: String?

struct ItemDialogScreen: View {
    let item: Binding<String?>
    var body: some View {
        Text("Files")
            .confirmationDialog("Delete?", item: item) { name in
                Button("Delete \(name)", role: .destructive) {}
            } message: { name in
                Text("\(name)'s files go too.")
            }
            .confirmationDialog(Text("Share?"), isPresented: .constant(true), presenting: Optional("Bo")) { name in
                Button("Share with \(name)") {}
            } message: { name in
                Text("\(name) sees it all.")
            }
    }
}

@MainActor
func checkItemDialogs(_ mock: MockRenderer) {
    dialogItem = nil
    let item = Binding<String?>(get: { dialogItem }, set: { dialogItem = $0; Runtime.shared.setNeedsRender() })
    Runtime.shared.installRootView { ItemDialogScreen(item: item) }
    Runtime.shared.start(host: StubHost(), width: 390, height: 760)
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    expect(!findTextInTree(mock.lastTree!, "Delete Ada"), "no item: no dialog")
    expect(findTextInTree(mock.lastTree!, "Share with Bo"), "a dialog presenting data makes its actions from it")
    dialogItem = "Ada"
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "Delete Ada"), "an item shows its dialog, the actions made from it")
    dialogItem = nil
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    expect(!findTextInTree(mock.lastTree!, "Delete Ada"), "the item nil again takes the dialog away")
}

// An alert about an item (a literal title: the LocalizedStringKey form).

nonisolated(unsafe) var alertItem: String?

struct ItemAlertScreen: View {
    let item: Binding<String?>
    var body: some View {
        Text("Inbox")
            .alert("Archived", item: item) { name in
                Button("Undo \(name)") {}
            } message: { name in
                Text("\(name) moved to the archive.")
            }
    }
}

@MainActor
func checkItemAlerts(_ mock: MockRenderer) {
    alertItem = nil
    let item = Binding<String?>(get: { alertItem }, set: { alertItem = $0; Runtime.shared.setNeedsRender() })
    Runtime.shared.installRootView { ItemAlertScreen(item: item) }
    Runtime.shared.start(host: StubHost(), width: 390, height: 760)
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    expect(!findTextInTree(mock.lastTree!, "Undo Mail"), "no item: no alert")
    alertItem = "Mail"
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "Undo Mail"), "an item shows its alert, the actions made from it")
    alertItem = nil
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    expect(!findTextInTree(mock.lastTree!, "Undo Mail"), "the item nil again takes the alert away")
}

// progressViewStyle: a built-in style reaches the host by kind; an app's
// style makes the view from the configuration.

struct PercentStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        Text("done \(Int((configuration.fractionCompleted ?? 0) * 100))%")
    }
}

struct ProgressStyleScreen: View {
    var body: some View {
        VStack {
            ProgressView(value: 0.5).progressViewStyle(.circular)
            ProgressView(value: 0.25).progressViewStyle(PercentStyle())
        }
    }
}

@MainActor
func checkProgressViewStyle(_ mock: MockRenderer) {
    Runtime.shared.installRootView { ProgressStyleScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 760)
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "done 25%"), "an app's ProgressViewStyle makes the view")
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
    let root = getRoot(byteBuffer: &buffer) as IsoFlat_Node
    expect(allParams(root, key: "pstyle") == ["circular"], "a built-in style reaches the host by kind (\(allParams(root, key: "pstyle")))")
}

// Gestures: TapGesture through the tap handler; LongPressGesture with
// @GestureState (true while pressed, reset when it ends) and onEnded; and
// onLongPressGesture's perform and pressing.

nonisolated(unsafe) var gestureLog: [String] = []

struct GestureScreen: View {
    @GestureState private var pressing = false

    var body: some View {
        VStack {
            Text("tap me").gesture(TapGesture().onEnded { gestureLog.append("tapped") })
            Text(pressing ? "pressing" : "idle")
                .gesture(LongPressGesture(minimumDuration: 1)
                    .updating($pressing) { value, state, _ in state = value }
                    .onEnded { _ in gestureLog.append("long") })
            Text("hold").onLongPressGesture(perform: { gestureLog.append("held") },
                                            onPressingChanged: { gestureLog.append("pressing \($0)") })
        }
    }
}

@MainActor
func checkGestures(_ mock: MockRenderer) {
    gestureLog = []
    Runtime.shared.installRootView { GestureScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 760)
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    func handlers() -> [String: (String) -> Void] {
        let encoder = FlatTreeEncoder()
        _ = encoder.encode(root: mock.lastTree!)
        Runtime.shared.installTreeHandlers(encoder.handlers)
        return encoder.handlers
    }
    let first = handlers()
    let taps = first.keys.filter { $0.hasSuffix(".tap") }
    let presses = first.keys.filter { $0.hasSuffix(".longpress") }.sorted()
    expect(taps.count == 1, "TapGesture gives the view a tap (\(taps))")
    expect(presses.count == 2, "both long presses reach the host (\(presses))")
    if let tap = taps.first { Runtime.shared.hostViewEvent(id: tap, value: "") }
    expect(gestureLog == ["tapped"], "the tap ran onEnded (\(gestureLog))")

    // The LongPressGesture: pressing sets the @GestureState, the press held
    // runs onEnded, lifting resets the state.
    guard presses.count == 2 else { return }
    for id in presses { Runtime.shared.hostViewEvent(id: id, value: "press:1") }
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "pressing"), "@GestureState is true while pressed")
    _ = handlers()
    for id in presses { Runtime.shared.hostViewEvent(id: id, value: "fire") }
    for id in presses { Runtime.shared.hostViewEvent(id: id, value: "press:0") }
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "idle"), "@GestureState goes back when the press ends")
    expect(gestureLog.contains("long") && gestureLog.contains("held"), "both presses ran their action (\(gestureLog))")
    expect(gestureLog.contains("pressing true") && gestureLog.contains("pressing false"), "onPressingChanged saw down and up (\(gestureLog))")
}

// layoutPriority reaches the host, which lays the row out by it.
@MainActor
func checkLayoutPriority(_ mock: MockRenderer) {
    Runtime.shared.installRootView { HStack { Text("first").layoutPriority(1); Text("second") } }
    Runtime.shared.start(host: StubHost(), width: 390, height: 760)
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
    let root = getRoot(byteBuffer: &buffer) as IsoFlat_Node
    expect(allParams(root, key: "layoutPriority") == ["1"], "layoutPriority reaches the host (\(allParams(root, key: "layoutPriority")))")
}

// List editing: EditButton turns editing on; a deletable row's minus
// deletes it; a movable row's handle, dragged a row down, moves it.

nonisolated(unsafe) var editItems = ["Ann", "Bo", "Cy"]

struct EditingScreen: View {
    var body: some View {
        VStack {
            EditButton()
            List {
                ForEach(editItems, id: \.self) { Text($0) }
                    .onDelete { editItems.remove(atOffsets: $0); Runtime.shared.setNeedsRender() }
                    .onMove { editItems.move(fromOffsets: $0, toOffset: $1); Runtime.shared.setNeedsRender() }
            }
        }
    }
}

/// A tree's tap or drag ids, in tree order.
func orderedIDs(_ node: IsoFlat_Node, drag: Bool) -> [String] {
    var out: [String] = []
    if let id = drag ? node.drag : node.tap, !id.isEmpty { out.append(id) }
    for child in node.ch { out += orderedIDs(child, drag: drag) }
    return out
}

@MainActor
func checkListEditing(_ mock: MockRenderer) {
    editItems = ["Ann", "Bo", "Cy"]
    Runtime.shared.installRootView { EditingScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 760)
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    /// This frame's taps and drags in tree order, its handlers installed.
    func frame() -> (taps: [String], drags: [String]) {
        let encoder = FlatTreeEncoder()
        var buffer = ByteBuffer(bytes: encoder.encode(root: mock.lastTree!))
        Runtime.shared.installTreeHandlers(encoder.handlers)
        let root = getRoot(byteBuffer: &buffer) as IsoFlat_Node
        return (orderedIDs(root, drag: false), orderedIDs(root, drag: true))
    }
    expect(findTextInTree(mock.lastTree!, "Edit"), "EditButton reads Edit")
    let before = frame()
    expect(before.drags.isEmpty, "no move handles until editing")
    guard let edit = before.taps.first else { return expect(false, "EditButton is a tap target") }
    Runtime.shared.hostViewEvent(id: edit, value: "")
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "Done"), "editing: the button reads Done")
    let editing = frame()
    expect(editing.drags.count == 3, "each row has a move handle while editing (\(editing.drags.count))")
    // Ann's handle dragged one row down: Bo, Ann, Cy.
    if let first = editing.drags.first {
        Runtime.shared.hostViewEvent(id: first, value: "changed:0,50")
        Runtime.shared.hostViewEvent(id: first, value: "ended:0,50")
    }
    Runtime.shared.renderFrame()
    expect(editItems == ["Bo", "Ann", "Cy"], "a handle dragged a row down moved its row (\(editItems))")
    // A minus deletes its row: the taps now are Done and the three minuses.
    let taps = frame().taps
    expect(taps.count == 4, "Done and a minus per row (\(taps.count))")
    if taps.count == 4 { Runtime.shared.hostViewEvent(id: taps[3], value: "") }
    Runtime.shared.renderFrame()
    expect(editItems == ["Bo", "Ann"], "the last row's minus deleted it (\(editItems))")
    // Done: editing off, no handles.
    if let done = frame().taps.first { Runtime.shared.hostViewEvent(id: done, value: "") }
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "Edit") && frame().drags.isEmpty, "Done ends editing")
}
