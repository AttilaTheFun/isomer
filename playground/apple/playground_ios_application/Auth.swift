// Sign-in: "Sign in with OpenRouter" (OAuth PKCE through
// ASWebAuthenticationSession → a user-scoped OpenRouter key) or an Anthropic
// API key pasted in settings. Keys live in the Keychain. A claude.ai
// subscription cannot be used by a third-party app (Anthropic does not
// allow third parties to offer claude.ai login), hence the provider seam.

import Foundation
import Security
import CryptoKit
import SwiftUI
#if os(iOS)
import AuthenticationServices
import UIKit
#endif

enum ModelProvider: String, Codable, CaseIterable, Identifiable {
    case openRouter
    case anthropic
    var id: String { rawValue }
    var title: String { self == .openRouter ? "OpenRouter" : "Anthropic API key" }
}

/// How the model is driven.
enum Harness: String, CaseIterable, Identifiable {
    /// Tools: write files, build with diagnostics fed back, run.
    case agent
    /// Conversation only — no tools, nothing written or built.
    case chat
    var id: String { rawValue }
    var title: String { self == .agent ? "Agent" : "Chat only" }
    var detail: String {
        self == .agent ? "Writes files, builds, fixes errors, runs the result." : "Answers questions; never touches the project."
    }
}

/// Minimal Keychain string storage (generic passwords under the app).
enum Keychain {
    private static let service = "com.LoganShire.Isomer"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
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

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var provider: ModelProvider?
    @Published private(set) var key: String?
    @Published var modelID: String {
        didSet { UserDefaults.standard.set(modelID, forKey: "playground.model") }
    }
    @Published var signingIn = false
    @Published var error: String?
    /// The agent harness: full tool loop, or plain chat (no tools).
    @Published var harness: Harness {
        didSet { UserDefaults.standard.set(harness.rawValue, forKey: "playground.harness") }
    }
    /// Reasoning effort passed to models that support it ("" = default).
    @Published var reasoningEffort: String {
        didSet { UserDefaults.standard.set(reasoningEffort, forKey: "playground.reasoning") }
    }

    var isSignedIn: Bool { key != nil && provider != nil }

    init() {
        var storedProvider = UserDefaults.standard.string(forKey: "playground.provider")
            .flatMap(ModelProvider.init(rawValue:))
        var storedKey = storedProvider.flatMap { Keychain.get($0.rawValue) }
        if storedKey == nil { storedProvider = nil }
        // A headless override (simulator/CI): ISO_PLAYGROUND_OPENROUTER_KEY.
        let env = ProcessInfo.processInfo.environment
        if storedKey == nil, let injected = env["ISO_PLAYGROUND_OPENROUTER_KEY"], !injected.isEmpty {
            storedProvider = .openRouter
            storedKey = injected
        }
        var model = UserDefaults.standard.string(forKey: "playground.model") ?? ""
        if model.isEmpty { model = Self.defaultModel(for: storedProvider ?? .openRouter) }
        provider = storedProvider
        key = storedKey
        modelID = model
        harness = Harness(rawValue: UserDefaults.standard.string(forKey: "playground.harness") ?? "") ?? .agent
        reasoningEffort = UserDefaults.standard.string(forKey: "playground.reasoning") ?? ""
    }

    static func defaultModel(for provider: ModelProvider) -> String {
        // Cheap, capable defaults for testing; users can pick pricier ones.
        provider == .openRouter ? "anthropic/claude-sonnet-5" : "claude-sonnet-5"
    }

    func link(provider: ModelProvider, key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.set(trimmed, for: provider.rawValue)
        UserDefaults.standard.set(provider.rawValue, forKey: "playground.provider")
        self.provider = provider
        self.key = trimmed
        if modelID.isEmpty || !modelID.contains(provider == .openRouter ? "/" : "claude") {
            modelID = Self.defaultModel(for: provider)
        }
    }

    func signOut() {
        if let provider { Keychain.set(nil, for: provider.rawValue) }
        UserDefaults.standard.removeObject(forKey: "playground.provider")
        provider = nil
        key = nil
    }

    // MARK: OpenRouter OAuth (PKCE)

    static let callbackScheme = "iso-playground"
    static let callbackURL = "iso-playground://auth"

