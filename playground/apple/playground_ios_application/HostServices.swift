// The Playground's platform services for agent-written apps: the shared
// Apple implementations (shared/platform_services + apple/platform_services_host),
// the keychain per project. A run's files and UserDefaults are Foundation's,
// in its project's home (WasmViewModel.guestHomeDirectory).

import Foundation
import ApplePlatformServices
import SwiftFFIWasmHost
import IsomerWasmView

/// The swift_ffi export prefix of the `platform_services` namespace.
let playgroundFFIPrefix = platformServicesFFIPrefix

/// The dependency table for one project's preview: a per-project keychain
/// namespace, analytics to the log, and a small flag table. Also gives the
/// model's runs the project's home: <project>/data, the folder its file
/// sandbox was before 0.31.
@MainActor
func playgroundDependencies(projectID: String, projects: ProjectStore, model: WasmViewModel) -> [String: SwiftFFIDependency] {
    model.guestHomeDirectory = projects.sandboxDir(projectID).path
    model.guestBundleIdentifier = "dev.isomer.playground.run." + projectID
    return applePlatformDependencies(
        namespace: "playground." + projectID,
        flags: ["promo_banner": true],
        analytics: { NSLog("[playground] analytics %@", $0) })
}
