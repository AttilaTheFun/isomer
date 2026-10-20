// The network probe in a WasmView: the reactor's URLSession goes through the
// network hosts WasmView injects by default (Apple's URLSession), with no
// dependencies of the app's own. See BUILD.bazel for the run.

import IsomerWasmView
import SwiftUI

@main
struct NetworkProbeApp: App {
    var body: some Scene {
        WindowGroup {
            WasmView(provider: AppBundleProvider(resource: "network_probe"))
        }
    }
}
