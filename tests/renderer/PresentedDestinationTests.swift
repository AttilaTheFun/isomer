// navigationDestination(isPresented:) and (item:): a binding pushes a
// screen onto the enclosing stack, Back sets it false (or nil), another
// item replaces the screen, and the app clearing the binding while the
// screen shows takes it off (its declaring screen unbuilt then).

import Foundation
import SwiftUI  // IsomerCore, aliased (BUILD.bazel)

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
