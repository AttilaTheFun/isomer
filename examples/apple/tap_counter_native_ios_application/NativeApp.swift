// The NATIVE iOS baseline for the minimal "Tap me" counter benchmark
// (docs/benchmarks.md#ios) — the performance ceiling. Hand-written real
// SwiftUI, sharing NO Isomer code; behavior/pixel-identical to the
// compiled/wasm cells and the Android/RN/Valdi twins.

import SwiftUI
import UIKit

/// UIApplicationDelegateAdaptor: the SwiftUI-blessed early lifecycle hook —
/// stamps didFinishLaunching so the harness can split startup into
/// process-start→launch (dyld + pre-main) vs launch→first-content.
final class BenchAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BenchHarness.launchedAt = CACurrentMediaTime()
        return true
    }
}

@main
struct NativeTapCounterApp: App {
    @UIApplicationDelegateAdaptor(BenchAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            CounterScreen()
        }
    }
}

struct CounterScreen: View {
    @State private var count = 0

    var body: some View {
        let _ = BenchHarness.noteBodyTick()
        return VStack(spacing: 24) {
            Text("Tapped \(count) time\(count == 1 ? "" : "s")")
                .font(.system(size: 20))
                .foregroundColor(.gray)

            Button {
                InteractionSignpost.tapReceived()
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
        .onAppear { BenchHarness.tapTrigger = { count += 1 } }
    }
}
