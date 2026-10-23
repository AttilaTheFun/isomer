// The Gallery as an `iso_hot` reactor: the Isomer app carries it and runs
// it on the platform's wasm engine ("Run as wasm"), opened on the entry its
// ISO_OPEN_APP names.

import Gallery
import SwiftUI

@main
struct GalleryReactor: App {
    var body: some Scene {
        WindowGroup("Gallery") { GalleryView() }
    }
}
