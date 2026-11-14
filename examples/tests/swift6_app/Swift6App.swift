// An app's Swift 6 code, as it builds against Apple's SwiftUI: SwiftUI's
// values kept in a Sendable type and sent across actors, and main-actor
// closures handed to Button.

import SwiftUI

struct Row: Sendable {
    let title: Text
    let icon: Image
    let shape: RoundedRectangle
    let fill: LinearGradient
    let style: AnyShapeStyle
    let gap: Spacer
}

@MainActor
final class Model {
    var count = 0
    func refresh() { count += 1 }
}

struct Swift6View: View {
    let onRefresh: @MainActor () -> Void
    let model: Model

    var body: some View {
        VStack {
            Button("Refresh", action: onRefresh)
            Button(action: model.refresh) { Text("Again") }
            Button("Delete", role: .destructive, action: onRefresh)
        }
    }
}

func title(of row: Row) async -> Text {
    await Task.detached { row.title }.value
}
