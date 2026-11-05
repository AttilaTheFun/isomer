import Foundation
import SwiftUI

// Bundle's resources on Android (isomer_android_app's `resources`): a string
// from the app's strings tables, in the device's language, and what Bundle
// found. `adb shell cmd locale set-app-locales dev.isomer.bundleprobe
// --locales fr-CA` turns it French.
@main
struct BundleProbe: App {
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text(NSLocalizedString("probe.greeting", comment: "The probe's greeting"))
                    .font(.title)
                Text("localizations: \(Bundle.main.localizations.joined(separator: ", "))")
                Text("preferred: \(Bundle.main.preferredLocalizations.joined(separator: ", "))")
                Text("resource: \(Bundle.main.url(forResource: "probe", withExtension: "txt") != nil ? "found" : "missing")")
            }
            .padding()
        }
    }
}
