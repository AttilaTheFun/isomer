# Driving Isomer apps (0.46)

An Isomer app can be driven, by a person at a terminal, an agent, or a test,
by what it shows (its texts, buttons, fields and controls), never by pixels:
headless on a server or in a container, or headful on a phone, a simulator,
an emulator or in a browser, on this machine or another. The same SwiftUI
source still builds natively against Apple's SwiftUI with none of this in it:
driving is something a build opts into, never an API an app calls.

## The protocol and its transports

shared/wire/headless.proto is the driver's protocol (ls, info, tap, type,
set, select, swipe, back, dismiss, wait, quit); shared/wire/session.proto a
head's session (drawing the app). An app serves both as an `IsomerServer`
(drive/serving), apart from any transport; adapters carry it:

| Transport | Module | For |
| --- | --- | --- |
| gRPC Swift 2, HTTP/2 | IsomerGRPCTransport (drive/grpc) | driving remotely: the CLI, tests, servers (macOS 15, iOS 18, Linux) |
| WebSockets | IsomerWebSocketTransport (drive/websocket), IsomerURLSessionConnection | clients without gRPC: browsers, the Android head, iOS before 18 |
| standard input and output, Unix sockets | IsomerProcessTransport (drive/process) | one machine, no TCP |
| a call in the same process | IsomerLocalConnection | a test hosted in the app |

`IsomerRemote` picks one by URL: `grpc://host:port`, `grpcs://…` (TLS),
`ws://host:port`, `unix:/path`, `exec:/path/to/app` (an app built headless,
started for the call).

## Serving an app

An app built headless (`--@isomer//headless`) serves itself:

```sh
ISO_DRIVE_LISTEN="grpc://127.0.0.1:7701 ws://127.0.0.1:7702 unix:/tmp/app.sock" \
ISO_HEADLESS_PROTOCOL=serve ./app
# isomer: listening grpc://127.0.0.1:7701 …
```

- `ISO_DRIVE_LISTEN`: where (port 0 is the system's choice; the bound port is
  printed). A listener on another address than the loopback needs a token:
  `ISO_DRIVE_TOKEN`, or `ISO_DRIVE_TOKEN_FILE` naming a file whose first line
  it is. Calls carry it as `authorization: Bearer <token>` (gRPC metadata, a
  WebSocket's header or its `token` query parameter).
- `ISO_DRIVE_SITE`: a directory the WebSocket listener also serves over HTTP:
  web/remote_client, the web's thin client, which draws the app
  (docs/remote_sessions.md).
- Without `ISO_DRIVE_LISTEN`, the app speaks JSON lines on standard input and
  output (a command a line); `ISO_HEADLESS_PROTOCOL=binary` serves one call
  there (what `exec:` URLs use).

## The iso CLI

`bazel run @isomer//xplat/iso -- …` (`//xplat/iso` in the examples), or the
binary it builds, which `bazel build` leaves at bazel-bin/xplat/iso/iso to run
in place or copy anywhere. It was `isomer` (drive/cli) until 0.49.

The quickest way to see it: the iPhone Storybook in a simulator, driven from
a terminal, in the examples:

```sh
bazel run //apple/storybook_ios_application --config=cli   # builds, installs, launches; listens
bazel run //xplat/iso -- ls                                # in another shell: its screen
bazel run //xplat/iso -- tap ObservableObject              # a story, scrolled to and opened
bazel run //xplat/iso -- tap Tap
bazel run //xplat/iso -- wait "Taps: 1"
```

`--config=cli` is `--@isomer//drive:headful`: an app on Apple's SwiftUI
built so, launched without `ISO_DRIVER`, listens for the CLI at
ws://127.0.0.1:7700 (`ISO_DRIVE_LISTEN` another address, `none` not at all;
`ISO_DRIVE_TOKEN` a token, for an address other than the loopback). A
simulator's apps share the Mac's loopback address, and with no application
selected the CLI drives that address. The Mac Storybook
(`//apple/storybook_macos_application`) listens the same way.

Apps elsewhere are kept by name:

```sh
iso application add storybook exec:/path/to/storybook_headless_application
iso application add staging grpc://build-host:7701 --token-file ~/.staging-token
iso application select storybook
iso application list

iso ls                          # the screen, a line an element: button-1 "Tap", text-3 "Taps: 0"
iso ls text                     # one role: text, button, textField, toggle…
iso info                        # name, platform, renderer, window
iso inspect text-3              # one element in full: kind, actions, font, colour, its parameters
iso tap button-1                # by name (role and place), identifier or label
iso tap Tap
iso type Title "Hits"
iso set Wi-Fi 0
iso select Flavor Chocolate
iso swipe Board left
iso back | dismiss
iso wait "Taps: 1" --timeout 10
iso drive                       # JSON lines on standard input
```

