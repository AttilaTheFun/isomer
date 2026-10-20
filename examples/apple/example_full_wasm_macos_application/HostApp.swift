// The "full x wasm" cell of the Apple matrix: the WHOLE shared example app,
// delivered as a wasm bundle and rendered full-screen with real SwiftUI. Where
// example_partial_wasm embeds one small FEATURE bundle inside host chrome, this
// hosts the entire multi-tab `@main App` (//examples/wasm/example_full_feature)
// with no native chrome at all — the wasm bundle owns the whole window. It is
// the runtime-updatable twin of example_full_compiled (which ships the same app
// as compiled Swift). See docs/wasm_view_architecture.md.
//
// Host-side dependency injection (the app's own surface — docs/wasm_di.md):
// this host gives the app its platform services (`applePlatformDependencies`);
// the app's URLSession goes through the URLSession WasmView injects beneath
// them, exactly as the web page's goes through fetch() and Android's through
// HttpURLConnection.

import ApplePlatformServices
import Foundation
import SwiftUI
import IsomerWasmView


@main
struct FullWasmHostApp: App {
    @StateObject private var model: WasmViewModel

    init() {
        registerBridgedViews()
        let model = WasmViewModel()
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup("Isomer — Full (wasm)") {
            // Full-screen: the wasm app is the entire UI, no host banner.
            WasmView(
                model: model,
                provider: AppBundleProvider(resource: "example_full"),
                ffiModulePrefix: platformServicesFFIPrefix,
                dependencies: applePlatformDependencies(namespace: "example_full_wasm_macos"))
                .ignoresSafeArea()
        }
        .defaultSize(width: 960, height: 760)
    }
}

/// Native SwiftUI views the wasm app may bridge in by id (registered up front,
/// ship with the host). Mirrors the partial host so both wasm cells expose the
/// same native surface.
@MainActor func registerBridgedViews() {
    BridgedViewRegistry.shared.register("native_badge") { params, _, _ in
        AnyView(
            Label(params["title"] ?? "Native", systemImage: params["icon"] ?? "star.fill")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.14))
                .foregroundStyle(Color.blue)
                .clipShape(Capsule())
        )
    }
}
