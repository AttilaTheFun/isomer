// The Playground on the web and Android: the shared shell (shared/app) with
// the host the page (index.html) or the Android app's Kotlin injected.

import SwiftUI

@main
struct PlaygroundWebApp: App {
    var body: some Scene { WindowGroup("Playground") { PlaygroundRoot() } }
}
