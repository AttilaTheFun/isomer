// `SecureStore`: secrets an app keeps (a sign-in's tokens) in the system's
// store, by service and key, the same API on every platform. Isomer's own
// (the Isomer module): Apple's is the Keychain's Security API, which isn't
// SwiftUI's or Foundation's. Underneath:
//
// - Apple platforms (an app on Apple's SwiftUI, or compiled against
//   Isomer's): the Keychain, generic-password items (kSecAttrService the
//   service, kSecAttrAccount the key), readable after the device's first
//   unlock, this device only (never in iCloud), in `accessGroup` when one is
//   given (an app group's keychain-access-groups entitlement shares it);
// - Android: the runtime's host, values sealed by a key in the Android
//   Keystore (IsomerSecureStore.kt), per app;
// - the web: the page's host, the origin's storage (a browser keeps nothing
//   more secure that a page can read back at once);
// - anywhere else (headless, tests, Linux and Windows for now): memory, for
//   the process.
//
// `accessGroup` (and `sharedGroup`, the same without its team prefix) is
// Apple's alone; elsewhere each app's store is its own.

import Foundation
#if canImport(Security)
import Security
#elseif canImport(IsomerNetworkHost)
import IsomerNetworkHost
#endif

/// Secrets kept by the system's store, by service and key.
public struct SecureStore: Sendable {
    /// What the items are filed under (an app's, or a sign-in's).
    public let service: String
    /// Apple's keychain access group the items are in, shared by the apps
    /// whose entitlements name it; nil, the app's own. Ignored elsewhere.
    public let accessGroup: String?
    /// The group without its team ID prefix ("com.example.shared"), which
    /// the store prefixes with the app's own team, found at run time (so a
    /// repository needn't carry the team ID). Ignored elsewhere.
    let sharedGroup: String?

    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
        self.sharedGroup = nil
    }

    /// Items in the keychain access group `sharedGroup` names without its
    /// team ID prefix (the entitlement's `$(AppIdentifierPrefix)` part): the
    /// app's own team's, found at run time from the group the keychain gives
    /// an item of the app's own.
    public init(service: String, sharedGroup: String) {
        self.service = service
        self.accessGroup = nil
        self.sharedGroup = sharedGroup
    }

    /// The item's value, nil when there is none.
    public func data(for key: String) throws -> Data? {
        try _SecureStoreBackend.read(self, key)
    }

    /// Stores the value, replacing the item's.
    public func set(_ data: Data, for key: String) throws {
        try _SecureStoreBackend.write(self, key, data)
    }

    /// Removes the item; an absent one is no error.
    public func remove(_ key: String) throws {
        try _SecureStoreBackend.remove(self, key)
    }

    /// The item's value as UTF-8 text, nil when there is none.
    public func string(for key: String) throws -> String? {
        try data(for: key).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Stores the text (UTF-8), replacing the item's.
    public func set(_ string: String, for key: String) throws {
        try set(Data(string.utf8), for: key)
    }
}

/// Why the system's store refused (the Keychain's OSStatus on Apple, the
/// host's reason elsewhere).
public struct SecureStoreError: Error, CustomStringConvertible, Sendable {
    public let description: String

    init(_ description: String) {
        self.description = description
    }
}

#if canImport(Security)
enum _SecureStoreBackend {
    /// The keychain's own parts of every query: generic passwords, never
    /// synchronized, and on the Mac the iOS-style keychain, where access
    /// groups are honoured.
    private static func base(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private static func query(_ store: SecureStore, _ key: String) throws -> [String: Any] {
        var query = base(service: store.service, account: key)
        if let group = store.accessGroup {
            query[kSecAttrAccessGroup as String] = group
        } else if let shared = store.sharedGroup {
            query[kSecAttrAccessGroup as String] = try teamPrefix() + "." + shared
        }
        return query
    }

    nonisolated(unsafe) private static var foundTeamPrefix: String?
    private static let teamLock = NSLock()

    /// The app's team ID: the first part of the access group the keychain
    /// gives an item the app writes without one (its default group, the
    /// entitlements' first, "<team>.<…>"), found once.
    private static func teamPrefix() throws -> String {
        teamLock.lock()
        defer { teamLock.unlock() }
        if let found = foundTeamPrefix { return found }
        var probe = base(service: "dev.isomer.secure-store.team", account: "team")
        probe[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        probe[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        var status = SecItemAdd(probe as CFDictionary, &result)
        if status == errSecDuplicateItem {
            probe[kSecAttrAccessible as String] = nil
            probe[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(probe as CFDictionary, &result)
        }
        guard status == errSecSuccess else { throw failure(status) }
        guard let group = (result as? [String: Any])?[kSecAttrAccessGroup as String] as? String,
              let prefix = group.split(separator: ".").first, !prefix.isEmpty else {
            throw SecureStoreError("the app's keychain access group names no team")
        }
        foundTeamPrefix = String(prefix)
        return String(prefix)
    }

    private static func failure(_ status: OSStatus) -> SecureStoreError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return SecureStoreError(message)
    }

    static func read(_ store: SecureStore, _ key: String) throws -> Data? {
        var query = try query(store, key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        return result as? Data
    }

    static func write(_ store: SecureStore, _ key: String, _ data: Data) throws {
        let query = try query(store, key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }

    static func remove(_ store: SecureStore, _ key: String) throws {
        let status = SecItemDelete(try query(store, key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
}
#else
enum _SecureStoreBackend {
    /// The process's store where the host has none.
    nonisolated(unsafe) private static var memory: [String: Data] = [:]
    private static let lock = NSLock()

    private static func slot(_ store: SecureStore, _ key: String) -> String { store.service + "\u{1F}" + key }

    static func read(_ store: SecureStore, _ key: String) throws -> Data? {
        #if canImport(IsomerNetworkHost)
        if let host = IsomerSecureStore.host {
            let answer = host.read(service: store.service, key: key)
            guard answer.error.isEmpty else { throw SecureStoreError(answer.error) }
            return answer.found ? Data(answer.value) : nil
        }
        #endif
        lock.lock()
        defer { lock.unlock() }
        return memory[slot(store, key)]
    }

    static func write(_ store: SecureStore, _ key: String, _ data: Data) throws {
        #if canImport(IsomerNetworkHost)
        if let host = IsomerSecureStore.host {
            let error = host.write(service: store.service, key: key, value: [UInt8](data))
            guard error.isEmpty else { throw SecureStoreError(error) }
            return
        }
        #endif
        lock.lock()
        defer { lock.unlock() }
        memory[slot(store, key)] = data
    }

    static func remove(_ store: SecureStore, _ key: String) throws {
        #if canImport(IsomerNetworkHost)
        if let host = IsomerSecureStore.host {
            let error = host.remove(service: store.service, key: key)
            guard error.isEmpty else { throw SecureStoreError(error) }
            return
        }
        #endif
        lock.lock()
        defer { lock.unlock() }
        memory[slot(store, key)] = nil
    }
}
#endif
