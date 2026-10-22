// The WASM iOS cell of the counter benchmark (docs/benchmarks.md#ios): the
// SAME shared TapCounter.swift shipped as a wasm reactor (interpreted by
// WasmKit, WasmView's engine) and rendered as REAL SwiftUI via `WasmView` →
// `IsomerTreeView`. Runtime-updatable, no compiled app Swift.

import SwiftUI
import UIKit
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
