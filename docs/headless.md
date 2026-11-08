# Headless Isomer (0.43; protobuf and remote sessions since 0.45)

An Isomer app runs headless: its SwiftUI on the building machine (a Mac, or
Linux in a container) with nothing drawn, its UI read and used through the
runtime. Tests drive it in seconds, with no simulator, emulator or browser.
Built so, it can also be served to clients that hold only a renderer
(docs/remote_sessions.md): the same binary, another protocol.

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

shared/wire/headless.proto's `Command` and `Answer`, in one of two
encodings (headless/libraries/swift_ui/HeadlessHost.swift):

- protobuf's JSON mapping, a command a line on standard input and an answer
  a line on standard output: the default, for a terminal or an agent;
- binary, each message length-delimited (a varint length, then the
  message), with `ISO_HEADLESS_PROTOCOL=binary`: IsomerHeadless's.

`ISO_HEADLESS_PROTOCOL=session` serves the app to a remote client instead
(shared/wire/session.proto, docs/remote_sessions.md).

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
"title", "message"}]}}` (protobuf's JSON leaves out a field at its default:
an empty list, a presentation's empty message), taken once the UI has settled after the command
(three frames alike): what a person sees and can do, never pixels. The
app's tasks run between commands; the window is 390 by 844 unless
`ISO_HEADLESS_WIDTH`/`ISO_HEADLESS_HEIGHT` say otherwise (a lazy list
builds the rows that fit).

## Tests

IsomerHeadless (`@isomer//headless/isomer_headless`) launches the app's
binary and speaks the protocol (binary):

```swift
let app = try HeadlessApp(executable: path, environment: ["ISO_STORYBOOK_STORY": "state.observableobject"])
try app.tap("Tap")
try app.wait(for: "Taps: 1")
```

The Storybook's are examples/headless/storybook_headless_application
(`bazel test --@isomer//headless //headless/...`). CI runs them in every
build, pull requests' and main's alike (tools/ci/container_build.sh): they
take seconds.

A test can drive the app on another machine too: a gateway's
`Headless.Drive` (gRPC, session_service.proto) or `/headless` WebSocket
runs it there (docs/remote_sessions.md).

## What's next

Fixtures at the network's edge (a transport that fails unexpected
requests), scrolling, the debug socket for apps with their UI, the headful
run in `verify`, and the repositories on Isomer adopting it.
