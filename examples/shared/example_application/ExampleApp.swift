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

#if canImport(ApplicationUpdates)
import ApplicationUpdates
#endif
import Storybook
import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct ExampleApplication: App {
    init() {
        // The example's host-side dependency injection for compiled cells
        // (PlatformServicesInstall.swift); a no-op wherever the host injected first.
        installPlatformDependenciesIfNeeded()
        #if canImport(ApplicationUpdates)
        // The build it is, written for Applications at each launch; and its
        // updates, told of while it is in front. The iPhone's and the Mac's
        // Storybook alone link ApplicationUpdates: elsewhere Applications
        // learns the version otherwise (Android's package manager), or not.
        AppUpdates.start()
        #endif
    }

    var body: some Scene {
        // The title reaches the host as the document/window/task title.
        WindowGroup("Storybook") {
            StorybookView()
                #if os(macOS)
                // ISO_ACTIVATE (the proof's, on a shared screen): in front, as
                // a launch from the Dock would be, when started by its binary.
                .onAppear {
                    if ProcessInfo.processInfo.environment["ISO_ACTIVATE"] != nil { NSApplication.shared.activate() }
                }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        #endif
    }
}
