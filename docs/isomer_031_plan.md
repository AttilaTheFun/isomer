# Isomer 0.31: Apple's frameworks, in Swift, everywhere

The plan agreed on 2026-10-12, and how it landed. (Its "WAMR hosts" are
WasmKit's since 0.38, when WAMR was removed: the checks run under
//tools/wasm/wasi_run, the native hosts on `WasmKitRuntime`.)
Work goes on `release-0.31` in isomer and in every repository that takes it
(visor_isomer, the Playground; other applications on their own). The
native Visor app is not cut for 0.31 yet.

## The idea

An application that imports only Swift, SwiftUI, Metal, Foundation,
Observation and Synchronization builds unchanged for every platform. On
Apple those imports are Apple's frameworks. Everywhere else they are
Isomer's: modules with Apple's names and Apple's public interfaces, backed
by a renderer or GPU backend chosen per platform. What Apple does not
provide (the FFI, SQLite, gRPC transports, proto-to-SQL code generation,
Postgres) is Isomer's own, behind `import Isomer`.

The long-term vision is larger than this release. 0.31 is its first cut.

## Rules

- **Swift only.** Isomer implements the part of each Apple interface that
  can be written in Swift. Nothing that needs the Objective-C runtime:
  no `NSObject` bases, `NSObjectProtocol` refinements, key-value observing,
  `@objc` optional requirements. Where Apple's API is Objective-C at heart
  (`MTKView`, `CAMetalLayer`), Isomer provides its own Swift API instead
  and says so.
- **Apple's interface, exactly.** A declaration Isomer has matches Apple's
  generated `.swiftinterface` (or, for frameworks written in C or
  Objective-C, the interface Swift synthesizes for them). The public
  modules carry nothing of Isomer's own; Isomer's plumbing is `@_spi`.
- **Gaps are public.** `docs/parity/<Module>.md` lists, for each module,
  what is implemented, what is not, why, and whether it is planned, maybe,
  or not planned. API that is planned and whose types all exist is
  declared `@available(*, unavailable, message: "Not yet in Isomer…")`, so
  the compiler names the gap; API that is excluded (Objective-C, a
  framework Isomer does not provide) is absent and listed.

## The modules (non-Apple platforms)

```
CoreGraphics    Isomer's own, limited: geometry, CGAffineTransform, CGColor,
                CGColorSpace, CGPath, line caps and joins, CGBlendMode
Foundation      built from Isomer's fork of swift-foundation
                (AttilaTheFun/swift-foundation, branch `isomer`, from
                swift-6.3.2-RELEASE): FoundationEssentials by default,
                FoundationInternationalization + ICU by a build setting
                with locale-trimmed data; no corelibs NS classes,
                CoreFoundation, FoundationNetworking or FoundationXML;
                re-exports CoreGraphics' geometry as Apple's does
Observation, Synchronization   the toolchain's
IsomerFFI       swift_ffi (the module was SwiftFFI)
Metal           Isomer's own: classic Metal (not Metal 4, ML tensors, ray
                tracing, IO queues, residency sets) over IsomerMetal
IsomerMetal     the backend protocol, the WebGPU backend, the shader
                translator (a subset of Metal's shading language to WGSL,
                written in Swift)
SwiftUI         Isomer's SwiftUI, Apple's public interface only
Isomer          the umbrella: IsomerFFI, IsomerMetal, Isomer's own SwiftUI
                additions (MetalView, platform modifiers, representables,
                WebView, VideoPlayer…), platform services
```

Layering: CoreGraphics < Foundation < IsomerFFI < IsomerMetal / Metal <
SwiftUI < Isomer. Metal names no CoreGraphics type; Isomer's MetalView does.

## Phases and status

| # | Phase | Status |
|---|---|---|
| 1 | Branches, this plan | done |
| 2 | Parity tooling and reports (SwiftUI, Metal, CoreGraphics, Foundation, Observation, Synchronization) | done (Metal's comes with phase 6) |
| 3 | CoreGraphics module | done |
| 4 | Foundation from the fork, on wasm and Android; skim Foundation retired | done (FoundationInternationalization over the Swift SDKs' ICU behind `--@isomer//foundation:internationalization`; `isomer_web_app(icu_locales = …)` trims ICU's data) |
| 5 | Layout and names: IsomerFFI, Isomer umbrella, SPI plumbing, `uui` → `iso` | done (stand-ins for other frameworks still in SwiftUI) |
| 6 | Metal: API, WebGPU backend, shader translator, MetalView | done |
| 7 | The GPU renderer and SwiftMap on Metal (web; Apple through the same source) | done |
| 8 | visor_isomer and the Playground on release-0.31; other applications told | done |
| 9 | AGENTS.md, README, this file's "how it landed" | done |
| 10 | The Apple-named modules expose Apple's API only, SPI included; Isomer's own API in Isomer* modules beneath them | done |
| 11 | Foundation's services: `URLSession` (HTTP, WebSockets), persistent `FileManager` directories, `@AppStorage` over `UserDefaults`; the injected file and network services retired | done for the web, Android and Apple's WasmView (transports, directories, `@AppStorage`, the services retired); the Linux/Windows WAMR hosts and Android's WasmView give a guest no home or transport yet |
| 12 | Consumers on Foundation's services: Visor Isomer's socket/HTTP/settings/cache bridges, other applications' file stores and host HTTP | Visor Isomer done (visor_isomer db8894b); the others are their own |
| 13 | Reports, docs, AGENTS.md; 0.31 (3) pre-release builds | done (pre-releases up to 0.31 (5); what is open is docs/open_items.md, what each module lacks docs/parity/missing/) |

Later (not 0.31): Metal backends for Android, Windows and Linux (WebGPU
through wgpu-native or Dawn by default); wasm → native Metal on Apple and
Metal hot reload; SwiftUI's shader effects; Metal 4; a MapKit subset for
`Map`; `URLSession` and `FileManager` over the web's own APIs; a separate
`IsomerServer`; SwiftPM.

## How it landed (2026-10-12)

All on `release-0.31` (isomer, the swift-foundation fork's `isomer` branch,
visor_isomer, the Playground); nothing tagged, released, published or
installed. The numbers are docs/parity's.

- **Foundation** (phase 4, then for the apps): FoundationEssentials from the
  fork for wasm and Android, plus, written in Swift, what corelibs has that
  the apps reached for (String formatting and searching, Bundle, streams,
  NSRange, NSRegularExpression over Swift's Regex, the locks, Thread,
  FileHandle, NSNumber). FoundationInternationalization is the fork's, over
  the Swift SDKs' prebuilt ICU, behind `--@isomer//foundation:internationalization`;
  `isomer_web_app(icu_locales = …)` keeps only the languages named (ICU's
  34 MB of data become 6-7 MB). 3,841 of 12,065 of Apple's Foundation
  declarations (32%), every gap sorted. Checks: //foundation/tests (WAMR,
  with ICU whole and trimmed; the ICU check also on the Android emulator),
  tools/foundation/check_link.py over the apps. Visor's web client on it
  is 47.9 MB (14.9 MB gzipped) against 0.30's 51.1 MB (15.7 MB), with
  every locale kept.
- **CoreGraphics**: 427 of 1,357 (31%).
- **Layout and names** (phase 5): the Isomer module per platform (the
  Playground SDK's too), IsomerFFI, `@_spi(Isomer)` plumbing, `uui` → `iso`.
  Isomer's own app-facing API left the SwiftUI module for the Isomer
  module, where the Apple build already had it: Map and its overlays,
  PlatformViewRepresentable (SwiftUI keeps it as `_PlatformViewRepresentable`)
  and its per-platform refinements, BridgedView, `Color.dynamic`,
  `swipeGesture`. The host interfaces and their structs,
  Font's and Path's internals and the like went behind `@_spi(Isomer)`
  (swift_ffi's `@ExportedInterface` carries a protocol's SPI to its peers).
  Then the rule (2026-10-12): SwiftUI's interface is a strict subset of
  Apple's, and the implementation may depend on any Isomer* library. Its
  own public declarations went from 423 to none: Apple's shapes (static
  members for enum cases, full signatures with Apple's defaulted
  parameters, the style protocols with a type per style, the gestures'
  `onChanged`/`onEnded` on `Gesture`, `onDelete` on `DynamicViewContent`,
  `Path.Element` as Apple's, Apple's result-builder methods only, no
  public `body` on primitives, TabContent's `TabValue`), `VideoPlayer(url:)`
  and `cameraCapture` to the Isomer module, and the other frameworks'
  types to //frameworks (CoreTransferable, UniformTypeIdentifiers and
  PhotosUI by Apple's names). 1,746 of Apple's SwiftUI declarations were
  there then (1,391 before), and the three new modules have reports of
  their own. Isomer's Foundation gained `UserDefaults` (kept in the host's
  store) for `@AppStorage`'s `store:`.
- **No Combine, UIKit or Dispatch** (2026-10-12: they "exist
  primarily for backwards compatibility and the future is Swift, SwiftUI
  and SwiftConcurrency"). IsomerCombine (`ObservableObject`, `@Published`,
  `@StateObject`, `@ObservedObject`, `@EnvironmentObject`), IsomerUIKit
  (`UIColor`, `UIPasteboard`, `UIKeyboardType`) and IsomerDispatch
  (`DispatchQueue.main` on the frame loop) are gone, with the runtime's
  object observers and timers. Apps use `@Observable` models in `@State`,
  `.environment(_:)` and `@Environment(Model.self)`/`@Bindable`, `Task`
  and `Task.sleep(for:)`, and the Isomer module's `Clipboard.string`; the
  examples and todos are ported (their Apple targets now need iOS 17 and
  macOS 14, Observation's). The parity reasons file the Combine members as
  not planned. On Android a library's `DispatchQueue.main.async` still runs:
  the host's Looper watches libdispatch's main-queue eventfd and drains it.
- **Conformances and swift-foundation's own count too.** parity.py compares
  each type's conformances with Apple's (stated or implied; marker
  protocols aside) and fails `--check` on one Apple's type lacks: 22 went
  (Metal's seven C structs' Equatable/Hashable, `View` on the four toolbar
  items, which the runtime now builds through an internal view,
  `Hashable` on `KeyPress.Phases`, `EventModifiers` and `IndexSet.Index`,
  `Equatable` on `HierarchicalShapeStyle`). swift-foundation's eight own
  public declarations (Decimal's corelibs SPI, `FileAttributeType.init(_:)`,
  `FileProtectionType.inactive`, `FileManager.withFileSystemRepresentation
  (for:_:)`, `OperatingSystemVersion`'s Codable) are internal in the fork
  (b04a549) and fail the check if they return.
- **Gaps the compiler names**: 224 of SwiftUI's planned-but-missing
  members (on types Isomer has, with every type they name there, and no
  overload of the name in Isomer to collide with) are declared
  `@available(*, unavailable, message: "Not yet in Isomer: <group>")`,
  generated by tools/parity/stubs.py into shared/swift_ui_core/NotYet.swift
  (re-run it after parity.py when SwiftUI grows). Metal's planned gaps name
  types its module doesn't have (`Bundle`, `URL`), so by the rule they stay
  absent; Foundation's and CoreGraphics' are not stubbed yet.
- **Metal** (phase 6): the classic API, 855 of 3,580 of Apple's Metal
  declarations (24%); the rest is Metal 4, ray tracing, ML, IO, residency,
  tessellation, Apple-GPU features and the like, each group with its
  reason. The MSL→WGSL translator compiles to WGSL Chrome's WebGPU accepts
  for SwiftGPU's shaders and a set of language checks; 13 end-to-end checks
  pass in headless Chrome (compute and render readback, textures, a canvas
  frame). `MetalView` on Apple (MTKView) and the web (both renderers); the
  triangle example draws the same frame from one source on iOS and in
  Chrome.
- **The GPU renderer and SwiftMap on Metal** (phase 7): SwiftGPU's Metal
  device is one source for Apple's Metal and Isomer's; on the web it
  replaced the hand-written WebGPU device, and the GPU renderer's frame is
  pixel-identical to the old one (0 of 1,073,600 pixels differ). SwiftMap's
  web example draws its tiles, polygon, polyline and markers through it.
- **The apps** (phase 8): visor_isomer release-0.31 (visor's
  `isomer-foundation` branch, 319a96a, gives visor's libraries isomer's
  Foundation through `--@visor//:foundation`; SwiftTerm gets it through a
  patch to visor's configure_package) builds its web, Android and iOS
  clients; its web e2e passes on all three roads, its snapshots are
  unchanged on Mobile Safari, iOS and Android. The Playground
  release-0.31 builds web, Android and iOS and its e2e passes (Android on
  the emulator: the 2048 project compiled on the device for the web run
  and for the wasm run; iOS: the embedded compiler's web run in the app's
  Safari view). What it took in isomer: the Playground SDK's Isomer
  module; SDK bundles that keep a Clang module's own module map
  (_FoundationCShims') and list their hosts' entries, so user builds link
  with `--gc-sections` (18.8 MB, where exporting everything made 28.4 MB,
  too big to compile on the emulator); wasi's emulated getpid in user
  links. Other applications have been told what to change, on
  release-0.31 branches of their own.
- **Foundation's networking** (phase 11, its first part): `URLRequest`,
  `URLResponse`, `HTTPURLResponse`, `URLError` (with
  `Error.localizedDescription`) and `URLSession` (configuration; data,
  upload, download and WebSocket tasks; completion-handler and async
  forms, `download(for:)` among them without the `delegate:` Apple
  defaults to nil) in Isomer's Foundation, Apple's shapes, no delegates.
  file: and data: URLs load without a host; http(s) and ws(s) go through
  IsomerFoundation (//foundation/isomer_foundation), the first Isomer*
  module beneath an Apple-named one: `IsomerNetwork.http` and
  `.webSocket` take a host's `HTTPTransport` and `WebSocketTransport`, and
  `IsomerUserDefaults.store` replaced UserDefaults' SPI hook. Foundation
  imports it `internal`ly, so `import Foundation` shows none of it.
  Foundation 4,418 → 4,717 of Apple's 12,065 declarations; the 379
  networking declarations left are sorted (delegates and metrics, streamed
  bodies, resume data, caches/cookies/credentials/URLProtocol, background
  and stream tasks with proxies and TLS, the Combine publisher). Checked
  over fake transports under WAMR (//foundation/tests). The hosts'
  transports (fetch and WebSocket on the web, Android's, URLSession in the
  WAMR hosts) are next.
- **Apple's API only** (phase 10): `parity.py --check` passes for every
  Apple-named module. The check counts `@_spi` declarations and public
  underscored names Apple's interfaces lack, tells instance from static
  members, and resolves what only looked like additions (members Apple
  reaches through inheritance, conformances, typealiases and defaulted
  parameters). SwiftUI's 516 SPI declarations became `package` (every
  isomer target is built with `package_name = "isomer"`) or moved to
  IsomerSwiftUI, now public: `HostBridge` with `HostColor` and
  `ImageStatus`, `RuntimeConnection` at `IsomerRuntime.connection` (start,
  `bindTreeRenderer`, the events), the IsoFlat tree types. Its 30 public
  underscored names went too: `Scene` and `Gesture` have Apple's `body`
  (primitive ones are `Never`-bodied, found through internal protocols);
  `ShapeStyle`, `Shape` and the style protocols require only what Apple's
  do; `ObservedObject.Wrapper`, AppStorage's per-type initializers,
  `TabContentBuilder<TabValue>` with Apple's opaque signatures;
  `PlatformViewRepresentable` is the Isomer module's own. CoreGraphics lost
  what Apple's Swift marks unavailable; Metal's `MTLLibraryError` took
  Apple's shape; NSNumber lost three extras. HotBridge and the GPU reactor
  glue are libraries reactors link. The Isomer umbrella re-exports
  IsomerFFI, IsomerSwiftUI, IsomerFoundation, IsomerNetworkHost and
  IsomerMetal.
- **Settings and files** (phase 11): `@AppStorage` keeps its values in
  `UserDefaults`, which keeps each suite in a file in the app's
  Library/Preferences; the Isomer module's `HostFileStore` and
  `defaultFileStore` are gone, `FileManager` in the app's directories in
  their place.
- **Fixed on the way**: a drawn navigation's large title was put in again
  every frame when its scroll was a reused subtree's (the web GPU
  renderer's sidebar showed one "Isomer" per frame drawn; a mock-renderer
  check now); a `Map` under the React renderer drew nothing (its layer
  hugged its content and left the map's element 0×0: map and Metal views
  take the space they are offered, as SwiftUI's do); the map's attribution
  was unreadable in dark mode; swift_map's web example served from the
  wrong directory.

## Phases 10-13 (added 2026-10-12)

2026-10-12: "SwiftUI, CoreGraphics, Foundation and Metal should not
have any public-facing Isomer-specific APIs but they can depend on
IsomerCoreGraphics, IsomerFoundation, IsomerMetal, IsomerSwiftUI and
IsomerFFI (all re-exported throught the Isomer umbrella module, though
that's intended for external consumption). So all the apis for e.g.
binding a renderer are in Isomer modules and our implementation of
SwiftUI would depend on IsomerSwiftUI to read it. Similarly IsomerFFI has
the APIs for injecting arbitrary dependencies as well." And the injected
file and network services go in favour of Foundation's own API, in 0.31.

**10. Apple's API only.** `@_spi(Isomer)` counts as public-facing.

- The check: tools/parity/parity.py counts SPI declarations, resolves what
  only looks like an addition (members Apple reaches through a typealias,
  `NSObject`'s and an imported option set's members, a case where Apple has
  a static property, what another Apple module the framework re-exports
  declares), checks underscored names against Apple's `.swiftinterface`,
  and fails when an Apple-named module has anything of Isomer's own.
- What a host or an app calls goes public in the Isomer* module beneath the
  Apple-named one, which reads it: IsomerSwiftUI (the host interface with
  resolved colours, the renderer a host binds, the runtime's entry points,
  the flat tree types), IsomerFoundation (UserDefaults' store, the URL
  transports), IsomerMetal (the drawable hook), IsomerCoreGraphics if
  anything needs it. The Isomer umbrella re-exports them and IsomerFFI.
- What only Isomer's own modules share (the render tree the Isomer module's
  views build, a colour's components) is `package`: every isomer target is
  built with `package_name = "isomer"`, which no application has.

**11. Foundation's services.** `URLRequest`, `URLResponse`,
`HTTPURLResponse`, `URLError`, `URLSession` (data, upload and download,
async and completion-handler forms, `URLSessionWebSocketTask`) in Isomer's
Foundation, over transports IsomerFoundation declares and each host
injects: the browser's `fetch` and `WebSocket`, Android's
`HttpURLConnection` and a WebSocket client in the runtime, Apple's
`URLSession` in the WAMR hosts. `FileManager`'s app directories persist:
a writable WASI directory kept in IndexedDB on the web, the app's files
directory on Android, the container in the WAMR hosts. `@AppStorage` reads
and writes `UserDefaults`, as Apple's does. Retired: `HostBridge`'s
`readFile`/`writeFile`, the Isomer module's `HostFileStore` and
`defaultFileStore`.

How it landed, the web's files (branch `web-persistent-files`):

- **Layout.** wasm/libraries/swift_ui/runtime/file_system.js gives the
  guest one tree, "/" preopened as fd 3, shaped as an iOS container:
  HOME=/home/app with Documents, Library/Application Support and
  Library/Caches, made at every start. swift-foundation on WASI takes the
  home from HOME (no users), Application Support and Caches from
  XDG_DATA_HOME and XDG_CACHE_HOME (else ~/.local/share and ~/.cache),
  Documents as ~/Documents, the temporary directory as /tmp/ (TMPDIR is
  not read there); the runtime's environ_get says HOME, XDG_DATA_HOME,
  XDG_CACHE_HOME and TMPDIR, and ISOMER_BUNDLE_IDENTIFIER when the page
  names the app. /tmp is in memory; /tmp/iso-import (picked and dropped
  files) is in every app's tree, read-only; the rest of "/" refuses writes
  (EACCES), as outside a container. `URL.documentsDirectory`,
  `.applicationSupportDirectory`, `.cachesDirectory` and the other
  search-path URLs are declared in foundation/Paths.swift: swift-foundation
  has them for Apple's framework only.
- **WASI calls.** path_open (create, truncate, exclusive, directory),
  fd_read/pread/write/pwrite (append), fd_seek/tell, fd_close/renumber,
  fd_sync/datasync/advise/allocate, fd_fdstat_get/set_flags,
  fd_filestat_get/set_size/set_times, path_filestat_get/set_times,
  path_create_directory, path_remove_directory, path_unlink_file,
  path_rename, fd_readdir (cut-off entries, cookies stable while fts
  removes), fd_prestat_get/dir_name, environ_get/sizes_get; links are
  ENOTSUP. Directories report one link (fts counts subdirectories by
  links otherwise), and no entry has inode 0 (FileManager skips those).
  stdin, stdout and stderr go to swift_ffi's built-ins, which a `wasi`
  override factory now receives.
- **Persistence.** Under HOME, a record per file and directory in the
  origin's IndexedDB (`isomer-files`, keys [app key, path under HOME]),
  read before the reactor is instantiated, written within 300 ms of a
  change (only the paths that changed, together) and at once when the page
  is hidden or left. Chrome aborts a leaving page's unfinished transaction now and
  then (the check lost a write just before a reload until this), so what
  isn't yet known to be written also goes to a localStorage journal
  (`isomer-files:<key>`, up to 1 MB of files), which the next load plays
  over IndexedDB and writes on. The key is `boot({ bundleIdentifier })`,
  else the reactor URL's path without its cache stamp. A page that opens
  the same key again (hot reload, a second surface) shares the tree.
  Without IndexedDB: memory, one warning.
- **Hosts.** boot.js, mountIsomer, `<Isomer>` and hot_host.js's
  runHotBundle take `bundleIdentifier`. Electron serves the site from a
  privileged `isomer://app/` scheme instead of a loopback port, so its
  origin, and the app's IndexedDB and localStorage, last across launches;
  its ISO_SCREENSHOT run keeps the window hidden. Sites assembled from a
  list of runtime files (an app's web build, the Playground's iOS site) must
  add runtime/file_system.js; isomer_web_app's list has it.
- **Checks.** //tests/web_files:file_system_test (the WASI layer in the
  hermetic Node); examples/web/files_probe_web_application with
  tools/testing/run_files_check.js in headless Chrome: directories where
  iOS has them, launches counted across reloads, Application Support and
  Caches kept, /tmp fresh, listing, rename, removal of a tree, a
  FileHandle append, a write made just before a reload, a record per file
  and none for what was removed, a second app's own home, memory without
  IndexedDB, and the journal carrying a page's refused writes. The probe
  also ran in Electron (both renderers) across launches.
- **For Android and the WAMR hosts** (not done here): the same layout
  under each host's own directory. Set HOME, XDG_DATA_HOME=$HOME/Library/
  Application Support and XDG_CACHE_HOME=$HOME/Library/Caches and make the
  three directories; on Android also CFFIXED_USER_HOME (swift-foundation
  asks getpwuid before HOME there) and TMPDIR (which it reads everywhere
  but WASI). A WAMR host
  maps HOME as a preopen (`/home/app::<container>`, the iOS container
  itself on Apple) beside its /tmp and passes the variables in its WASI
  environment.

How the rest landed:

- **Transports.** The web's runtime/network.js (fetch, WebSocket; a page's
  own through `boot({ fetch, WebSocket })`), Android's runtime
  (HttpURLConnection, its own RFC 6455 client), Apple's WasmView
  (URLSession, URLSessionWebSocketTask), each injected under
  `isomerHTTP`/`isomerWebSocket` and installed by the runtime at start.
- **Directories.** Android's runtime sets HOME, CFFIXED_USER_HOME and the
  XDG variables before any Swift runs (AppDirectories.kt); a WAMR host maps
  `IsoWamrCallbacks.home_dir` as /home/app, and Apple's WasmView gives the
  app's container. swift-foundation's intermediate-directory creation
  recursed past "/" where no preopen reached it (a stack overflow at the
  first save in a host with no home); the fork stops at the root (e8b0c06),
  checked in //foundation/tests.
- **`@AppStorage`** reads and writes UserDefaults, whose suites are files
  in Library/Preferences.
- **Retired.** PlatformServices' NetworkService, FileService and
  PreferencesService; WebHost's storageGet/storageSet, AndroidHost's
  fileRead/fileWrite, the Windows host's iso_read_file/iso_write_file, the
  Linux and Windows WAMR hosts' network and file dispatchers. The examples
  use URLSession and FileManager (the todos app's web build: gRPC-Web over
  URLSession, the database image a file; its Android build a SQLite file).

**12. Consumers.** Visor Isomer's socket, HTTP, settings and cache bridges
give way to visor's own Foundation implementations, compiled for every
platform (with Visor); dictation keeps its bridge. Other applications'
file stores and host HTTP follow.

**13.** Reports regenerated, AGENTS.md and this file, then 0.31 (3)
pre-release builds of Visor Isomer and the Playground.

