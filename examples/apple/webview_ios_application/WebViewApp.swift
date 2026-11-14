// The Storybook in web-view mode on an iPhone (docs/modes.md): its Swift
// built as wasm (the web Storybook's site, bundled), run in a web view the
// app keeps out of sight, and drawn by Isomer's tree renderer over the
// session protocol (IsomerWebViewAppView). No Swift of the Storybook's is
// compiled into the app.
//
// A story by its launch hook, as the native Storybook takes it:
//
//   SIMCTL_CHILD_ISO_STORYBOOK_STORY=controls.toggle \
//       xcrun simctl launch <simulator> com.LoganShire.IsomerExamples.WebView
//
// The remote peer is examples/apple/remote_ios_application (the app on a
// server instead of in a page).

import Foundation
import IsomerWebViewHead
import SwiftUI

@main
struct WebViewApp: App {
    private let environment = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("ISO_") }

    var body: some Scene {
        WindowGroup {
            if let site = IsomerWebViewHost.bundledSite(named: "storybook_web_application_site") {
                IsomerWebViewAppView(site: site, environment: environment)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                Text("The Storybook's web site isn't in the app's bundle.")
            }
        }
    }
}
