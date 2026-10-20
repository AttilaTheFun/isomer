# SwiftMap architecture

## The split

```
                 ┌────────────────────────────┐
                 │   //swift_map/core (Swift) │  pure, Foundation-free
                 │  camera · tile math ·      │  shared source of truth
                 │  fetch/cache policy ·      │  (compiled per platform)
                 │  frame building            │
                 └──────────┬─────────────────┘
              MapEngineHost │ MapFrame
       ┌────────────────────┼─────────────────────┐
       │                    │                     │
 Apple (direct)        wasm (swift_ffi)      Android (swift_ffi)
 MapView + Metal       boot.js + WebGPU      MapSurfaceView + GLES2
 URLSession/ImageIO    fetch/ImageBitmap     HttpURLConnection/BitmapFactory
```

The engine decides *what* to fetch, keep, and draw; the platform host owns
the bytes and pixels. The host implements three calls — `requestTile(key,
url)`, `evictTile(key)`, `setNeedsRender()` — and drives the engine with
input events; the engine hands back a `MapFrame` of textured quads whenever
the host paints. There is **no frame loop**: rendering is event-driven
(gesture, tile arrival, camera set), the same discipline isomer's
high-level renderers follow.

## Core engine (`//swift_map/core`)

- **Tile math** (`TileMath`, `TileKey`): standard slippy-map Web Mercator.
  The world is a `tileSize * 2^zoom`-point square; latitude clamps at
  ±85.051° so it stays square. `TileKey` ("z/x/y") is also the host-side
  texture identifier string.
- **Camera** (`MapCamera`): latitude/longitude/fractional zoom. Clamping
  wraps longitude, pins the viewport inside the world square vertically,
  and bounds zoom to the configuration.
- **Gestures**: `pointer(phase:x:y:)` implements drag panning;
  `zoom(by:anchorX:anchorY:)` keeps the geographic point under the anchor
  fixed (wheel/pinch semantics); `pan(deltaX:deltaY:)` moves content with
  the finger.
- **Frame building** (`buildFrame()`): picks the integer tile zoom nearest
  the camera zoom, walks the covering tile range (x wraps, y clamps),
  requests missing tiles once (`pending` dedupes), and substitutes the
  nearest **ready ancestor** with a quadrant UV sub-rect for anything still
  in flight — so zooming in shows upscaled parents until children stream in.
  After each frame, ready/failed tiles beyond `maxCachedTiles` that were not
  displayed this frame are evicted oldest-first (`evictTile`, host frees the
  texture). Pending tiles are never evicted (the request is in flight).
- **Threading**: single-threaded by contract, on the host's render thread —
  main thread (Apple), GL thread (Android), JS thread (web).

## The frame JSON (FFI platforms)

Swift builds the frame; the JS/Kotlin renderer draws it. One compact object
crosses the bridge per paint:

```json
{"w":800,"h":600,"lat":37.7749,"lon":-122.4194,"zoom":12,
 "quads":[{"k":"12/655/1582","x":-37.4,"y":-12.5,"s":256,"u":0,"v":0,"d":1}]}
```

`k` names the texture, `x`/`y`/`s` the screen-space square in points, and
`u`/`v`/`d` the (square) UV sub-rect — `d < 1` marks an ancestor fallback.
Numbers are rounded to 4 decimals by a Foundation-free formatter.

## Platform hosts

### Apple (`//swift_map/apple/libraries/swift_map`, module `SwiftMap`)

Direct Swift: no FFI. `MapView` (MTKView, `isPaused` +
`enableSetNeedsDisplay`) owns a `MapEngine`, a `MetalTileRenderer`
(runtime-compiled MSL, one textured draw per quad, texture cache keyed by
`TileKey.id`), and a `TileTextureLoader` (URLSession with the OSM
User-Agent, ImageIO decode, RGBA8 upload; completion hops to the main
queue). AppKit: drag + scroll pan, magnify + double-click zoom, flipped
coordinates. UIKit: pan/pinch/double-tap recognizers (simultaneous).
`//swift_map/apple/tools/map_snapshot` renders offscreen (shared-storage render
target) to a PNG for verification. The same library ships as
`SwiftMap.xcframework` (library evolution + `.swiftinterface`).

### Web (`//swift_map/wasm/libraries/swift_map` + `//swift_map/web/applications/...`)

`WebBridge.swift` declares `@ExportedInterface MapWebHost` (presentFrame /
requestTile / evictTile / scheduleRender / log) and `@ExportedFunction`s
(`smStart`, `smRender`, `smPointer`, `smPan`, `smZoom`, `smSetCamera`,
`smResize`, `smTileLoaded`, `smTileFailed`). swift_ffi's `ts_swift_library`
produces the wasm reactor (16 MiB stack linkopt) and typed bindings;
`runtime/boot.js` implements the host: rAF-coalesced `smRender()`, fetch +
`createImageBitmap` decode, `webgpu_tile_renderer.js` (one vertex buffer per
frame, bind group per tile texture). Push model: Swift serializes the frame
and calls `presentFrame` — exported-function returns stay simple. Smoke-test
hooks: `window.__smBridge`, `window.__smLastFrame`.

### Android (`//swift_map/android/libraries/swift_map` + `//swift_map/android/applications/...`)

`AndroidBridge.swift` mirrors the web surface as `MapAndroidHost`.
swift_ffi's `kt_swift_library` produces the JNI `.so`
(`libswift_map_bindings.so`) and Kotlin bindings under
`dev.swiftmap.runtime`, compiled together with the hand-written runtime:
`MapSurfaceView` (GLSurfaceView, `RENDERMODE_WHEN_DIRTY`) marshals every
engine call onto the GL thread (`queueEvent` for touch, `onDrawFrame` calls
`smRender()`, decoded tiles upload + report on the GL thread).
`GLTileRenderer` draws GLES2 textured quads in dp space (density only feeds
`glViewport`). GL context loss restarts the engine (`smStart` is
re-callable) since the textures died with the context. `MapView` wraps the
surface in a FrameLayout with the attribution overlay. Platform APIs only —
the runtime adds no Maven dependencies.

## Verification

- `bazel test //swift_map/tests:core_tests` — engine unit tests (reference
  tile 11/327/791, mercator roundtrip, anchor-fixed zoom, fallback UVs,
  eviction, JSON shape).
- `bazel run //swift_map/apple/tools/map_snapshot -- /tmp/map.png` — real tiles
  through the Metal pipeline, offscreen.
- `tools/testing/cdp.py` — headless-Chrome driver (trusted input,
  `--enable-unsafe-webgpu`) against the served web app; assert on
  `window.__smLastFrame`.
- Android: the hermetic emulator (`bazel run //swift_map/tools/android/emulator`),
  `adb exec-out screencap`, and `adb shell input swipe` for pan.
