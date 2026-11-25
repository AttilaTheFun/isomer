// The example application: the Storybook (//storybook), compiled for
// every platform. The Storybook apps (com.LoganShire.Storybook,
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

#if canImport(ShireworksKit)
import ShireworksKit
#endif
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
                #if canImport(ShireworksKit)
                // Shireworks' kit: the build it is, written for Applications
                // at each launch, its update sheet, crash reports, and a
                // shake to file an issue for someone signed in to the shared
                // GitHub sign-in, where the build carries its keys (CI's:
                // ShireworksRepository and the rest, //tools/signing). Only
                // the iPhone's and the Mac's Storybook link it: elsewhere
                // Applications learns the version otherwise (Android's
                // package manager), or not.
                .shireworks()
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        #endif
        #if canImport(ShireworksKit)
        // Help › Report a Bug… (⌥⌘B), the shake's twin on the Mac.
        .commands { ShakeKitCommands() }
        #endif
    }
}
