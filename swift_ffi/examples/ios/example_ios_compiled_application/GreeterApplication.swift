// The Apple consumer of the shared Greeter library. On Apple platforms there
// is no bridge: the swift_ffi annotations are inert validating markers, and
// the app calls the Swift functions directly.
import Greeter
import SwiftUI

@main
struct GreeterApplication: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    private let lines: [String] = {
        let counter = makeCounter(named: "taps")
        _ = counter.increment()
        _ = counter.increment()
        _ = counter.increment()
        return [
            greeting(for: "iOS"),
            "add(19, 23) = \(add(19, 23))",
            "isEven(42) = \(isEven(42))",
            counter.label(),
        ]
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(lines, id: \.self) { line in
                Text(line)
            }
        }
        .padding()
    }
}
