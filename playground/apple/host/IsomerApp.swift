// The Isomer app on Apple platforms: the shared shell (shared/app) against
// Apple's SwiftUI, with the host (AppleHost) and the platform's views (the
// run's WasmView, the iPhone's highlighted code editor) installed before it
// starts.

import ApplePlatformServices
import PlatformServices
import SwiftUI

@main
struct IsomerApp: App {
    init() {
        PlaygroundHost.service = AppleHost()
        PlaygroundSurfaces.run = { onStopped in AnyView(AppleRunSurface(onStopped: onStopped)) }
        #if os(iOS)
        PlaygroundSurfaces.codeEditor = { text, fileName in AnyView(CodeEditor(text: text, fileName: fileName)) }
        #endif
        // The Gallery's screens and the shell's shake read the compiled-in
        // service table, as the example apps do.
        installPlatformDependencies(
            keychain: NativeKeychainService(namespace: "isomer"),
            analytics: NativeAnalyticsService(),
            configuration: NativeConfigurationService(flags: ["promo_banner": true]))
        installPlatformImagePicker(imagePicker: NativeImagePickerService())
        installPlatformDeviceMotion(deviceMotion: NativeDeviceMotionService.shared)
    }

    var body: some Scene {
        WindowGroup("Isomer") { IsomerRoot() }
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
