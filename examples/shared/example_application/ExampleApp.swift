// The example application: the Storybook (@isomer//storybook), compiled for
// every platform. The Storybook apps (com.LoganShire.IsomerStorybook,
// "Storybook") are its one cell per platform, each with that platform's
// renderer:
//   * examples/apple/storybook_{ios,macos}_application (Apple's SwiftUI)
//   * examples/web/storybook_web_application (React)
//   * examples/android/storybook_android_application (Compose)
//   * examples/linux/storybook_linux_application (OpenGL)
//   * examples/windows/storybook_windows_application (DirectX)
// The rest compile the same source as test cells: delivered as wasm
// (example_full_wasm_*, example_full_feature), the web's GPU renderer
// (example_full_webgpu_*), Electron.

import Storybook
import SwiftUI

@main
struct ExampleApplication: App {
    init() {
        // The example's host-side dependency injection for compiled cells
        // (PlatformServicesInstall.swift); a no-op wherever the host injected first.
        installPlatformDependenciesIfNeeded()
    }

    var body: some Scene {
        // The title reaches the host as the document/window/task title.
        WindowGroup("Storybook") {
            StorybookView()
        }
    }
}
