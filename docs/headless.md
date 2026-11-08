# Headless Isomer (prototype, 0.43)

An Isomer app runs headless: its SwiftUI on the building machine (a Mac, or
Linux in a container) with nothing drawn, its UI read and used through the
runtime. Tests drive it in seconds, with no simulator, emulator or browser.
The same reads and writes are meant to drive the app with its UI too (a
debug-only socket on Android, the web and the desktops: the next version).

## Building an app headless

`--@isomer//headless` points `@isomer//:swift_ui` and `@isomer//:isomer` at
the headless platform module (headless/libraries/swift_ui), whose
`App.main()` runs the headless host. The examples' Storybook:

```sh
cd examples
bazel run --@isomer//headless //headless/storybook_headless_application
{"cmd": "ls"}
```

## The protocol

A command a line on standard input, an answer a line on standard output
(headless/libraries/swift_ui/HeadlessHost.swift):

| Command | Does |
| --- | --- |
| `{"cmd": "ls"}` | nothing: the screen as it is |
| `{"cmd": "tap", "target": T}` | taps a button, found by its `accessibilityIdentifier`, its label, or the text in it |
| `{"cmd": "type", "target": T, "text": S}` | sets a text field's text |
| `{"cmd": "set", "target": T, "value": V}` | sets a control: a toggle's `"1"`/`"0"`, a picker's index |
| `{"cmd": "back"}` / `{"cmd": "dismiss"}` | the system's back / the topmost presentation dismissed |
| `{"cmd": "wait", "text": S, "timeout": 5}` | until the text shows |
| `{"cmd": "quit"}` | ends the app |

Each answer is `{"ok": …, "error": …, "screen": {"texts": […],
"elements": [{"role", "label", "id", "value"}], "presented": [{"style",
"title", "message"}]}}`, taken once the UI has settled after the command
(three frames alike): what a person sees and can do, never pixels. The
app's tasks run between commands; the window is 390 by 844 unless
`ISO_HEADLESS_WIDTH`/`ISO_HEADLESS_HEIGHT` say otherwise (a lazy list
builds the rows that fit).

## Tests

IsomerHeadless (`@isomer//headless/isomer_headless`) launches the app's
binary and speaks the protocol:

```swift
let app = try HeadlessApp(executable: path, environment: ["ISO_STORYBOOK_STORY": "state.observableobject"])
try app.tap("Tap")
try app.wait(for: "Taps: 1")
```

The Storybook's are examples/headless/storybook_headless_application
(`bazel test --@isomer//headless //headless/...`). CI runs them in every
build, pull requests' and main's alike (tools/ci/container_build.sh): they
take seconds.

## What's next (0.44)

Fixtures at the network's edge (a transport that fails unexpected
requests), scrolling, the debug socket for apps with their UI, the headful
run in `verify`, and the repositories on Isomer adopting it.
