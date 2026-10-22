// Map Explorer: the SwiftUI `Map` view (SwiftMap-backed on Apple) embedded
// in a page with on-screen camera controls, all driven through the two-way
// camera binding:
//   * top right     — a slider (with −/+ buttons) for smooth zooming
//   * bottom left   — a D-pad tilting (▲▼) and rotating (◀▶) the camera
//   * bottom right  — a D-pad panning in screen directions
// Gestures work too (drag / pinch / two-finger rotate); the controls and
// gestures share the same binding.

import SwiftUI
import Isomer

/// Headless-verification hook: ISO_MAP_CAMERA="lat,lon,zoom,bearing,tilt"
/// overrides the initial camera (exercises the binding -> Map -> engine
/// path without taps).
private let initialCamera: MapCamera = {
    var camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 12)
    if let override = launchEnvironment("ISO_MAP_CAMERA") {
        let parts = override.split(separator: ",").compactMap { Double($0) }
        if parts.count == 5 {
            camera = MapCamera(latitude: parts[0], longitude: parts[1], zoom: parts[2], bearing: parts[3], tilt: parts[4])
        }
    }
    return camera
}()

/// Sample overlays: SF landmark markers (tap one for its callout), the
/// Golden Gate Park footprint, and the Alcatraz ferry route.
private let landmarks = [
    MapAnnotation(id: "ferry", latitude: 37.7955, longitude: -122.3937, title: "Ferry Building"),
    MapAnnotation(id: "goldengate", latitude: 37.8199, longitude: -122.4783, color: MapColor(red: 0, green: 0.48, blue: 1), title: "Golden Gate Bridge"),
    MapAnnotation(id: "alcatraz", latitude: 37.8270, longitude: -122.4230, color: MapColor(red: 0.2, green: 0.78, blue: 0.35), radius: 10, title: "Alcatraz Island"),
]

private let routes = [
    MapPolyline(
        id: "ferryroute",
        coordinates: [
            [37.7955, -122.3937], [37.8080, -122.4090],
            [37.8210, -122.4180], [37.8270, -122.4230],
        ],
        color: MapColor(red: 0, green: 0.48, blue: 1, alpha: 0.9),
        width: 4
    ),
]

private let parks = [
    MapPolygon(
        id: "goldengatepark",
        coordinates: [
            [37.7714, -122.5110], [37.7748, -122.4553],
            [37.7680, -122.4547], [37.7645, -122.5104],
        ],
        fillColor: MapColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 0.35),
        strokeColor: MapColor(red: 0.2, green: 0.78, blue: 0.35),
        strokeWidth: 3
    ),
]

struct MapExplorerScreen: View {
    @State private var camera = initialCamera
    @State private var tappedLandmark: String?

    private let tiltStep = 10.0
    private let rotateStep = 15.0
    private let panStep = 120.0

    var body: some View {
        ZStack {
            Map(
                camera: $camera,
                annotations: landmarks,
                polygons: parks,
                polylines: routes,
                onAnnotationTap: { annotation in
                    tappedLandmark = annotation.title
                }
            )
            controls
        }
        .navigationTitle("Map")
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack {
                if let tappedLandmark {
                    Text("Tapped: \(tappedLandmark)")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(panelColor)
                        .cornerRadius(10)
                }
                Spacer()
                zoomPanel
            }
            Spacer()
            HStack(alignment: .bottom) {
                tiltPad
                Spacer()
                panPad
            }
        }
        .padding(16)
    }

    // MARK: Zoom (top right)

    private var zoomPanel: some View {
        HStack(spacing: 10) {
            Button {
                camera.zoom = max(camera.zoom - 1, 1)
            } label: {
                Text("−").font(.title3)
            }
            Slider(value: $camera.zoom, in: 1...19)
                .frame(width: 160)
            Button {
                camera.zoom = min(camera.zoom + 1, 19)
            } label: {
                Text("+").font(.title3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(panelColor)
        .cornerRadius(12)
    }

    // MARK: Tilt / rotate (bottom left)

    private var tiltPad: some View {
        VStack(spacing: 6) {
            padButton("▲") { camera.tilt = min(camera.tilt + tiltStep, 60) }
            HStack(spacing: 6) {
                padButton("◀") { camera.bearing -= rotateStep }
                padButton("⦿") {
                    camera.bearing = 0
                    camera.tilt = 0
                }
                padButton("▶") { camera.bearing += rotateStep }
            }
            padButton("▼") { camera.tilt = max(camera.tilt - tiltStep, 0) }
            Text("Tilt / Rotate")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(panelColor)
        .cornerRadius(12)
    }

    // MARK: Pan (bottom right)

    private var panPad: some View {
        VStack(spacing: 6) {
            padButton("▲") { camera.pan(deltaX: 0, deltaY: panStep) }
            HStack(spacing: 6) {
                padButton("◀") { camera.pan(deltaX: panStep, deltaY: 0) }
                padButton("⦿") {
                    camera.latitude = 37.7749
                    camera.longitude = -122.4194
                }
                padButton("▶") { camera.pan(deltaX: -panStep, deltaY: 0) }
            }
            padButton("▼") { camera.pan(deltaX: 0, deltaY: -panStep) }
            Text("Pan")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(panelColor)
        .cornerRadius(12)
    }

    private func padButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .frame(width: 34, height: 34)
                .background(buttonColor)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // App-defined adaptive colors (`Color.dynamic`): the same shared source
    // adapts on every platform — natively (trait-based dynamic provider) on
    // Apple, through the runtime's scheme on the reimplementation platforms.
    // The map tiles stay light, so the chrome floats translucent above them
    // in both schemes.
    private var panelColor: Color {
        Color.dynamic(
            light: Color.white.opacity(0.75),
            dark: Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.8))
    }

    private var buttonColor: Color {
        Color.dynamic(
            light: Color.white.opacity(0.9),
            dark: Color(red: 0.17, green: 0.17, blue: 0.19).opacity(0.9))
    }
}
