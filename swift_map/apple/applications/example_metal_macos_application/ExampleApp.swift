// The SwiftMap example for macOS: the imperative MapView wrapped for
// SwiftUI. Drag to pan, two-finger scroll to pan, pinch or double-click to
// zoom.

import SwiftMap
import SwiftUI

struct MapViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> MapView {
        let view = MapView()
        view.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 12)
        return view
    }

    func updateNSView(_ view: MapView, context: Context) {}
}

@main
struct ExampleApp: App {
    var body: some Scene {
        WindowGroup("SwiftMap") {
            MapViewRepresentable()
                .frame(minWidth: 640, minHeight: 480)
        }
    }
}
