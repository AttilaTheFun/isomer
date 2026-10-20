// The tap counter (examples/shared/tap_counter_application) compiled into
// this app against Isomer's frameworks (apple/compiled), not Apple's: the
// feature's `import SwiftUI` is Isomer's, and this host draws the tree it
// builds with Apple's SwiftUI through WasmView, over the native engine. The
// same source as tap_counter_native_ios_application, which is Apple's
// SwiftUI throughout.

import IsomerNativeRuntime
import IsomerWasmView
import SwiftUI

@main
struct TapCounterCompiledIsomerApp: App {
    init() {
        NativeFeatureRuntime.register()
    }

    var body: some Scene {
        WindowGroup {
            WasmView(provider: CompiledFeatureProvider())
                .ignoresSafeArea()
        }
    }
}
