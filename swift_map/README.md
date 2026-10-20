# SwiftMap

An open-source, Swift-native map renderer for OpenStreetMap data — an
alternative to MapKit / Mapbox / Google Maps SDKs whose entire stack is
open. One Bazel module builds the same Swift map engine for every platform;
each platform contributes only a thin GPU renderer and an IO host:

| Platform      | Renderer  | IO host (fetch + decode)             |
| ------------- | --------- | ------------------------------------ |
| iOS / macOS   | Metal     | URLSession + ImageIO (Swift)         |
| Web (wasm)    | WebGPU    | fetch + createImageBitmap (JS)       |
| Android       | OpenGL ES | HttpURLConnection + BitmapFactory (Kotlin) |
| Windows*      | Direct2D  | planned                              |
| Linux*        | OpenGL    | planned                              |

The core engine (`//swift_map/core`) is pure, Foundation-free Swift: Web
Mercator tile math, camera state (center/zoom/bearing/tilt), pan/anchor-zoom
gestures, visible-tile computation with ancestor fallback while tiles stream
in, request deduping, LRU cache policy, and overlays — billboarded
annotation markers and ear-clip-triangulated polygons, emitted as
per-vertex-color triangles every renderer draws with one blended pipeline. The wasm and Android builds cross-compile it with
rules_swift's Swift SDK toolchains and bridge to their hosts through
[swift_ffi](../swift_ffi/)
(`rules_swift < swift_ffi < swift_map < isomer`).

## Two API layers

- **SwiftMap (this repo)** is the imperative layer — the analogue of using
  `MKMapView` / `MapboxMap` directly: create a `MapView`, set its `camera`,
  add it to your hierarchy (`MapEngine` + a renderer if you need to go
  lower, e.g. offscreen).
- **SwiftUI layer (in isomer)** — a declarative `Map` view with a
  two-way `MapCamera` binding (center/zoom/bearing/tilt), in the style of
  MapKit-for-SwiftUI / Mapbox's SwiftUI API. Live on Apple (backed by this
  engine's Metal renderer; see isomer's "Map Explorer" example); the
  other isomer hosts show a placeholder until the engine is wired in.

## Example applications

One example app per platform/renderer pair, named
`example_<renderer>_<platform>_application`:

| Platform | Renderer  | Target                                                       |
| -------- | --------- | ------------------------------------------------------------ |
| macOS    | Metal     | `//swift_map/apple/applications/example_metal_macos_application`       |
| iOS      | Metal     | `//swift_map/apple/applications/example_metal_ios_application`         |
| Web      | WebGPU    | `//swift_map/web/applications/example_webgpu_web_application`          |
| Android  | OpenGL ES | `//swift_map/android/applications/example_opengl_android_application`  |

Everything except the Apple builds is hermetic (no ANDROID_HOME, no host
JDK, no npm; Apple builds use the local Xcode, as all Bazel Apple builds do).

```sh
# macOS — a windowed Metal map (drag / scroll to pan, pinch or double-click
# to zoom).
bazel run //swift_map/apple/applications/example_metal_macos_application

# iOS — build for the simulator, then install with simctl:
bazel build //swift_map/apple/applications/example_metal_ios_application --ios_multi_cpus=sim_arm64
ditto -x -k bazel-bin/apple/applications/example_metal_ios_application/example_metal_ios_application.ipa /tmp/swiftmap_ios
xcrun simctl install booted /tmp/swiftmap_ios/Payload/example_metal_ios_application.app
xcrun simctl launch booted dev.swiftmap.example.ios

# Web — serves on localhost:8080 and opens the browser (WebGPU required).
bazel run //swift_map/web/applications/example_webgpu_web_application

# Android — boots the hermetic emulator if no device is connected,
# installs, launches, and tails logcat.
bazel run //swift_map/android/applications/example_opengl_android_application

# Engine unit tests + an offscreen Metal render of real OSM tiles to a PNG:
bazel test //swift_map/tests:core_tests
bazel run //swift_map/apple/tools/map_snapshot -- /tmp/map.png
```

## XCFramework / Swift Package distribution

For iOS/macOS consumers outside Bazel, SwiftMap ships as a prebuilt
XCFramework (static, library evolution enabled, `.swiftinterface` included)
wrapped in a binary Swift package:

```sh
bazel build //swift_map/apple/xcframework:SwiftMap
ditto -x -k bazel-bin/apple/xcframework/SwiftMap.xcframework.zip distribution/
```

Then depend on the package at `distribution/` (or publish the zip and switch
`distribution/Package.swift` to `url:` + `checksum:`):

```swift
.package(path: "path/to/swift_map/distribution")
```

```swift
import SwiftMap

let map = MapView()
map.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 12)
view.addSubview(map)
```

## Tile source & attribution

The default configuration uses the openstreetmap.org raster tile server,
which is fine for development and light use but **not for production**
(see the [tile usage policy](https://operations.osmfoundation.org/policies/tiles/));
point `MapConfiguration.tileURLTemplate` at your own tile source for real
deployments. Every renderer displays the required "© OpenStreetMap
contributors" attribution (ODbL); keep it visible in your apps too.

## Architecture

See [docs/architecture.md](docs/architecture.md) for the engine design, the
host protocol each platform implements, the frame JSON that crosses the FFI
bridges, and the per-platform threading contracts.

## Roadmap

- Vector tiles (MVT) with GPU tessellation — the reason the renderers are
  pluggable rather than a Canvas2D blit.
- Polylines and richer annotation content (labels, callouts); dot markers
  and polygons landed with the overlay engine.
- Inertial pan/zoom animation (the engine is event-driven today).
- Wiring the engine into isomer's wasm/Android hosts (the SwiftUI
  `Map` placeholder there).
- Windows (Direct2D) and Linux (OpenGL) hosts.
- @2x raster tiles for hidpi displays.