    #if os(iOS)
    /// Runs https://openrouter.ai/auth in a web auth session and exchanges
    /// the returned code for a user-scoped key (POST /api/v1/auth/keys).
    func signInWithOpenRouter() {
        guard !signingIn else { return }
        signingIn = true
        error = nil
        let verifier = Self.randomVerifier()
        let challenge = Self.challenge(for: verifier)
        var components = URLComponents(string: "https://openrouter.ai/auth")!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: Self.callbackURL),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: Self.callbackScheme) { [weak self] url, sessionError in
            Task { @MainActor in
                guard let self else { return }
                defer { self.signingIn = false }
                if let sessionError {
                    if (sessionError as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                        self.error = sessionError.localizedDescription
                    }
                    return
                }
                guard let url, let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "code" })?.value else {
                    self.error = "OpenRouter returned no code"
                    return
                }
                do {
                    let key = try await Self.exchange(code: code, verifier: verifier)
                    self.link(provider: .openRouter, key: key)
                } catch {
                    self.error = "Key exchange failed: \(error.localizedDescription)"
                }
            }
        }
        session.presentationContextProvider = AuthPresentationContext.shared
        session.prefersEphemeralWebBrowserSession = false
        AuthPresentationContext.shared.session = session
        session.start()
    }
    #endif

    static func exchange(code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code, "code_verifier": verifier, "code_challenge_method": "S256",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode ?? 500 < 300,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["key"] as? String else {
            throw NSError(domain: "OpenRouter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "bad response"])
        }
        return key
    }

    static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

#if os(iOS)
final class AuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthPresentationContext()
    var session: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}
#endif

// MARK: - Splash / sign-in UI

struct SplashView: View {
    @EnvironmentObject private var auth: AuthStore
    @State private var provider: ModelProvider = .openRouter
    @State private var key = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "swift")
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(spacing: 8) {
                Text("Playground").font(.largeTitle.bold())
                Text("Describe an app. An agent writes the SwiftUI, and the app compiles and runs it right here.")
                    .font(.body).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Spacer()
            VStack(spacing: 14) {
                providerSwitch
                keyField
                Button(action: link) {
                    Text("Continue").fontWeight(.semibold)
                        .frame(maxWidth: .infinity).frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(provider == .openRouter
                     ? "Create a key at openrouter.ai/keys (set a spending limit). Cheap models for experiments; Opus and Fable when it matters."
                     : "Create a key at platform.claude.com → Settings → Keys.")
                    .font(.caption2).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Text("Stored in this device's Keychain only. Usage is billed to your own account.")
                    .font(.caption2).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 380)
            .padding(.bottom, 32)
        }
        .padding()
    }

    /// A capsule segmented switch at the same 50pt height as the field and
    /// button (UISegmentedControl won't grow past its intrinsic height).
    private var providerSwitch: some View {
        let picker = HStack(spacing: 4) {
            ForEach(ModelProvider.allCases) { option in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { provider = option }
                } label: {
                    Text(option.title)
                        .font(.body.weight(provider == option ? .semibold : .regular))
                        .foregroundColor(provider == option ? .primary : .secondary)
                        .frame(maxWidth: .infinity).frame(height: 42)
                        .background(
                            Capsule().fill(provider == option ? Color.accentColor.opacity(0.18) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(height: 50)
        return Group {
            if #available(iOS 26, macOS 26, *) {
                picker.glassEffect(.regular, in: .capsule)
            } else {
                picker.background(.thinMaterial, in: Capsule())
            }
        }
    }

    /// The key entry: a tall capsule with the Liquid Glass treatment on
    /// iOS 26 (a translucent capsule fill on older systems).
    @ViewBuilder private var keyField: some View {
        let field = SecureField(provider == .openRouter ? "OpenRouter API key (sk-or-…)" : "Anthropic API key (sk-ant-…)", text: $key)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.asciiCapable)
            #endif
            .onSubmit(link)
            .padding(.horizontal, 20)
            .frame(height: 50)
        if #available(iOS 26, macOS 26, *) {
            field.glassEffect(.regular, in: .capsule)
        } else {
            field.background(.thinMaterial, in: Capsule())
        }
    }

    private func link() {
        auth.link(provider: provider, key: key)
    }
}

/// Paste-a-key sheet (Anthropic direct, or an OpenRouter key by hand).
struct KeyEntrySheet: View {
    let provider: ModelProvider
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(provider == .anthropic ? "sk-ant-…" : "sk-or-…", text: $key)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text(provider.title)
                } footer: {
                    Text(provider == .anthropic
                         ? "Create a key at platform.claude.com → Settings → Keys. Stored in this device's Keychain only."
                         : "Create a key at openrouter.ai/keys. Stored in this device's Keychain only.")
                }
            }
            .navigationTitle("Link a key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Link") { auth.link(provider: provider, key: key); dismiss() }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
