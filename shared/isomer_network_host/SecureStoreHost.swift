// The hosts' side of the Isomer module's `SecureStore` (secrets kept by the
// system), beside Foundation's networking: what a host implements as a
// swift_ffi interface where the app's Swift can't reach the system's store
// itself. Android's runtime implements it over the Android Keystore and
// hands it to `installIsomerSecureStore` (Kotlin, before the runtime starts);
// a web page injects the browser's under `SecureStoreHostKey.isomerSecureStore`
// and the runtime installs it when it starts (`installInjectedSecureStore`).
// On Apple platforms SecureStore is the Keychain's, no host between.

import IsomerFFI

/// The key of Isomer's secure store among the injected dependencies.
@ExportedEnum
public enum SecureStoreHostKey: String {
    case isomerSecureStore
}

/// What a host read: the value when `found`; `error` names why the read
/// failed ("" when it didn't; an absent item is no failure).
@ExportedStruct
public struct SecureStoreHostValue {
    public let found: Bool
    public let value: [UInt8]
    public let error: String

    public init(found: Bool, value: [UInt8], error: String) {
        self.found = found
        self.value = value
        self.error = error
    }
}

/// The system's store of secrets: items by service and key. Each answers at
/// once (the store is local); a failure is its reason, "" for none.
@ExportedInterface(namespace: "isomer")
public protocol SecureStoreHost {
    func read(service: String, key: String) -> SecureStoreHostValue
    func write(service: String, key: String, value: [UInt8]) -> String
    /// Removes the item; an absent one is no failure.
    func remove(service: String, key: String) -> String
}

/// Where SecureStore reads and writes off Apple: the host's store, else
/// (headless, a test, a host with none) one in memory for the process.
public enum IsomerSecureStore {
    public nonisolated(unsafe) static var host: (any SecureStoreHost)?
}

/// Installs the host's store (what a Kotlin host calls before the runtime
/// starts).
@ExportedFunction(namespace: "isomer")
public func installIsomerSecureStore(host: any SecureStoreHost) {
    IsomerSecureStore.host = host
}

/// Installs what the host injected under `SecureStoreHostKey`'s key, keeping
/// a store already installed where it injected none.
public func installInjectedSecureStore() {
    let key = SecureStoreHostKey.isomerSecureStore
    if let host = (dependencies[key] as? Lazy<any SecureStoreHost>)?.value ?? dependencies[key] as? any SecureStoreHost {
        IsomerSecureStore.host = host
    }
}
