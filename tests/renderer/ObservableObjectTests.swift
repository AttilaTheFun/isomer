// ObservableObject models (ObservableObject.swift): @StateObject made once,
// @ObservedObject and @EnvironmentObject rebuilding on objectWillChange,
// bindings through $model, and onReceive. On the host the core's Combine is
// Apple's; off Apple, Isomer's (frameworks/combine) behaves the same.

import Combine
import Foundation
import SwiftUI  // IsomerCore, aliased (BUILD.bazel)

final class PublishedCounter: ObservableObject {
    /// How many were made, and the latest: the one the screen's
    /// @StateObject holds.
    nonisolated(unsafe) static var made = 0
    nonisolated(unsafe) static weak var latest: PublishedCounter?
    @Published var count = 0
    @Published var title = "Taps"
    let pings = PassthroughSubject<Int, Never>()

    init() {
        PublishedCounter.made += 1
        PublishedCounter.latest = self
    }
}

nonisolated(unsafe) var counterPings: [Int] = []

struct PublishedCounterScreen: View {
    @StateObject private var model = PublishedCounter()

    var body: some View {
        VStack {
            PublishedCounterLabel(model: model)
            PublishedCounterTitleField()
        }
        .environmentObject(model)
        .onReceive(model.pings) { counterPings.append($0) }
    }
}

struct PublishedCounterLabel: View {
    @ObservedObject var model: PublishedCounter
    var body: some View { Text("\(model.title) \(model.count)") }
}

struct PublishedCounterTitleField: View {
    @EnvironmentObject private var model: PublishedCounter
    var body: some View {
        TextField("Title", text: $model.title)
        Text("env \(model.count)")
    }
}

@MainActor
func checkObservableObject(_ mock: MockRenderer) {
    PublishedCounter.made = 0
    counterPings = []
    Runtime.shared.installRootView { PublishedCounterScreen() }
    Runtime.shared.start(host: StubHost(), width: 320, height: 480)
    Runtime.shared.setNeedsRender()
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "Taps 0"), "@ObservedObject shows the model")
    expect(findTextInTree(mock.lastTree!, "env 0"), "@EnvironmentObject finds the model")
    expect(PublishedCounter.made == 1, "@StateObject made its object once (\(PublishedCounter.made))")

    let encoder = FlatTreeEncoder()
    _ = encoder.encode(root: mock.lastTree!)
    guard let field = encoder.handlers.keys.first(where: { $0.hasSuffix(".text") }) else {
        expect(false, "the title field is a host target")
        return
    }
    // A binding through $model: the field's edit writes the object, and the
    // label that observes it shows the new title.
    Runtime.shared.installTreeHandlers(encoder.handlers)
    Runtime.shared.hostViewEvent(id: field, value: "Hits")
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "Hits 0"), "$model.title wrote the object and the label rebuilt")

    // Frames built again keep the same object (@StateObject's thunk is not
    // run again) and a @Published write rebuilds its observers.
    for _ in 0..<3 {
        Runtime.shared.setNeedsRender()
        Runtime.shared.renderFrame()
    }
    expect(PublishedCounter.made == 1, "@StateObject kept its object across builds (\(PublishedCounter.made))")
    guard let model = PublishedCounter.latest else {
        expect(false, "the screen's model is reachable")
        return
    }
    model.count = 5
    Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "Hits 5"), "a @Published write rebuilt the @ObservedObject view")
    expect(findTextInTree(mock.lastTree!, "env 5"), "and the @EnvironmentObject view")

    // onReceive: each value the subject sends reaches the action.
    model.pings.send(1)
    model.pings.send(2)
    expect(counterPings == [1, 2], "onReceive got the subject's values (\(counterPings))")
}
