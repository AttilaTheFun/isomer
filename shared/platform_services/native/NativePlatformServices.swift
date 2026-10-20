// Foundation-backed implementations of the platform services for hosts
// written in Swift — the compiled Apple/Linux/Windows apps, the Apple
// WasmView hosts, and the Playground. This file imports neither
// `PlatformServices` (the guest module) nor `PlatformServicesHost` (the
// generated host bindings): each consumer adds one-line conformances to
// whichever protocol family it links, so the implementations live once.

#if !os(WASI) && !os(Android)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Network)
import Network
#endif
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A failed platform request (status/message).
public struct NativeServiceError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Secrets: the Security-framework keychain on Apple (generic passwords under
/// a per-namespace service); files in the app's Application Support
/// elsewhere (a directory of the namespace's, a file per key).
public final class NativeKeychainService {
    public let namespace: String

    public init(namespace: String) {
        self.namespace = namespace
    }

    #if !canImport(Security)
    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("keychain-" + namespace, isDirectory: true)
    }

    private func file(_ key: String) -> URL {
        directory.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_"), isDirectory: false)
    }
    #endif

    /// The keychain service items are kept under, and the one they were kept
    /// under while the framework was named universal_ui: an item found only
    /// under the old name is moved across when it is read, so an app keeps
    /// its secrets through the rename.
    private var service: String { "isomer." + namespace }
    private var formerService: String { "universalui." + namespace }

    #if canImport(Security)
    private func item(service: String, key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    private func remove(service: String, key: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        return SecItemDelete(query as CFDictionary)
    }
    #endif

    public func get(key: String) async throws -> [UInt8] {
        #if canImport(Security)
        if let data = item(service: service, key: key) { return [UInt8](data) }
        if let data = item(service: formerService, key: key) {
            // Moved, not copied: one place holds the secret.
            if (try? await set(value: [UInt8](data), for: key)) != nil {
                remove(service: formerService, key: key)
            }
            return [UInt8](data)
        }
        throw NativeServiceError("no keychain value for \(key)")
        #else
        guard let data = try? Data(contentsOf: file(key)) else { throw NativeServiceError("no keychain value for \(key)") }
        return [UInt8](data)
        #endif
    }

    public func set(value: [UInt8], for key: String) async throws {
        #if canImport(Security)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NativeServiceError("keychain write failed (\(status))") }
        #else
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(value).write(to: file(key))
        } catch {
            throw NativeServiceError("keychain write failed")
        }
        #endif
    }

    public func delete(key: String) async throws {
        #if canImport(Security)
        remove(service: formerService, key: key)
        let status = remove(service: service, key: key)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NativeServiceError("keychain delete failed (\(status))") }
        #else
        try? FileManager.default.removeItem(at: file(key))
        #endif
    }
}

/// Analytics events go to the log (a real pipeline would forward them).
public final class NativeAnalyticsService {
    public var sink: (String) -> Void
    public init(sink: @escaping (String) -> Void = { print("[analytics] \($0)") }) { self.sink = sink }
    public func track(event: String) { sink(event) }
}

/// Feature flags from a static table.
public final class NativeConfigurationService {
    public var flags: [String: Bool]
    public init(flags: [String: Bool] = [:]) { self.flags = flags }
    public func flag(key: String) -> Bool { flags[key] ?? false }
}


/// One-shot delays on the host's clock.
public final class NativeTimerService {
    public init() {}

    public func delay(milliseconds: Int32) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
    }
}

/// OAuth through the system browser with a loopback listener catching the
/// redirect (`http://127.0.0.1:<port>/callback`), the desktop shape every
/// provider accepts for native apps. `redirectURI` starts the listener;
/// `authorize` opens the URL and waits for the redirect's query string.
public final class NativeOAuthService {
    public init() {}

    #if canImport(Network)
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var waiter: CheckedContinuation<String, Error>?
    private let lock = NSLock()

    public func redirectURI() async throws -> String {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            do {
                let listener = try NWListener(using: .tcp, on: .any)
                var resumed = false
                listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if !resumed, let port = listener.port { resumed = true; continuation.resume(returning: port.rawValue) }
                    case .failed(let error):
                        if !resumed { resumed = true; continuation.resume(throwing: error) }
                    default: break
                    }
                }
                self.lock.lock(); self.listener?.cancel(); self.listener = listener; self.lock.unlock()
                listener.start(queue: .main)
            } catch {
                continuation.resume(throwing: error)
            }
        }
        lock.lock(); self.port = port; lock.unlock()
        return "http://127.0.0.1:\(port)/callback"
    }

    public func authorize(url: String) async throws -> String {
        guard let target = URL(string: url) else { throw NativeServiceError("bad url: \(url)") }
        lock.lock()
        guard listener != nil else { lock.unlock(); throw NativeServiceError("call redirectURI() first") }
        lock.unlock()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock(); waiter = continuation; lock.unlock()
            DispatchQueue.main.async {
                #if canImport(AppKit)
                NSWorkspace.shared.open(target)
                #elseif canImport(UIKit)
                UIApplication.shared.open(target)
                #endif
            }
        }
    }

    /// Reads one HTTP request, answers with a small page, and delivers the
    /// query string of a `/callback` request.
    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            var query = ""
            if let line = request.split(separator: "\r\n").first, let path = line.split(separator: " ").dropFirst().first,
               path.hasPrefix("/callback"), let mark = path.firstIndex(of: "?") {
                query = String(path[path.index(after: mark)...])
            }
            let body = "<html><body style=\"font-family:-apple-system,sans-serif;padding:32px\">Signed in. You can close this window.</body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            guard !query.isEmpty else { return }
            self.lock.lock()
            let waiter = self.waiter
            self.waiter = nil
            self.listener?.cancel()
            self.listener = nil
            self.lock.unlock()
            waiter?.resume(returning: query)
        }
    }
    #else
    public func redirectURI() async throws -> String { throw NativeServiceError("OAuth redirect capture is not carried on this host") }
    public func authorize(url: String) async throws -> String { throw NativeServiceError("OAuth redirect capture is not carried on this host") }
    #endif
}
#endif
