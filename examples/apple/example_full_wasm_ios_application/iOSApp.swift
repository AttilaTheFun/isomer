// The "full x wasm" iOS cell: the WHOLE shared example app as a wasm bundle,
// rendered full-screen with real SwiftUI via `WasmView`. Where
// example_partial_wasm embeds one FEATURE bundle in native chrome, this hosts
// the entire multi-tab `@main App`. The runtime-updatable twin of
// example_full_compiled_ios_application.
//
// Host-side dependency injection: the app's platform services (the keychain,
// analytics, flags, the image picker, a timer, OAuth) from
// `applePlatformDependencies`; its URLSession goes through the URLSession
// WasmView injects beneath them, as the web page's goes through fetch() and
// Android's through HttpURLConnection.

import ApplePlatformServices
import Foundation
import SwiftUI
import IsomerWasmView


@main
struct FullWasmiOSApp: App {
    @StateObject private var model: WasmViewModel

    init() {
        let model = WasmViewModel()
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            WasmView(
                model: model,
                provider: AppBundleProvider(resource: "example_full"),
                ffiModulePrefix: platformServicesFFIPrefix,
                dependencies: applePlatformDependencies(namespace: "example_full_wasm_ios"))
                .ignoresSafeArea()
        }
    }
}
