// The example application: the Storybook (//storybook), compiled for
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

#if canImport(ShakeKit)
import ShakeKit
#endif
#if canImport(UpdateKit)
import UpdateKit
#endif
import Storybook
import SwiftUI

@main
struct ExampleApplication: App {
    init() {
        // The example's host-side dependency injection for compiled cells
        // (PlatformServicesInstall.swift); a no-op wherever the host injected first.
        installPlatformDependenciesIfNeeded()
        #if canImport(UpdateKit)
        // The build it is, written for Applications at each launch; and its
        // updates, told of while it is in front. The iPhone's and the Mac's
        // Storybook alone link UpdateKit: elsewhere Applications
        // learns the version otherwise (Android's package manager), or not.
        AppUpdates.start()
        #endif
    }

    var body: some Scene {
        // The title reaches the host as the document/window/task title.
        WindowGroup("Storybook") {
            StorybookView()
                #if canImport(ShakeKit)
                // A shake files an issue here, with a screenshot and the
                // logs, for someone signed in (ShakeKitScope is in every
                // build's Info.plist); only the iPhone's and the Mac's
                // Storybook link ShakeKit.
                .shakeToReport(repository: "AttilaTheFun/isomer")
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        #endif
        #if canImport(ShakeKit)
        // Help › Report a Bug… (⌥⌘B), the shake's twin on the Mac.
        .commands { ShakeKitCommands() }
        #endif
    }
}
