// The Playground on Linux and Windows: the shared shell (shared/app) against
// Isomer's SwiftUI, with the desktop host installed before it starts.

import SwiftUI

@main
struct PlaygroundDesktopApp: App {
    init() {
        PlaygroundHost.service = DesktopHost()
        PlaygroundSurfaces.run = { onStopped in AnyView(DesktopRunSurface(onStopped: onStopped)) }
    }

    var body: some Scene {
        WindowGroup("Playground") { PlaygroundRoot() }
    }
}
