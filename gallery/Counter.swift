// Counter — the smallest example: a button that counts taps. Shared by the
// example apps (a catalog entry) and the Playground (a project template).

import SwiftUI

struct CounterScreen: View {
    @State private var count = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Hello from Isomer!")
                .font(.title2)
            Text("Tapped \(count) times")
                .foregroundColor(.secondary)
            Button("Tap me") { count += 1 }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Counter")
    }
}
