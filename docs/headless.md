# Headless Isomer (0.43; protobuf and remote sessions since 0.45)

An Isomer app runs headless: its SwiftUI on the building machine (a Mac, or
Linux in a container) with nothing drawn, its UI read and used through the
runtime. Tests drive it in seconds, with no simulator, emulator or browser.
Built so, it can also be served to clients that hold only a renderer
(docs/remote_sessions.md): the same binary, another protocol.

An app repository's guide to running its UI tests this way on Linux, with
Swift Testing: docs/testing_on_linux.md.

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
- binary, one call (a `CallHeader`, then the call's messages, each
  length-delimited), with `ISO_HEADLESS_PROTOCOL=binary`: what IsomerHeadless
  and the CLI's `exec:` URLs start an app with.

The app also serves itself on gRPC, WebSockets and Unix sockets
(`ISO_DRIVE_LISTEN`), to drivers and to heads that draw it: docs/drive.md,
docs/remote_sessions.md. The commands since 0.46 also include `info`,
`select <element> <option>` and `swipe [<element>] <direction>`.

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
binary, listening on a Unix socket of its own, and speaks the protocol
(binary):

```swift
let app = try HeadlessApp(executable: path, environment: ["ISO_STORYBOOK_STORY": "state.observableobject"])
try app.tap("Tap")
try app.wait(for: "Taps: 1")
```

## The headless head and its layout (0.49)

With no remote head drawing it, an app built headless renders through the
headless head (headless/libraries/swift_ui/HeadlessHead.swift): it renders
without rendering. Each frame is laid out as the self-drawing renderer lays
it out (its drawn chrome, measured and placed: `Runtime.layoutTree`, the
layout the GPU renderer draws from), and nothing is drawn; `GeometryReader`
gets its real size. Text is measured by the headless host's fixed estimate
(0.55 of the font's size a character), the same on every machine.

Tests read the layout through the app's IsomerLayoutServer
(shared/wire/layout.proto: `LayoutServer.Frames`, beside the driver's calls on
the same transports): every text, button, field, image, scroll and host
view, with its label, identifier and frame in the window's points, the
presented layers (sheets, alerts) after the window's. The driver's protocol
and the CLI stay frameless: they drive by names and labels.

```swift
let layout = try app.layout()
let tap = try #require(layout.frame(of: "Tap", kind: "button"))
#expect(tap.maxX <= layout.width)
```

A headful app has no layout server (its layout is its platform's).

The Storybook's are examples/headless/storybook_headless_application
(`bazel test --@isomer//headless //headless/...`). CI runs them in every
build, pull requests' and main's alike (tools/ci/container_build.sh): they
take seconds.

A test can drive the app on another machine too, or a headful app that
dialled out to it: `HeadlessApp(url:token:)` over any of docs/drive.md's
transports.

## What's next

Fixtures at the network's edge (a transport that fails unexpected
requests), scrolling, the debug socket for apps with their UI, the headful
run in `verify`, and the repositories on Isomer adopting it.
