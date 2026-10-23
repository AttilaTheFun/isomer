// The Playground's host on Apple platforms (iOS and macOS), set as
// `PlaygroundHost.service` before the app starts: the shared shell's
// compiler, runs, chat and settings. It compiles (ToolchainCompiler: the
// swift-frontend and lld the app carries, or the host toolchain on the
// simulator), runs a build in a WasmView (AppleRun), serves a build to an
// in-app Safari on the iPhone (WebRunServer) and signs in to OpenRouter
// (PKCE).

import AuthenticationServices
import CryptoKit
import Foundation
import Isomer
import Security
import SwiftUI
#if os(iOS)
import SafariServices
import UIKit
#endif

final class AppleHost: PlaygroundHostService, @unchecked Sendable {
    /// The last successful build (a project's), for run and runOnWeb.
    private var lastBuild: Data?

    func capabilities() -> String {
        #if os(iOS)
        return "projects,sign-in"
        #else
        return "sign-in"
        #endif
    }

    // MARK: Compiling

    func compile(source: String) async throws -> String {
        #if os(iOS)
        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("playground-source-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let file = work.appendingPathComponent("App.swift")
        try Data(source.utf8).write(to: file)
        let result = await Task.detached { Result { try ToolchainCompiler.compile(files: [file]) } }.value
        switch result {
        case .success(let wasm):
            lastBuild = wasm
            NSLog("[playground] compiled %d bytes", wasm.count)
            return ""
        case .failure(let error):
            return (error as? CompileError)?.diagnostics ?? "\(error)"
        }
        #else
        return "This Mac has no Swift compiler for the Playground yet."
        #endif
    }

    func toolchainStatus() -> String {
        #if os(iOS)
        return ToolchainCompiler.availability ?? "Swift toolchain in the app (swift-frontend and lld)"
        #else
        return "none: no compiler on the Mac yet"
        #endif
    }

    // MARK: Running

    func run(project: String) async throws -> String {
        guard let wasm = lastBuild else { throw HostError("nothing built yet") }
        await MainActor.run {
            AppleRun.shared.start(.init(wasm: wasm, label: "run", name: project, environment: [:]))
        }
        return "running"
    }

    func stop() {
        MainActor.assumeIsolated { AppleRun.shared.stop() }
    }

    func logs() -> String {
        MainActor.assumeIsolated { AppleRun.shared.logs }
    }

    func canRunOnWeb() -> Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    /// The last build in an in-app Safari: the app serves the page and the
    /// reactor (WebRunServer); WebKit runs it with the React renderer.
    func runOnWeb() async throws -> String {
        #if os(iOS)
        guard let wasm = lastBuild else { throw HostError("nothing built yet") }
        guard let url = WebRunServer.shared.publish(wasm: wasm) else { throw HostError("the in-app web server did not start") }
        await MainActor.run {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            var top = scenes.compactMap(\.keyWindow).first?.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            top?.present(SFSafariViewController(url: url), animated: true)
        }
        return "opened \(url.absoluteString)"
        #else
        throw HostError("no web run on the Mac")
        #endif
    }

    // MARK: Driving the run

    func uiTree() -> String { MainActor.assumeIsolated { AppleRun.shared.treeDump() } }
    func tap(target: String) async throws -> String { await MainActor.run { AppleRun.shared.tap(target) } }
    func typeText(target: String, text: String) async throws -> String { await MainActor.run { AppleRun.shared.type(target, text: text) } }
    func submit(target: String) async throws -> String { await MainActor.run { AppleRun.shared.submit(target) } }
    func swipe(target: String, dx: Double, dy: Double) async throws -> String {
        await AppleRun.shared.swipe(target, dx: dx, dy: dy)
    }

    // MARK: Chat and the key

    /// The OpenRouter key: the Playground's (signed in, or pasted), or
    /// ISO_PLAYGROUND_OPENROUTER_KEY for a headless run.
    private var key: String? {
        Keychain.get(Self.keyAccount)
            ?? ProcessInfo.processInfo.environment["ISO_PLAYGROUND_OPENROUTER_KEY"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The account the Playground kept its OpenRouter key under (before 0.38
    /// too, so a signed-in Playground stays signed in).
    private static let keyAccount = "openRouter"

    func chat(body: String) async throws -> String {
        guard let key else { throw HostError("no OpenRouter key: sign in from Settings") }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/AttilaTheFun/isomer", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Isomer Playground", forHTTPHeaderField: "X-Title")
        request.httpBody = Data(body.utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(decoding: data, as: UTF8.self)
    }

    func hasKey() -> Bool { key != nil }

    func setKey(key: String) {
        Keychain.set(key.isEmpty ? nil : key, for: Self.keyAccount)
        UserDefaults.standard.set(key.isEmpty ? nil : "openRouter", forKey: "playground.provider")
    }

    func signIn() async throws -> String {
        #if os(iOS)
        let key = try await OpenRouterSignIn.run()
        setKey(key: key)
        return "signed in"
        #else
        throw HostError("paste a key in Settings")
        #endif
    }

    // MARK: Settings and the rest

    func requestedTemplate() -> String { "" }

    func renderer() -> String { RendererPreference.current }
    func setRenderer(value: String) { UserDefaults.standard.set(value, forKey: RendererPreference.key) }
    func rendererNames() -> String { "SwiftUI,Metal" }
    func rendererFooter() -> String {
        "SwiftUI draws a run with real views; Metal is the self-drawing SwiftGPU renderer. Applies to the next run."
    }

    func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// The projects as the Playground kept them before 0.38
    /// (Documents/Projects/<id>/project.json and files/App.swift), in the
    /// shared store's layout (playground/projects.json, playground/<id>/App.swift).
    func legacyFiles() -> String {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Projects", isDirectory: true)
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var files: [String: JSONValue] = [:]
        var index: [(created: Double, entry: JSONValue)] = []
        for id in ids {
            let directory = root.appendingPathComponent(id, isDirectory: true)
            guard let meta = try? Data(contentsOf: directory.appendingPathComponent("project.json")),
                  let json = parseJSON(String(decoding: meta, as: UTF8.self)), let name = json["name"].string,
                  let source = try? Data(contentsOf: directory.appendingPathComponent("files/App.swift")) else { continue }
            files["playground/\(id)/App.swift"] = .string(source.base64EncodedString())
            index.append((json["createdAt"].double ?? 0, .object(["id": .string(id), "name": .string(name)])))
        }
        guard !index.isEmpty else { return "{}" }
        let projects = JSONValue.object(["projects": .array(index.sorted { $0.created < $1.created }.map(\.entry)), "selection": .null])
        files["playground/projects.json"] = .string(Data(projects.encoded().utf8).base64EncodedString())
        return JSONValue.object(files).encoded()
    }
}

struct HostError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Generic-password strings in the app's keychain.
enum Keychain {
    private static let service = "com.LoganShire.IsomerPlayground"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

#if os(iOS)
/// OpenRouter's OAuth (PKCE): https://openrouter.ai/auth in a web
/// authentication session, its code exchanged for a user-scoped key.
@MainActor
enum OpenRouterSignIn {
    static let callbackScheme = "iso-playground"

    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        var session: ASWebAuthenticationSession?
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
    private static let anchor = Anchor()

    static func run() async throws -> String {
        let verifier = randomVerifier()
        var components = URLComponents(string: "https://openrouter.ai/auth")!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: callbackScheme + "://auth"),
            URLQueryItem(name: "code_challenge", value: base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: callbackScheme) { url, error in
                if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? HostError("sign-in ended")) }
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            anchor.session = session
            session.start()
        }
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw HostError("OpenRouter returned no code")
        }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(JSONValue.object([
            "code": .string(code), "code_verifier": .string(verifier), "code_challenge_method": .string("S256"),
        ]).encoded().utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode ?? 500 < 300,
              let key = parseJSON(String(decoding: data, as: UTF8.self))?["key"].string else {
            throw HostError("key exchange failed: \(String(decoding: data, as: UTF8.self))")
        }
        return key
    }

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
#endif
