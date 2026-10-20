// The floating probe (shared/floating_probe_application) as a wasm reactor
// in WasmView, whose tree renderer draws the menu an alignment guide moves
// over the navigation bar (under the bar for now: the web and Android lift
// such a menu above their bars, this renderer not yet). Simulator builds:
// `--ios_multi_cpus=sim_arm64`.

import IsomerWasmView
import SwiftUI

@main
struct FloatingProbeiOSApp: App {
    @StateObject private var model = WasmViewModel()

    var body: some Scene {
        WindowGroup {
            WasmView(model: model, provider: AppBundleProvider(resource: "floating_probe"))
        }
    }
}
