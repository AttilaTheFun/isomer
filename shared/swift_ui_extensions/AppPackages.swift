import Foundation
import SwiftUI

/// Other apps on the device: which are installed and at what version,
/// opening one, and installing one from a package file, as an app store
/// does. Isomer's own (Apple's SwiftUI has none). Here it is the host's:
/// Android's PackageManager and PackageInstaller (whose manifest must name
/// the packages it reads in `<queries>`, and ask for
/// REQUEST_INSTALL_PACKAGES to install); elsewhere off Apple, nothing is
/// installed and nothing can be. On Apple's platforms,
/// apple/libraries/swift_ui/AppleAppPackages.swift.
public enum AppPackages {
    /// An installed app's version.
    public struct Installed: Sendable, Hashable {
        /// The version people see ("1.4.2": Android's versionName).
        public let version: String
        /// The build number updates are ordered by (Android's versionCode).
        public let build: Int
    }

    /// Why an app wasn't installed, in words to show as they are.
    public struct InstallError: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The installed app with `identifier` (a package name, a bundle
    /// identifier), or nil when it isn't installed or can't be seen.
    @MainActor
    public static func installed(_ identifier: String) -> Installed? {
        guard let line = Runtime.shared.host?.hostValue("package.installed:" + identifier) else { return nil }
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 2, let build = Int(parts[1]) else { return nil }
        return Installed(version: String(parts[0]), build: build)
    }

    /// Opens the app with `identifier` (its launcher's entry), or `url` in
    /// it when it has none; whether it opened.
    @MainActor
    @discardableResult
    public static func open(_ identifier: String, url: URL? = nil) async -> Bool {
        await Runtime.shared.host?.hostRequest("package.open", identifier + "\n" + (url?.absoluteString ?? "")) == "1"
    }

    /// Whether this app may install apps now (Android's "install unknown
    /// apps", which the person turns on for it).
    @MainActor
    public static var mayInstall: Bool {
        Runtime.shared.host?.hostValue("package.mayInstall") == "1"
    }

    /// Shows the system's setting that lets this app install apps.
    @MainActor
    public static func askToInstall() async {
        _ = await Runtime.shared.host?.hostRequest("package.askToInstall", "")
    }

    /// Installs the package at `file` (an APK), the system asking the person
    /// first; returns once it is installed. `identifier` is the app's, when
    /// known (the system checks the package is that app).
    @MainActor
    public static func install(_ file: URL, identifier: String? = nil) async throws {
        guard let host = Runtime.shared.host,
              let failure = await host.hostRequest("package.install", file.path + "\n" + (identifier ?? ""))
        else { throw InstallError(message: "Apps can't be installed here.") }
        if !failure.isEmpty { throw InstallError(message: failure) }
    }
}
