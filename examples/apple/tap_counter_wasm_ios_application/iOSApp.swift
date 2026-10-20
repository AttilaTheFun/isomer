// The WASM iOS cell of the counter benchmark (docs/benchmarks.md#ios): the
// SAME shared TapCounter.swift shipped as a wasm reactor (interpreted, or a
// wamrc .aot under --config=release) and rendered as REAL SwiftUI via
// `WasmView` → `IsomerTreeView`. Runtime-updatable, no compiled app Swift.

import CIsoEmbeddedAot
import SwiftUI
import UIKit
import IsomerWamrRuntime
import IsomerWasmView

/// See the native cell: didFinishLaunching stamp for the startup split.
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
struct TapCounterWasmIOSApp: App {
    @UIApplicationDelegateAdaptor(BenchAppDelegate.self) private var delegate

    init() {
        // Hybrid delivery policy: run the embedded (signed-__TEXT, execute-in-
        // place) AOT image by default; ISO_FORCE_INTERP=1 opts into the
        // interpreter on the bundled .wasm — the dynamically-deliverable tier
        // (e.g. a hotfix bundle), trading some speed to avoid a shipped bug.
        if ProcessInfo.processInfo.environment["ISO_FORCE_INTERP"] != "1" {
            var length = 0
            if let data = iso_embedded_aot_data(&length), length > 0 {
                WamrRuntime.embeddedImage = UnsafeRawBufferPointer(start: data, count: length)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            WasmView(provider: AppBundleProvider(resource: "tap_counter_release"))
                .ignoresSafeArea()
        }
    }
}

/// Bench wiring (found via dlsym by BenchHarness): tap = inject the button
/// node's event into the reactor — the same path a touch-up takes (wasm event
/// handling + diff patch + SwiftUI update included).
@_cdecl("iso_bench_wire")
public func iso_bench_wire() {
    Task { @MainActor in
        BenchHarness.tapTrigger = {
            guard let model = WasmViewModel.benchShared,
                  let id = IsomerTreeBenchHook.lastTapID else { return }
            model.send(id: id, value: "")
        }
        IsomerTreeBenchHook.bodyTick = { BenchHarness.noteBodyTick() }
    }
}