An element's name is its role and its place among that role's on the
screen, from 1 (`button-3`, `textField-1`; `text-2` the second text): any
command takes it as its target, resolved by the app against the screen
as it stands, so a name from one `ls` holds until the screen changes. A
text names the button it is in for `tap`. `--app <name>` drives another than the selected one, `--url <url>` one with
no name, `--json` prints protobuf's JSON; with neither and none selected,
ws://127.0.0.1:7700. An `exec:` application is started
on its first command and kept running on a Unix socket, so its state lasts
between commands, until `iso application stop <name>`. Applications are
kept in `~/.config/isomer/applications.json`, readable only by their user.

## Headful apps

A headful app can't usually be reached (a simulator, an emulator, a phone, a
browser tab), so it dials out instead. Built with `--@isomer//drive:headful`
(off by default, and never in a release: such an app obeys whoever its
launch names) and launched with `ISO_DRIVER=ws://host:port`, it connects to a
hub and is driven over that connection: an Isomer app's screen read through
its runtime as the headless host's is (the web's, Android's, Linux's and
Windows' hosts), an app on Apple's SwiftUI through its accessibility tree
(below). The CLI is a hub:

```sh
iso hub --ws 7710                # a token with --token when not on the loopback
# then launch the app with ISO_DRIVER=ws://<this machine>:7710
#   (the web: ?ISO_DRIVER=…; Android: -e ISO_DRIVER …)
iso --url ws://127.0.0.1:7710 ls
```

With several apps attached, name one: `?target=<name>` (gRPC: the URL's
path), the name being the app's or its `ISO_DRIVER_NAME`. A headless app
dials out too (`ISO_DRIVER`), which is how the tests cover the hub on Linux.

**Apps on Apple's SwiftUI** (the iPhone and Mac Storybooks, and any app on
Apple's frameworks): with the flag, @isomer//apple/libraries/swift_ui links
drive/apple, which a constructor starts (the app calls nothing). It answers
the same commands from the app's accessibility tree, with the same names:
on iOS it walks UIKit's accessibility containers once the app's
accessibility is on, scrolls to what is off screen as a person would, waits
out navigation transitions, and taps what takes no activation (a list's
cell, a control) as a tap would; on the Mac it asks its own process as an
accessibility client would (AXUIElement), on the main thread. A list's row
of texts is a button, as Isomer's renderers give it. Launch with simctl's
`SIMCTL_CHILD_ISO_DRIVER=…`, or a Mac app with `ISO_DRIVER` in its
environment, to dial out; launched without it, the app listens for the CLI
(above).

## Tests

IsomerHeadless (`@isomer//headless/isomer_headless`) is one API over every
target:

```swift
let app = try HeadlessApp(executable: path, environment: ["ISO_STORYBOOK_STORY": "state.observableobject"])
let app = try HeadlessApp(url: "grpc://127.0.0.1:7701", token: token)
let app = try HeadlessApp(connection: IsomerLocalConnection(server))
let app = try HeadlessApp(launcher: launcher, environment: ["ISO_STORYBOOK_STORY": "state.observableobject"])
try app.tap("Tap")
try app.wait(for: "Taps: 1")
```

`HeadlessApp(launcher:environment:)` drives a headful app with the same
test: the test holds a hub of its own (IsomerServing's `IsomerHub`, on a
loopback WebSocket), and the launcher, run as `<launcher> <hub URL> <name>
[KEY=VALUE…]`, starts the app dialling out to it (ISO_DRIVER,
ISO_DRIVER_NAME) and ends it when stopped. A launcher a platform, beside the
Storybook's tests (examples' headless/storybook_headless_application): the
web's (headless Chrome under browser_check `--hold`), the iPhone's (simctl
on a booted simulator), the Mac's, Android's (`am start` with the extras,
the hub's port reversed with `adb reverse`) and Linux's (under Xvfb).
:storybook_headful_{web,linux}_test run in CI's container;
:storybook_headful_{ios,macos,android}_test on GitHub's macOS and Ubuntu VMs
in a run by hand (tools/ci/hosted_headful_test.sh, the apps the container's
with their drivers in, the test built there).

The examples' //headless tests drive the Storybook built headless, and
:storybook_headful_web_test runs the same source against the web Storybook
headful (ISOMER_HEADFUL_LAUNCHER names the launcher; CI's container runs
both on every pull request). The //remote tests drive it over each
transport, with tokens, a head's session, the hub and the CLI;
//remote:headful_web_test the web Storybook in Chrome through the CLI's hub.
