// The platform services a native Swift host injects into a reactor it runs
// (Linux's and Windows' wasm hosts): the Foundation implementations
// (native/) conformed to the generated host protocols (PlatformServicesHost),
// and the dependency table a host hands to `WasmFeatureRuntime`. Async
// methods (the keychain's, the timer's) complete back into the running
// feature through the runtime's `resumeAsync`.

import Foundation
import PlatformServicesHost
import SwiftFFIWasmHost

extension NativeKeychainService: KeychainService {}
extension NativeAnalyticsService: AnalyticsService {}
extension NativeConfigurationService: ConfigurationService {}
extension NativeTimerService: TimerService {}

/// The swift_ffi export prefix of the `platform_services` namespace.
public let nativePlatformServicesPrefix = "swift_ffi_platform_services_"

/// The dependency table for one feature (its keychain under `namespace`).
/// Networking, files and preferences are Foundation's own.
public func nativePlatformDependencies(
    namespace: String,
    flags: [String: Bool] = ["promo_banner": true],
    analytics: @escaping (String) -> Void = { print("[analytics] \($0)") }
) -> [String: SwiftFFIDependency] {
    [
        "keychain": Dependencies.keychainService { NativeKeychainService(namespace: namespace) },
        "analytics": Dependencies.analyticsService { NativeAnalyticsService(sink: analytics) },
        "configuration": Dependencies.configurationService { NativeConfigurationService(flags: flags) },
        "timer": Dependencies.timerService { NativeTimerService() },
    ]
}
