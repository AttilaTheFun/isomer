// The Isomer app on the web and Android: the shared shell (shared/app) with
// the host the page (index.html) or the Android app's Kotlin injected.

import SwiftUI

@main
struct PlaygroundWebApp: App {
    init() {
        // The host keeps the renderer choice: it picks the renderer before
        // the app starts.
        RendererPreference.hostStore = (
            get: { PlaygroundHost.service?.renderer() ?? "" },
            set: { PlaygroundHost.service?.setRenderer(value: $0) })
    }

    var body: some Scene { WindowGroup("Isomer") { IsomerRoot() } }
}
