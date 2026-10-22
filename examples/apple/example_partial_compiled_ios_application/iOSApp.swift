// The `IsomerView` demo host: a plain native SwiftUI app — its own @main,
// its own chrome — embedding ONE shared Isomer feature
// (//examples/shared/embedded_example's OrderStatusCard) through `IsomerView`.
//
// The view always gets the COMPILED root (built natively against
// IsomerCore — see the feature_lib alias in BUILD.bazel) plus a bundle
// provider; whichever wasm bundle the provider yields overrides the compiled
// feature, and with no bundle the compiled root renders at native
// performance:
//   • default                → no bundle: compiled engine (what ships).
//   • ISO_ENGINE=wasm        → simulates "a delivered bundle is cached":
//     the packaged embedded_example.wasm renders on the interpreter from
//     launch (a real provider would return its newest downloaded bundle).
//   • ISO_WASM_PATH=<artifact> (no ISO_ENGINE) → starts compiled, then hot
//     reload takes over live when the watched build products change.
//
//   bazel run //examples/apple/example_partial_compiled_ios_application

import SwiftUI
import IsomerJSCRuntime
import IsomerView
import EmbeddedExample

@main
struct PartialCompiledIOSApp: App {
    var body: some Scene {
        WindowGroup {
            HostScreen()
        }
    }
}

/// Stand-in for a production dynamic-delivery provider. A real implementation
/// returns the newest cached download from `initialBundle()` and feeds
/// `bundleUpdates()` when a background fetch lands a newer one; here
/// ISO_ENGINE=wasm plays the "a bundle is cached" role by serving the
/// app-packaged reactor. `bundleUpdates()` delegates to `AppBundleProvider`,
/// which contributes the dev hot-reload stream when ISO_HOT_RELOAD_SERVER /
/// ISO_WASM_PATH is set.
struct DemoDeliveryProvider: BundleProvider {
    private let packaged = AppBundleProvider(resource: "embedded_example")

    func initialBundle() -> WasmServiceBundle? {
        guard ProcessInfo.processInfo.environment["ISO_ENGINE"]?.lowercased() == "wasm" else {
            return nil
        }
        return packaged.initialBundle()
    }

    func bundleUpdates() -> AsyncStream<WasmServiceBundle> {
        packaged.bundleUpdates()
    }
}

/// Native host chrome that owns the screen; the shared feature is one section.
struct HostScreen: View {
    @State private var status = "Starting…"

    init() {
        // Engine override demo: ISO_JSC=1 runs the wasm feature on
        // JavaScriptCore's WebAssembly instead of WasmKit (pair with
        // ISO_ENGINE=wasm so a bundle is served). On iOS devices JSC has no
        // JIT pages, so wasm runs on its interpreter tier; the simulator
        // JITs like macOS.
        if ProcessInfo.processInfo.environment["ISO_JSC"] == "1" {
            WasmRuntimeRegistry.register { JSCRuntime() }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(status)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, 20).padding(.top, 8)

                    // The shared feature: compiled root + wasm-override provider.
                    IsomerView(
                        root: { OrderStatusCard() },
                        bundleProvider: DemoDeliveryProvider(),
                        onStatus: { status = $0 }
                    )
                    .frame(height: 380)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.08)))
                    .padding(.horizontal, 12)
                }
            }
            .navigationTitle("Acme")
        }
    }
}
