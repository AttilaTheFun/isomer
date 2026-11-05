// The Playground on Apple platforms: the shared shell (shared/app) against
// Apple's SwiftUI, with the host (AppleHost) and the platform's views (the
// run's WasmView, the iPhone's highlighted code editor) installed before it
// starts.

import ApplePlatformServices
import ApplicationUpdates
import PlatformServices
import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct PlaygroundApp: App {
    init() {
        PlaygroundHost.service = AppleHost()
        PlaygroundSurfaces.run = { onStopped in AnyView(AppleRunSurface(onStopped: onStopped)) }
        #if os(iOS)
        PlaygroundSurfaces.codeEditor = { text, fileName in AnyView(CodeEditor(text: text, fileName: fileName)) }
        #endif
        // The shell's shake reads the compiled-in service table (device
        // motion), as the example apps do.
        installPlatformDependencies(
            keychain: NativeKeychainService(namespace: "isomer"),
            analytics: NativeAnalyticsService(),
            configuration: NativeConfigurationService(flags: ["promo_banner": true]))
        installPlatformImagePicker(imagePicker: NativeImagePickerService())
        installPlatformDeviceMotion(deviceMotion: NativeDeviceMotionService.shared)
        // The build it is, written for Applications at each launch; and its
        // updates, told of while it is in front (ApplicationUpdates).
        AppUpdates.start()
    }

    var body: some Scene {
        WindowGroup("Playground") {
            PlaygroundRoot()
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

extension NativeKeychainService: PlatformServices.KeychainService {}
extension NativeAnalyticsService: PlatformServices.AnalyticsService {}
extension NativeConfigurationService: PlatformServices.ConfigurationService {}
extension NativeImagePickerService: PlatformServices.ImagePickerService {}
extension NativeDeviceMotionService: PlatformServices.DeviceMotionService {}
