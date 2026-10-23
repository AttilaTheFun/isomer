// The example application: the Gallery (@isomer//gallery) as an app of its
// own, compiled for every platform:
//   * examples/apple/example_full_compiled_{ios,macos}_application (Apple's SwiftUI)
//   * examples/web/example_full_{react,webgpu}_web_application, electron (wasm)
//   * examples/android/example_full_{compiled,wasm}_android_application
//   * examples/linux, examples/windows (compiled and wasm)

import Gallery
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
        WindowGroup("Isomer") {
            GalleryView()
        }
    }
}
