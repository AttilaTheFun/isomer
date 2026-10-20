// The JavaScriptCore iOS cell of the counter benchmark (docs/benchmarks.md#ios):
// the SAME shared TapCounter.swift as the standard `.wasm` reactor, run by
// JSC's own WebAssembly implementation inside a JSContext (`JSCRuntime`) —
// interpreter-only on device (no 3rd-party JIT pages), rendered as real
// SwiftUI via `WasmView`. Fully committable: JavaScriptCore is a system
// framework, no vendored SDK.

import SwiftUI
import UIKit
import IsomerJSCRuntime
import IsomerWasmRuntime
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
struct TapCounterJSCIOSApp: App {
    @UIApplicationDelegateAdaptor(BenchAppDelegate.self) private var delegate

    init() {
        // Wins over WasmView's registerDefault(WamrRuntime) — every launch in
        // this cell runs the reactor under JavaScriptCore.
        WasmRuntimeRegistry.register { JSCRuntime() }
    }

    var body: some Scene {
        WindowGroup {
            WasmView(provider: AppBundleProvider(resource: "tap_counter_release"))
                .ignoresSafeArea()
        }
    }
}

/// Bench wiring (found via the boot constructor's weak reference): tap =
/// inject the button node's event into the reactor — the same path a
/// touch-up takes.
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
