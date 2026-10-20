// The platform services injected into feature code, defined with swift_ffi:
// the app (and the Playground's agent-written apps) call these protocols;
// networking, files and preferences are Foundation's own on every platform
// (URLSession, FileManager in the app's directories, UserDefaults), so they
// are not among them;
// every host implements them natively and installs them through the
// dependency dictionary (docs/wasm_di.md in swift_ffi). Nothing else crosses
// the boundary — no request ids, no completion exports: `async throws`
// methods suspend in the guest and the host answers when it is done.

import IsomerFFI

/// The keys of the host-injected dependency dictionary.
@ExportedEnum
public enum PlatformDependencyKey: String {
    case keychain
    case analytics
    case configuration
    case imagePicker
    case deviceMotion
    case timer
    case oauth
}

/// Secrets in the platform keychain, namespaced by the app / project sandbox.
/// `get` throws when the key is absent.
@ExportedInterface(namespace: "platform_services")
public protocol KeychainService {
    func get(key: String) async throws -> [UInt8]
    func set(value: [UInt8], for key: String) async throws
    /// Removes the value; absent keys are not an error.
    func delete(key: String) async throws
}

/// An analytics event, delivered to the host's pipeline.
@ExportedInterface(namespace: "platform_services")
public protocol AnalyticsService {
    func track(event: String)
}

/// Natively-evaluated feature flags.
@ExportedInterface(namespace: "platform_services")
public protocol ConfigurationService {
    func flag(key: String) -> Bool
}

/// The platform's image chooser — `<input type="file" accept="image/*">` on
/// the web, the photo picker on iOS/Android, an open panel on desktop.
/// `pickImage` presents it and returns a URL of the chosen image the host's
/// image loader displays (a `file://` copy natively, a blob URL on the web;
/// show it with `AsyncImage(url: URL(string: url))`), scaled so its long
/// side is at most `maxDimension` pixels; "" when the user cancels.
@ExportedInterface(namespace: "platform_services")
public protocol ImagePickerService {
    func pickImage(maxDimension: Int) async throws -> String
}

/// Device motion: `nextShake` suspends until the next shake gesture
/// (UIKit's motion events on iOS, the accelerometer's `devicemotion`
/// stream on the web, a keyboard stand-in on desktops) — the hook behind
/// `.onShake { }`. Throws when the host cannot detect motion, so a
/// listener loop ends instead of waiting forever.
@ExportedInterface(namespace: "platform_services")
public protocol DeviceMotionService {
    func nextShake() async throws
}

/// A one-shot delay kept by the host (device-flow polling, retries): the
/// wasm executor has no timer of its own, so `Task.sleep` is not portable.
@ExportedInterface(namespace: "platform_services")
public protocol TimerService {
    func delay(milliseconds: Int32) async
}

/// An OAuth authorization through the system browser with the redirect
/// caught by the host. `redirectURI` is the URI the host will catch (a
/// loopback listener on a desktop, the page's own `/oauth/callback` on the
/// web) — put it in the authorization URL; `authorize` opens the URL and
/// returns the redirect's query string ("code=…&state=…") once it lands.
/// Throws when the user cancels or the host cannot capture redirects.
@ExportedInterface(namespace: "platform_services")
public protocol OAuthService {
    func redirectURI() async throws -> String
    func authorize(url: String) async throws -> String
}

/// Where feature code reads the injected services — resolved lazily, once,
/// from the standard dependency dictionary. Absent services are nil (a host
/// that injects nothing, e.g. a bare web page).
public enum PlatformDependencies {
    public nonisolated(unsafe) static var keychain: (any KeychainService)? = {
        (dependencies[PlatformDependencyKey.keychain] as? Lazy<any KeychainService>)?.value
            ?? dependencies[PlatformDependencyKey.keychain] as? any KeychainService
    }()
    public nonisolated(unsafe) static var analytics: (any AnalyticsService)? = {
        (dependencies[PlatformDependencyKey.analytics] as? Lazy<any AnalyticsService>)?.value
            ?? dependencies[PlatformDependencyKey.analytics] as? any AnalyticsService
    }()
    public nonisolated(unsafe) static var configuration: (any ConfigurationService)? = {
        (dependencies[PlatformDependencyKey.configuration] as? Lazy<any ConfigurationService>)?.value
            ?? dependencies[PlatformDependencyKey.configuration] as? any ConfigurationService
    }()
    public nonisolated(unsafe) static var imagePicker: (any ImagePickerService)? = {
        (dependencies[PlatformDependencyKey.imagePicker] as? Lazy<any ImagePickerService>)?.value
            ?? dependencies[PlatformDependencyKey.imagePicker] as? any ImagePickerService
    }()
    public nonisolated(unsafe) static var deviceMotion: (any DeviceMotionService)? = {
        (dependencies[PlatformDependencyKey.deviceMotion] as? Lazy<any DeviceMotionService>)?.value
            ?? dependencies[PlatformDependencyKey.deviceMotion] as? any DeviceMotionService
    }()
    public nonisolated(unsafe) static var timer: (any TimerService)? = {
        (dependencies[PlatformDependencyKey.timer] as? Lazy<any TimerService>)?.value
            ?? dependencies[PlatformDependencyKey.timer] as? any TimerService
    }()
    public nonisolated(unsafe) static var oauth: (any OAuthService)? = {
        (dependencies[PlatformDependencyKey.oauth] as? Lazy<any OAuthService>)?.value
            ?? dependencies[PlatformDependencyKey.oauth] as? any OAuthService
    }()
}

/// The error feature code sees when a service is not injected.
public struct PlatformServiceUnavailable: Error, CustomStringConvertible {
    public let service: String
    public init(_ service: String) { self.service = service }
    public var description: String { "\(service) is not available on this host" }
}

/// In-process installation for compiled hosts (Apple/Linux/Windows apps
/// install their Swift implementations here at launch; the Android app's
/// Kotlin calls the generated export before the runtime starts). Wasm hosts
/// inject through the dependency dictionary instead.
@ExportedFunction(namespace: "platform_services")
public func installPlatformDependencies(
    keychain: any KeychainService, analytics: any AnalyticsService, configuration: any ConfigurationService
) {
    installDependencies([
        PlatformDependencyKey.keychain: Lazy<any KeychainService> { keychain },
        PlatformDependencyKey.analytics: Lazy<any AnalyticsService> { analytics },
        PlatformDependencyKey.configuration: Lazy<any ConfigurationService> { configuration },
    ])
}

/// The image picker, installed separately (optional: a host without a UI
/// leaves it out and `PlatformDependencies.imagePicker` is nil).
@ExportedFunction(namespace: "platform_services")
public func installPlatformImagePicker(imagePicker: any ImagePickerService) {
    installDependencies([
        PlatformDependencyKey.imagePicker: Lazy<any ImagePickerService> { imagePicker },
    ])
}

/// Device motion, installed separately (optional, like the image picker).
@ExportedFunction(namespace: "platform_services")
public func installPlatformDeviceMotion(deviceMotion: any DeviceMotionService) {
    installDependencies([
        PlatformDependencyKey.deviceMotion: Lazy<any DeviceMotionService> { deviceMotion },
    ])
}

@ExportedFunction(namespace: "platform_services")
public func installPlatformTimer(timer: any TimerService) {
    installDependencies([
        PlatformDependencyKey.timer: Lazy<any TimerService> { timer },
    ])
}

@ExportedFunction(namespace: "platform_services")
public func installPlatformOAuth(oauth: any OAuthService) {
    installDependencies([
        PlatformDependencyKey.oauth: Lazy<any OAuthService> { oauth },
    ])
}
