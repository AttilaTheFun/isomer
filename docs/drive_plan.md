# Driving Isomer apps (the plan; docs/drive.md what 0.46 has)

The owner's design (2026-11-08), and how it lands. One driver protocol,
shared/wire/headless.proto (ls, info, tap, type, set, swipe, select, back,
dismiss, wait, quit), whatever the app is and wherever it runs.

## Transports

- **gRPC Swift 2 over HTTP/2 is the primary client and server.** The
  services are shared/wire/session_service.proto's: `Headless.Drive` and
  `Session.Connect`, and a third, `Driver.Attach`, for apps that dial out.
- **WebSockets are an alternative transport** adapted to the same messages,
  for browsers (no bidirectional gRPC there) and the dependency-free Android
  head.
- **The headless application is the server.** An app built headless runs the
  gRPC server and the WebSocket adapter in its own process (`--listen`), as
  well as speaking the protocol on standard input and output. The examples'
  gateway, which spawned an app per connection, goes.
- **Headful apps dial out** (`ISO_DRIVER=<url>`): to the test host, or to the
  headless application whose head they are. Dialling out works from a
  simulator, an emulator (10.0.2.2), a device and a browser tab, none of which
  a container can reach by listening.

## The CLI

`isomer`, a Swift binary with gRPC Swift 2's HTTP/2 client:

```
isomer application add <name> <url> [--token <token> | --token-file <path>]
isomer application remove <name>
isomer application select <name>
isomer application list
isomer ls | info | tap <element> | type <element> <text> | set <element> <value>
       | swipe <element> <direction> | select <element> <option> | back | dismiss
       | wait <text> [--timeout s]
```

Applications are kept in `~/.config/isomer/applications.json` (mode 600). A
URL is `grpc://host:port`, `grpcs://…` (TLS), `ws://`/`wss://`, or
`exec:<path to a headless binary>` (started per command group). Remote
instances authenticate with a bearer token: the app (`--token-file`,
`ISO_DRIVE_TOKEN`) refuses calls without it, gRPC metadata `authorization` or
the WebSocket's `Authorization` header; a listener on a non-loopback address
requires one.

## Tests

One Swift test source, `IsomerHeadless`'s `HeadlessApp` API, run four ways by
where its target is:

- headless on Linux or macOS: the app binary started, or a URL;
- headful from Linux: the app on a leased simulator or emulator, launched
  with `ISO_DRIVER` pointing at the test process, which listens;
- headful natively on a Mac: the same, on a local simulator;
- headful in an XCTest bundle hosted in the app: the driver in process, no
  network, so a UI test runs as fast as a unit test.

Unit tests that touch code importing Apple's frameworks build against
Isomer's on Linux (headless, `--@isomer//headless`) and against Apple's in an
XCTest bundle on a simulator or device: one `isomer_test` macro.

## What iOS and the Mac can be driven by

The shipping Apple apps render with Apple's SwiftUI: no Isomer tree in
process. First the Isomer-compiled build (apple/compiled: the same source on
Isomer's SwiftUI, the tree view drawing it) is the headful iOS target; then
an in-process accessibility driver, for Apple's own rendering.

## The package

gRPC Swift 2 marks its API available from macOS 15 and iOS 18 rather than
raising a package minimum, so isomer's package keeps macOS 13 and iOS 16:
IsomerGRPCTransport's API carries the same marks, and everything else
(IsomerServing, the WebSocket client over URLSession, the driver) builds
wherever Isomer does. Below iOS 18 a client takes the WebSocket.

## Order

0.46 has steps 1 and 2 (headful dial-out from the web's and Android's hosts),
and the transports as the owner refined them: an `IsomerServer` free of gRPC
(iOS 16), server and client adapters for gRPC, WebSockets and processes.

1. The package: IsomerWire and the gRPC services in it; the headless app's
   server (gRPC and WebSocket, tokens); the `isomer` CLI with its registry;
   IsomerHeadless over any URL. The gateway goes.
2. The driver shared by every host (the headless host's screen reading, moved
   out), `Driver.Attach`, and dial-out from the Android and web hosts and the
   remote session's head.
3. Headful iOS through the Isomer-compiled build; the hosted-XCTest
   transport; leased-simulator runs from Linux.
4. `isomer_test`; the gateway-less low-end mode on Linux in CI; an iOS head.
5. The accessibility driver for Apple's SwiftUI.
