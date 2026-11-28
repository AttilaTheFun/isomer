// A text field whose Return key the app takes (`.onKeyPress(.return)`),
// counting them: the page //tests/wasm_key_event's test sends keys to.
import SwiftUI

@main
struct KeyPressApp: App {
    var body: some Scene {
        WindowGroup {
            KeyPressView()
        }
    }
}

struct KeyPressView: View {
    @State private var text = ""
    @State private var returns = 0

    var body: some View {
        VStack(spacing: 12) {
            TextField("Type", text: $text)
                .onKeyPress(.return) {
                    returns += 1
                    return .handled
                }
            Text("Returns: \(returns)")
        }
    }
}
