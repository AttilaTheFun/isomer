// The native implementations conformed to the platform-service interfaces,
// and one call that installs them all for an in-process Apple host.

import Foundation
import PlatformServices
import IsomerFFI

extension NativeKeychainService: KeychainService {}
extension NativeAnalyticsService: AnalyticsService {}
extension NativeConfigurationService: ConfigurationService {}
extension NativeImagePickerService: ImagePickerService {}
extension NativeDeviceMotionService: DeviceMotionService {}
extension NativeTimerService: TimerService {}
extension NativeOAuthService: OAuthService {}

/// Installs the Foundation implementations (the keychain sandboxed under
/// `namespace`) unless a host already injected its own. Returns whether it
/// installed. (Networking, files and preferences are Foundation's own.)
@discardableResult
public func installNativePlatformServices(
    namespace: String,
    flags: [String: Bool] = [:],
    analytics: @escaping (String) -> Void = { print("[analytics] \($0)") }
) -> Bool {
    guard swiftFFIDependencyResolver == nil else { return false }
    installPlatformDependencies(
        keychain: NativeKeychainService(namespace: namespace),
        analytics: NativeAnalyticsService(sink: analytics),
        configuration: NativeConfigurationService(flags: flags))
    installPlatformImagePicker(imagePicker: NativeImagePickerService())
    installPlatformDeviceMotion(deviceMotion: NativeDeviceMotionService.shared)
    installPlatformTimer(timer: NativeTimerService())
    installPlatformOAuth(oauth: NativeOAuthService())
    return true
}
