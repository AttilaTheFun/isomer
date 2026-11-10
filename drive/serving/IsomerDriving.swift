// Where a headful app (built with --@isomer//drive:headful) dials out to, and
// how it stays attached: both drivers' (drive/headful's for Isomer's hosts,
// drive/apple's for Apple's SwiftUI).
//
// ISO_DRIVER names a hub or a test's own (`none`: nowhere). Without it the
// app dials the iso CLI's hub on the machine it runs on (`iso` starts one):
// ws://127.0.0.1:7710, which a simulator's app and a browser's page on that
// machine reach as it is, and an Android emulator's as 10.0.2.2, its name for
// the machine it runs on. Such an app attaches under its platform's name
// (`ios`, `android`, `web`, `macos`, …) unless ISO_DRIVER_NAME names it, so
// several apps on one hub are told apart: `iso --app ios,android,web tap Tap`.

import Foundation

public enum IsomerDriving {
    /// The iso CLI's hub's port.
    public static let hubPort = 7710

    /// Where an app dials with no ISO_DRIVER.
    public static var defaultHub: String {
        #if os(Android)
        "ws://10.0.2.2:\(hubPort)"
        #else
        "ws://127.0.0.1:\(hubPort)"
        #endif
    }

    /// Where to dial and the name to attach under (nil: the hub names the app
    /// by its own name), or nil when the app dials nowhere.
    public static func destination(_ environment: [String: String], platform: String) -> (url: URL, name: String?)? {
        let given = environment["ISO_DRIVER"]
        if given == "none" { return nil }
        guard let url = URL(string: given ?? defaultHub) else { return nil }
        let name = environment["ISO_DRIVER_NAME"] ?? (given == nil ? platform.lowercased() : nil)
        return (url, name)
    }

    /// Attaches with `attach`, and again whenever that ends or fails (the hub
    /// not there yet, or gone), a second apart, for as long as the app runs:
    /// so it doesn't matter whether the app or the hub starts first. `report`
    /// is told when it attaches and when it's waiting, not of every try.
    public static func keepAttached(
        to address: String,
        report: @escaping @Sendable (String) -> Void,
        attach: @escaping @Sendable () async throws -> Void
    ) async {
        var waiting = false
        while !Task.isCancelled {
            let started = Date()
            do {
                try await attach()
                report("driver at \(address): the call ended")
                waiting = false
            } catch {
                if !waiting { report("driver: waiting for a hub at \(address) (\(error))") }
                waiting = true
            }
            // An attachment that lasted a while ended: dial again at once.
            if Date().timeIntervalSince(started) < 1 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
