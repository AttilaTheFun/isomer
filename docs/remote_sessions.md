# Remote sessions (0.45; the app serves itself since 0.46)

An app's SwiftUI can run on a server, built headless, and be drawn on a
client that holds nothing of the app but a renderer: a browser with the
React renderer, an Android phone with the Compose renderer. The client
sends what the person does; the app answers with each frame as a patch of
its render tree. A low-end phone needs only the renderer and a WebSocket:
no Swift, no wasm, no native library.

```
 head (renderer only)                    server
 ┌───────────────────────┐   WebSocket   ┌──────────────────────────────┐
 │ React / Compose       │ ────────────▶ │ the app, headless, serving    │
 │ tree reader (patches) │ ◀──────────── │ itself (ISO_DRIVE_LISTEN)     │
 └───────────────────────┘   or gRPC     └──────────────────────────────┘
```

## One wire format

Every path from Isomer's SwiftUI to a renderer speaks protobuf
(shared/wire), whether the renderer is in the same process, in another on
the same machine, or across a network, and whether the stream is live or
recorded:

| File | What |
| --- | --- |
| `tree.proto` | the render tree and its patches, what a component-system renderer takes (in process since 0.45, FlatBuffers before) |
| `session.proto` | a head's session: `ClientMessage` (start, resize, events, keys, text, appearance, scene phase, URLs, back) and `ServerMessage` (a patch, a platform command, an image, a URL, the app's appearance, text input, a log line); `CallHeader`, a call's opening where a transport has no headers |
| `headless.proto` | the driver: `Command` and `Answer` (docs/drive.md) |
| `session_service.proto` | as gRPC services: `Session.Connect`, `Headless.Drive`, `Driver.Attach`, bidirectional streams |

In a stream of bytes (a pipe, a file) each message is length-delimited, as
protobuf's `writeDelimitedTo` writes them, so a session can be recorded and
replayed. Over a WebSocket each binary message is one message, and an empty
one ends its sender's messages. The Swift is generated as it builds
(`IsomerSwiftUI`'s tree messages and `IsomerWire`'s: swift-protobuf's build
plugin in a SwiftPM build, swift_proto_library under Bazel); drive/grpc serves
and calls session_service.proto's methods by name, its messages as bytes, so
nothing is generated for it; the JavaScript and Kotlin readers and writers are written by
hand against protobuf's wire format, so the web and Android need no protobuf
library (flat_tree.js and session_messages.js, FlatTree.kt and
RemoteIsomer.kt).

## The server

An app built headless (`--@isomer//headless`) serves itself on whatever
`ISO_DRIVE_LISTEN` names (docs/drive.md): gRPC, WebSockets, a Unix socket.
A head's `Session.Connect` starts with `start` (its size, scale, appearance
and renderer); the app binds that renderer (React's or Compose's tree),
resizes to the head, and sends a frame whenever the app asks for one, the
first the whole tree (headless/libraries/swift_ui/RemoteSession.swift). One
head at a time; a driver keeps working while it draws, on the same screen.

```sh
cd examples
bazel build --@isomer//headless //headless/storybook_headless_application @isomer//web/remote_client
ISO_DRIVE_LISTEN=ws://127.0.0.1:8090 ISO_HEADLESS_PROTOCOL=serve \
ISO_DRIVE_SITE=bazel-bin/external/isomer+/web/remote_client/remote_client \
ISO_STORYBOOK_STORY=state.observableobject \
    bazel-bin/headless/storybook_headless_application/storybook_headless_application
# then http://127.0.0.1:8090/
```

## The heads

- **The web**: `connectIsomer({ url, container })`
  (wasm/libraries/swift_ui/runtime/remote.js): the React renderer,
  flat_tree.js and a WebSocket. web/remote_client is a page of it, served by
  the app beside its session (`ISO_DRIVE_SITE`), or `?session=ws://…`.
- **Android**: `IsomerRemote(url)` (dev.isomer.runtime, with the
  interpreter: android/libraries/swift_ui/kotlin/…/RemoteIsomer.kt): the
  Compose renderer, FlatTree and IsomerWebSockets. examples/android/
  remote_android_application is an app of it: Kotlin and Compose only.
- **Swift**: `IsomerConnection.connect()` over any transport (drive/serving),
  for a head of its own.

## What a remote app can't know

- **Text is measured on the server**, as the headless host measures it (a
  fixed-width estimate): the head's renderer lays the tree out with its own
  fonts, as it does in process, but what the app computes from a
  measurement (a `GeometryReader` around text) is approximate.
- **A key's answer comes too late** to keep it from a field: `.onKeyPress`
  sees every key, and the head lets every key through.
- **Back**: the head sends the system's back to the app, which can't answer
  in time for the system to act on it; an app at its root stays.
- **Images** the app makes reach the head as `image` messages; images by URL
  are the head's to load.
- **The launch environment is the app's**: a head can't change what the app
  was started with (`ISO_STORYBOOK_STORY`); a server starts one app per
  environment it wants.
- **One session a process on Android** (the interpreter's one tree, as a
  WasmView's).

## Tests

In the examples, with the app's flag (`bazel test --@isomer//headless
//remote/...`), in every CI build beside the headless tests:

- `//remote:remote_test`: the app driven over gRPC, a WebSocket and a Unix
  socket, with tokens; a head's session over gRPC; dial-out to the CLI's hub;
- `//remote:web_test`: the web's thin client in headless Chrome over the
  app's WebSocket, drawing the session and clicking in it (Chrome for Testing
  on Linux, the Mac's Chrome on a Mac);
- `//remote:cli_test`: the `isomer` CLI.

Android's head was checked by hand on an emulator (drawn, tapped, typed
into); an automated run is open (TODO.md).
