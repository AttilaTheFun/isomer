// The minimal benchmark app: a "Tap me" button and a label counting taps.
// Deliberately tiny and identical (by behavior) to the native-Compose, Valdi,
// and React Native counter apps, so the cross-framework benchmark measures each
// framework's delivery/runtime overhead — not app content. Delivered three ways
// off this one source: compiled to an Android .so, and as a wasm reactor run
// interpreted or AOT. See docs/benchmarks.md.
import SwiftUI

@main
struct TapCounterApp: App {
    var body: some Scene {
        WindowGroup {
            CounterView()
        }
    }
}

/// Benchmark bridge (the iOS on-device cells; see apple/libraries/bench):
/// lets the harness drive the same state mutation a tap performs. A single
/// closure assignment on appear; dormant otherwise, on every platform.
public enum TapCounterBenchBridge {
    nonisolated(unsafe) public static var increment: (() -> Void)?
    /// Fires at the Button action's first instruction — the UIEvent → handler
    /// edge, the interaction benchmark's signpost-begin anchor.
    nonisolated(unsafe) public static var onTap: (() -> Void)?
    /// Fires at each body evaluation — lets the harness anchor "the framework
    /// applied the update" and attach a commit-completion observer.
    nonisolated(unsafe) public static var bodyTick: (() -> Void)?
}

struct CounterView: View {
    @State private var count = 0

    var body: some View {
        let _ = TapCounterBenchBridge.bodyTick?()
        return VStack(spacing: 24) {
            Text("Tapped \(count) time\(count == 1 ? "" : "s")")
                .font(.system(size: 20))
                .foregroundColor(.gray)

            Button {
                TapCounterBenchBridge.onTap?()
                count += 1
            } label: {
                Text("Tap me")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(Color(red: 0.35, green: 0.34, blue: 0.84))
                    .cornerRadius(10)
            }
        }
        .padding(40)
        .onAppear { TapCounterBenchBridge.increment = { count += 1 } }
    }
}
