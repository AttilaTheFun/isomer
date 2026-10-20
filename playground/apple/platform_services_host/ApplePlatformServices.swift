// The Apple WasmView hosts' side of shared/platform_services: the
// Foundation implementations conformed to the generated host protocols
// (PlatformServicesHost), and the dependency table a host passes to
// `WasmView(dependencies:)`. Async methods (the keychain's, the timer's)
// complete back into the running feature through the runtime's
// `resumeAsync` — no request ids or completion exports in app code.

import Foundation
import PlatformServicesHost
import SwiftFFIWasmHost

extension NativeKeychainService: KeychainService {}
extension NativeAnalyticsService: AnalyticsService {}
extension NativeConfigurationService: ConfigurationService {}
extension NativeImagePickerService: ImagePickerService {}
extension NativeDeviceMotionService: DeviceMotionService {}
extension NativeTimerService: TimerService {}
extension NativeOAuthService: OAuthService {}

/// The swift_ffi export prefix of the `platform_services` namespace.
public let platformServicesFFIPrefix = "swift_ffi_platform_services_"

/// The full dependency table for one feature (the keychain sandboxed under
/// `namespace`). Networking, files and preferences are Foundation's own:
/// WasmView injects URLSession beneath this table, and the feature's files
/// are its FileManager's.
public func applePlatformDependencies(
    namespace: String,
    flags: [String: Bool] = ["promo_banner": true],
    analytics: @escaping (String) -> Void = { NSLog("[analytics] %@", $0) }
) -> [String: SwiftFFIDependency] {
    return [
        "keychain": Dependencies.keychainService { NativeKeychainService(namespace: namespace) },
        "analytics": Dependencies.analyticsService { NativeAnalyticsService(sink: analytics) },
        "configuration": Dependencies.configurationService { NativeConfigurationService(flags: flags) },
        "imagePicker": Dependencies.imagePickerService { NativeImagePickerService() },
        "deviceMotion": Dependencies.deviceMotionService { NativeDeviceMotionService.shared },
        "timer": Dependencies.timerService { NativeTimerService() },
        "oauth": Dependencies.oAuthService { NativeOAuthService() },
    ]
}
