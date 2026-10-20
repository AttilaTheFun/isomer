// Host-side dependency wiring for the COMPILED cells (the app runs in-process
// with its host): installs the native platform services into the swift_ffi
// dependency dictionary at launch. Everywhere else the host injects before
// app code runs (wasm hosts through the generated resolver at activation,
// the Android app's Kotlin through `installPlatformDependencies`), and the
// nil-resolver guard keeps this a no-op there.

import PlatformServices
import IsomerFFI

#if !os(WASI) && !os(Android)

extension NativeKeychainService: KeychainService {}
extension NativeAnalyticsService: AnalyticsService {}
extension NativeConfigurationService: ConfigurationService {}
extension NativeImagePickerService: ImagePickerService {}
extension NativeDeviceMotionService: DeviceMotionService {}

/// Installs the compiled host's services unless a host already injected its
/// own (the wasm resolver, Kotlin's install, or a test).
func installPlatformDependenciesIfNeeded() {
    guard swiftFFIDependencyResolver == nil else { return }
    installPlatformDependencies(
        keychain: NativeKeychainService(namespace: "example_application"),
        analytics: NativeAnalyticsService(),
        configuration: NativeConfigurationService(flags: ["promo_banner": true]))
    installPlatformImagePicker(imagePicker: NativeImagePickerService())
    installPlatformDeviceMotion(deviceMotion: NativeDeviceMotionService.shared)
}

#else

/// Wasm / Android: the host injects; nothing to do.
func installPlatformDependenciesIfNeeded() {}

#endif
