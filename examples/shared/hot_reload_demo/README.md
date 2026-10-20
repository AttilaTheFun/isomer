# Cross-platform hot-reload demo

One edit, live on iOS and Android at the same time. This demo boots the iOS
simulator **and** the hermetic Android emulator, installs the same
embedded-wasm-feature app on both, starts the hot-reload server, and connects
both apps to it. Then you edit one SwiftUI file and save — both apps re-render
the feature in a few seconds, and **the native host processes never restart**.

The feature UI is compiled to a WebAssembly reactor (`hot_demo.wasm`) that the
native apps embed and swap at runtime. The host owns native concerns
(dependency injection over the swift_ffi transport, native-view bridging); the
wasm feature stays declarative SwiftUI. Editing the feature rebuilds only the
wasm, so the swap is fast and the host keeps its state.

## Run it

```sh
bazel run //examples/shared/hot_reload_demo
```

That single command:

1. Builds both apps + the macOS hot-reload server.
2. Boots the iOS simulator; if no Android device is attached, starts the
   hermetic Android emulator **with a window** (`//tools/android/emulator`) so
   you can watch it re-render. Set `HEADLESS=1` for an unattended run.
3. Installs both apps.
4. Starts the hot-reload server on `:8787`.
5. Launches both apps connected to the server (Android reaches the host via
   `adb reverse`).

When it prints `READY`, make the loop live:

```sh
# edit and save — both apps re-render, no restart
$EDITOR examples/wasm/hot_demo_feature/HotDemo.swift
```

Try changing `accent`, `greeting`, or adding a row to `items`. Save, and watch
both the simulator and emulator update (~10–15 s: a scoped bazel rebuild of just
the wasm, then the swap). `Ctrl-C` stops the server; the apps stay up.

## Prerequisites

- **macOS** with Xcode (provides `xcrun simctl` and the iOS simulator runtime).
- **bazel** via the repo's `bazelisk`/`.bazelversion` (same as the rest of the
  workspace).
- No local Android SDK needed — the emulator and `adb` are hermetic, fetched by
  bazel. First run downloads them, so it takes longer.

## Variations

All are environment variables on the `bazel run`:

| Want | How |
| --- | --- |
| A physical Android phone instead of the emulator | Plug it in (USB debugging on, screen unlocked), then `ANDROID_SERIAL=<serial> bazel run …`. Get the serial from `adb devices`. |
| A specific iOS simulator | `SIM_UDID=<udid> bazel run …` (list them with `xcrun simctl list devices`). The default is a specific local simulator and will differ on your machine. |
| A different port | `ISO_HOT_RELOAD_PORT=9000 bazel run …` |
| An unattended run (CI, no display) | `HEADLESS=1 bazel run …` — starts the emulator with `-no-window`. |

### Just one platform

You don't need both devices. The macOS host app runs the same feature with the
same live-reload loop, no simulator or emulator involved:

```sh
# terminal 1: the server
bazel run //examples/apple/example_partial_wasm_macos_application:hot_reload_server

# terminal 2: the host app (connects to the server, then edit HotDemo.swift)
bazel run //examples/apple/example_partial_wasm_macos_application
```

The iOS simulator or Android emulator alone works too — the full demo is just
both of those plus the server wired together.

## How it works

- **`examples/wasm/hot_demo_feature/HotDemo.swift`** — the watched file. It
  compiles *only* into `hot_demo.wasm`, never into a host binary. It's plain
  SwiftUI, plus two host integration points: a native-injected feature flag
  (`AppHost.current?.flag(...)`, marshaled over the swift_ffi transport) and a
  `BridgedView` that renders a real native SwiftUI view the app registered by id
  (things the wasm core can't draw, like SF Symbols).
- **The host apps** (`example_partial_wasm_{ios,android,macos}_application`)
  embed the wasm runtime, connect to the server, and hot-swap the reactor when a
  new build arrives. They keep all their state across a swap.
- **The server**
  (`example_partial_wasm_macos_application:hot_reload_server`) watches the
  feature source, rebuilds just the wasm on change, and pushes it to every
  connected app. iOS/macOS connect over localhost directly; Android connects
  through `adb reverse tcp:8787 tcp:8787`, which is why the same flow works
  unchanged on an emulator or a USB-attached device.

## Troubleshooting

- **Android app installs but never connects.** The APK must be the *signed*
  one (`…_apk.apk`); the `zipaligned_*` intermediate is unsigned and its install
  silently no-ops. The demo script already installs the signed apk — if you
  install by hand, use that target.
- **Emulator/`uiautomator` seems stuck.** The device must be **unlocked**.
- **iOS app launches but stays blank.** Confirm the server is up
  (`curl http://localhost:8787/version`) before the app launches; the demo waits
  on this, but a stale server on the port can interfere — kill it and re-run.
- **`SIM_UDID` not found.** The default is a local simulator id; set `SIM_UDID`
  to one from `xcrun simctl list devices`.
