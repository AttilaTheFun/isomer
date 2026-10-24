// The host of the Storybook compiled against Isomer's frameworks
// (FeatureApp.swift): WasmView drives the feature over the native engine and
// draws the tree it builds with Apple's SwiftUI. A launch's
// ISO_STORYBOOK_STORY reaches the feature through the process environment.

import IsomerNativeRuntime
import IsomerWasmView
import SwiftUI

@main
struct StorybookIsomerApp: App {
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
