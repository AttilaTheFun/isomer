// The selection probe (shared/selection_probe_application) as a wasm
// reactor under WasmView: the Apple tree view's text field reporting its
// selection to the guest and showing the guest's (iOS 18: SwiftUI's
// `TextField(_:text:selection:)`). Drive it on a simulator with
// examples/tests/safari_probe (tap the field, type, tap Complete).

import IsomerWasmView
import SwiftUI

@main
struct SelectionProbeiOSApp: App {
    @StateObject private var model = WasmViewModel()

    var body: some Scene {
        WindowGroup {
            WasmView(model: model, provider: AppBundleProvider(resource: "selection_probe"))
        }
    }
}
