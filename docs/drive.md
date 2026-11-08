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

## The isomer CLI

`bazel run @isomer//drive/cli:isomer -- …`, or the binary it builds:

```sh
isomer application add storybook exec:/path/to/storybook_headless_application
isomer application add staging grpc://build-host:7701 --token-file ~/.staging-token
isomer application select storybook
isomer application list

isomer ls                          # the screen
isomer info                        # name, platform, renderer, window
isomer tap Tap
isomer type Title "Hits"
isomer set Wi-Fi 0
isomer select Flavor Chocolate
isomer swipe Board left
isomer back | dismiss
isomer wait "Taps: 1" --timeout 10
isomer drive                       # JSON lines on standard input
```

`--app <name>` drives another than the selected one, `--url <url>` one with
no name, `--json` prints protobuf's JSON. An `exec:` application is started
on its first command and kept running on a Unix socket, so its state lasts
between commands, until `isomer application stop <name>`. Applications are
kept in `~/.config/isomer/applications.json`, readable only by their user.

## Headful apps

A headful app can't usually be reached (a simulator, an emulator, a phone, a
browser tab), so it dials out instead. Built with `--@isomer//drive:headful`
(off by default, and never in a release: such an app obeys whoever its
launch names) and launched with `ISO_DRIVER=ws://host:port`, it connects to a
hub and is driven over that connection, its screen read through its runtime
as the headless host's is (the web's and Android's hosts; the iPhone and the
Mac next, docs/drive_plan.md). The CLI is a hub:

```sh
isomer hub --ws 7710                # a token with --token when not on the loopback
# then launch the app with ISO_DRIVER=ws://<this machine>:7710
#   (the web: ?ISO_DRIVER=…; Android: -e ISO_DRIVER …)
isomer --url ws://127.0.0.1:7710 ls
```

With several apps attached, name one: `?target=<name>` (gRPC: the URL's
path), the name being the app's or its `ISO_DRIVER_NAME`. A headless app
dials out too (`ISO_DRIVER`), which is how the tests cover the hub on Linux.

## Tests

IsomerHeadless (`@isomer//headless/isomer_headless`) is one API over every
target:

```swift
let app = try HeadlessApp(executable: path, environment: ["ISO_STORYBOOK_STORY": "state.observableobject"])
let app = try HeadlessApp(url: "grpc://127.0.0.1:7701", token: token)
let app = try HeadlessApp(connection: IsomerLocalConnection(server))
try app.tap("Tap")
try app.wait(for: "Taps: 1")
```

The examples' //remote tests drive the Storybook over each transport, with
tokens, a head's session, the hub and the CLI; //remote:headful_web_test the
web Storybook in Chrome through the hub.
