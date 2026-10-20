// The SwiftMap example for iOS: the imperative MapView wrapped for SwiftUI.
// Drag to pan, pinch or double-tap to zoom.
//
// The canImport guard keeps host-platform wildcard builds (`bazel build
// //...`) compiling this swift_library for macOS, where UIKit is absent.

#if canImport(UIKit)

import SwiftMap
import SwiftUI

struct MapViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> MapView {
        let view = MapView()
        view.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 12)
        return view
    }

    func updateUIView(_ view: MapView, context: Context) {}
}

@main
struct ExampleApp: App {
    var body: some Scene {
        WindowGroup {
            MapViewRepresentable()
                .ignoresSafeArea()
        }
    }
}

#endif
