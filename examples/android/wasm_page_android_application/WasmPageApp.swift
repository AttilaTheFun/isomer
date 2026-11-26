// A compiled Isomer app with a wasm page inside it: its own counter, in
// compiled Swift, above the tap counter's reactor drawn by WasmView in a tree
// of its own. Each "Tap me" counts only its own taps: the page's events go to
// its reactor, the app's to the app (IsoTreeState, LocalIsoEvents). The
// engine is bound in this app's library (`wasm_view = True`), one Swift
// runtime for both.
import Isomer
import SwiftUI

@main
struct WasmPageApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                CompiledCounter()
                Divider()
                TapCounterPage()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, 24)
        }
    }
}

struct CompiledCounter: View {
    @State private var count = 0

    var body: some View {
        VStack(spacing: 12) {
            Text("Compiled: \(count)")
            Button("Tap me") { count += 1 }
        }
    }
}

/// The page: the reactor packaged as the APK's tap_counter_release.wasm,
/// drawn by the Kotlin factory WasmPages registers for "wasm:page".
struct TapCounterPage: PlatformViewRepresentable {
    var kind: String { "wasm:page" }
    var value: String { "tap_counter_release.wasm" }
    func onValueChanged(_ value: String) {}
}
