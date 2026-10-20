import PlatformServices
import IsomerFFI
import XCTest

/// Host-side services standing in for the platform's (the keychain,
/// analytics, flags, a timer, OAuth): the compiled in-process round trip
/// through the dependency dictionary — `async throws` methods included,
/// exactly as the wasm hosts marshal them. (Networking and files are
/// Foundation's own, not injected.)
private final class MemoryKeychain: KeychainService {
    var store: [String: [UInt8]] = [:]
    func get(key: String) async throws -> [UInt8] {
        guard let value = store[key] else { throw PlatformServiceUnavailable("no keychain value for \(key)") }
        return value
    }
    func set(value: [UInt8], for key: String) async throws { store[key] = value }
    func delete(key: String) async throws { store[key] = nil }
}

private final class RecordingAnalytics: AnalyticsService {
    var events: [String] = []
    func track(event: String) { events.append(event) }
}

private final class Flags: ConfigurationService {
    func flag(key: String) -> Bool { key == "promo_banner" }
}

final class PlatformServicesDITests: XCTestCase {
    private let keychain = MemoryKeychain()
    private let analytics = RecordingAnalytics()

    override func setUp() {
        super.setUp()
        installPlatformDependencies(keychain: keychain, analytics: analytics, configuration: Flags())
        // Re-resolve (the static defaults may have resolved before install).
        PlatformDependencies.keychain = (dependencies[PlatformDependencyKey.keychain] as? Lazy<any KeychainService>)?.value
        PlatformDependencies.analytics = (dependencies[PlatformDependencyKey.analytics] as? Lazy<any AnalyticsService>)?.value
        PlatformDependencies.configuration = (dependencies[PlatformDependencyKey.configuration] as? Lazy<any ConfigurationService>)?.value
    }

    override func tearDown() {
        swiftFFIDependencyResolver = nil
        super.tearDown()
    }

    func testKeychainAnalyticsConfiguration() async throws {
        let keychain = PlatformDependencies.keychain!
        try await keychain.set(value: [1, 2, 3], for: "token")
        let value = try await keychain.get(key: "token")
        try await keychain.delete(key: "token")
        do { _ = try await keychain.get(key: "token"); XCTFail("deleted key still readable") } catch {}
        try await keychain.delete(key: "token")  // absent: not an error
        // Timer and OAuth services resolve through the same dictionary.
        final class StubTimer: TimerService { var waited: Int32 = 0; func delay(milliseconds: Int32) async { waited += milliseconds } }
        final class StubOAuth: OAuthService {
            func redirectURI() async throws -> String { "http://127.0.0.1:1/callback" }
            func authorize(url: String) async throws -> String { "code=abc&state=xyz" }
        }
        let timer = StubTimer()
        installPlatformTimer(timer: timer)
        installPlatformOAuth(oauth: StubOAuth())
        let resolvedTimer = (dependencies[PlatformDependencyKey.timer] as? Lazy<any TimerService>)?.value
        await resolvedTimer?.delay(milliseconds: 250)
        XCTAssertEqual(timer.waited, 250)
        let oauth = (dependencies[PlatformDependencyKey.oauth] as? Lazy<any OAuthService>)?.value
        let query = try await oauth?.authorize(url: "https://example.com/auth")
        XCTAssertEqual(query, "code=abc&state=xyz")
        XCTAssertEqual(value, [1, 2, 3])

        PlatformDependencies.analytics?.track(event: "tap")
        XCTAssertEqual(analytics.events, ["tap"])
        XCTAssertTrue(PlatformDependencies.configuration!.flag(key: "promo_banner"))
        XCTAssertFalse(PlatformDependencies.configuration!.flag(key: "other"))
    }
}
