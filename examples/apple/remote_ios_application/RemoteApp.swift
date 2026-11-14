// An app whose SwiftUI runs elsewhere, drawn on an iPhone (docs/modes.md):
// IsomerRemoteView over the app's session. Start an app built headless,
// serving itself (docs/remote_sessions.md):
//
//   ISO_DRIVE_LISTEN=ws://0.0.0.0:8090 ISO_HEADLESS_PROTOCOL=serve \
//       bazel-bin/headless/storybook_headless_application/storybook_headless_application
//
// then launch this with the session's URL and the app's launch environment:
//
//   xcrun simctl launch <simulator> com.LoganShire.IsomerExamples.Remote -url ws://127.0.0.1:8090/session
//   (SIMCTL_CHILD_ISO_STORYBOOK_STORY=controls.toggle for a story)
//
// The Android peer is examples/android/remote_android_application.

import Foundation
import IsomerRemoteHead
import SwiftUI

@main
struct RemoteApp: App {
    private let url = UserDefaults.standard.string(forKey: "url") ?? "ws://127.0.0.1:8090/session"
    private let environment = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("ISO_") }

    var body: some Scene {
        WindowGroup {
            IsomerRemoteView(url: url, environment: environment)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}
