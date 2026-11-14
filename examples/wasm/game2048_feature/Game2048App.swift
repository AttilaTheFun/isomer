// The Playground's 2048 sample (AttilaTheFun/playground,
// shared/sample_sources/Game2048.swift), wrapped as the Playground's iOS app
// wraps it: the wasm drag benchmark's subject.
import SwiftUI

@main
struct Game2048App: App {
    var body: some Scene {
        WindowGroup { NavigationStack { Game2048Screen() }.preferredColorScheme(.light) }
    }
}
