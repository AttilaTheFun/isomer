// The Isomer module's `AppPackages` on Apple's platforms. A Mac reads and
// opens apps through NSWorkspace and installs a package by handing it to
// the system (Installer for a .pkg, the Finder for a disk image). iOS lets
// an app do none of it: nothing is seen installed, an app opens only by a
// URL of its own, and nothing installs. (Off Apple:
// shared/swift_ui_extensions/AppPackages.swift.)

import Foundation
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Other apps on the device: which are installed and at what version,
/// opening one, and installing one from a package file.
public enum AppPackages {
    /// An installed app's version.
    public struct Installed: Sendable, Hashable {
        /// The version people see (CFBundleShortVersionString).
        public let version: String
        /// The build number (CFBundleVersion, where it is a number).
        public let build: Int
    }

    /// Why an app wasn't installed, in words to show as they are.
    public struct InstallError: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The installed app with `identifier` (a bundle identifier), or nil when
    /// it isn't installed or can't be seen (always, on iOS).
    @MainActor
    public static func installed(_ identifier: String) -> Installed? {
        #if os(macOS)
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
              let info = Bundle(url: url)?.infoDictionary
        else { return nil }
        return Installed(
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: Int(info["CFBundleVersion"] as? String ?? "") ?? 0)
        #else
        return nil
        #endif
    }

    /// Opens the app with `identifier`, or `url` in it (on iOS only a URL
    /// opens an app); whether it opened.
    @MainActor
    @discardableResult
    public static func open(_ identifier: String, url: URL? = nil) async -> Bool {
        #if os(macOS)
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return (try? await NSWorkspace.shared.openApplication(at: app, configuration: .init())) != nil
        }
        guard let url else { return false }
        return NSWorkspace.shared.open(url)
        #elseif os(iOS)
        guard let url else { return false }
        return await UIApplication.shared.open(url)
        #else
        return false
        #endif
    }

    /// Whether this app may install apps: on a Mac, by handing the package
    /// to the system; on iOS, never.
    @MainActor
    public static var mayInstall: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Shows the system's setting that lets this app install apps: none on
    /// Apple's platforms.
    @MainActor
    public static func askToInstall() async {}

    /// Installs the package at `file`: on a Mac, handed to the system (the
    /// person finishes the install there); on iOS, it can't.
    @MainActor
    public static func install(_ file: URL, identifier: String? = nil) async throws {
        #if os(macOS)
        if !NSWorkspace.shared.open(file) {
            throw InstallError(message: "The Mac couldn't open \(file.lastPathComponent).")
        }
        #else
        throw InstallError(message: "Apps can't be installed here.")
        #endif
    }
}
