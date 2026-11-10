# TODO

Open items that are not yet tracked in code or docs.

## Move isomer to the Isomer Swift organization (after the next release)

GitHub's hosted-runner limits are per account (20 jobs at once on the free
plan, 5 of them macOS): in an organization of its own, isomer's tests stop
sharing a pool with visor's and agent_ui's. Moved between releases:

- Transfer the repository to the organization (GitHub redirects the old
  URL, archives included, while nothing new takes `AttilaTheFun/isomer`).
- Register our self-hosted runners again under the new owner: Shireworks'
  `isomer-jit` and the Mac's `isomer-containers` (the Shireworks session's).
- Install the agents' GitHub App on the organization; check that the code
  owner can still approve and that Container Helper's merges still work.
- Move what isn't the repository's own: account-level secrets and
  variables (Applications' CI code).
- The new URL where the old one is written:
  - bazel_registry's isomer entries (new ones; old ones redirect);
  - README, AGENTS.md, docs, the Playground's links;
  - the Pages site's address (`attilathefun.github.io/isomer` → the
    organization's), and the links to it;
  - consumers' MODULE.bazel comments and docs (Visor, Reviews).
- Tell Visor, Reviews, Shireworks and Upstream.

## The CI proof: what's left

The Build workflow's proof jobs picture the Storybook on every tier-1
platform when run by hand (verify, release), each picture compared with
the previous release's (AGENTS.md). Since 0.47 the Storybook alone: the
Playground's proof is AttilaTheFun/playground's.

- **Reviews' Publish waits for the proof** of the release's commit (a
  change in Reviews).
- **The full set's live stories:** the spinners, the map's tiles and the
  video's frame and buffering bar are painted grey as they are taken
  (tools/proof/masks.txt, proof.py's `mask`, since 0.50: CI compared with
  proof_ignore.txt's regions until 0.48 moved the comparison to Reviews,
  which compares every pixel); `isomer.webview` shows its own page (#80).
  Still to hold still at the source, so that nothing is masked: the map's
  tiles (tiles served to the story under the proof, so its markers count
  again), `isomer.video` (a video of the Storybook's own) and
  `images.async` (a remote image). After each release, compare its proof
  with the release before AND a second run of the same commit: whatever
  moves without the app changing gets fixed before the next.
- **Actions write for the Claude app**, so agents can start a full proof or
  rerun a failed job.

## Slots and app distribution (2026-11-03, done but for these)

The proof's Mac part runs on a `mac` slot of Shireworks' primary macOS VM
(#64) and its iPhone part in a simulator inside that VM (#65); the
Storybook publishes an Alpha when a release is proposed (#59, #60, #62).
Left:

- **Production promoted, not rebuilt**: the release job asks Applications
  Server to stamp the release commit's Alpha (BuildVariant rewritten,
  re-signed) once it has that route; it rebuilds with `--config=prod` today.
- **Android on a slot**: the proof's Android part still uses an emulator on
  Shireworks' Mac. It moves when Shireworks has an Ubuntu primary VM (held
  for the Mac Studio) or Android emulators in containers (being tried).

## The platforms' tests in containers (2026-11-04): what's left

Every platform's Storybook is now tested where it runs (AGENTS.md,
"Platform tiers"): the web, Linux and the GL checks in CI's build container,
Windows built on Linux and run under arm64 Wine, Android on Cuttlefish in a
container with its own KVM, the iPhone and the Mac on slots. Left:

- **The proof's Linux and Windows parts** still lease whole VMs. Linux's
  could move to the container's Xvfb (its pictures then lose GNOME's title
  bar, a one-time change); Windows' pixels stay Windows' (a Windows slot of
  a Windows primary, Shireworks' backlog for the Mac Studio). The proof's
  Android part could use the container phone once its boot is fast enough.
- **Android in a container doesn't finish booting on a Mac**, so CI tests
  Android on an emulator leased from Shireworks (the Mac's own hypervisor).
  Cuttlefish in a container with its own KVM (tools/ci/android_device.sh)
  boots far into the system server, which then restarts each time
  WebView's zygote times out starting. Not nesting: Virtualization's vCPU
  threads aren't real-time, and macOS's timer leeway makes every timed wait
  in a guest oversleep by about half (Shireworks' maintainers measured it;
  no Virtualization setting changes it; a report to Apple is filed).
  Android's timeouts scaled by 20 and the container's CPUs kept from idling
  got the system server from 75 to 18 minutes into a boot. On a Linux host
  with KVM the container is the fast path.
- **The Windows cross toolchain upstream**: bazelbuild/rules_swift#1988
  (`swift.windows_sdk`, draft); tools/windows gives way to it once released.
- **The build image**: container_build.sh installs Xvfb, Mesa's drivers and
  Chrome's libraries into Visor's agent image at each run; Wine 10 needs
  Ubuntu 26.04, so Windows runs in a container of its own. An image of
  Isomer's (or these in Visor's) would save both.

## Driving and remote sessions: what's left

docs/drive.md and docs/remote_sessions.md say what there is,
docs/drive_plan.md the order. Open:

- **Headful iOS and the Mac** (the plan's step 3): apps on Apple's SwiftUI
  are driven by drive/apple's in-process accessibility driver (0.48, step
  5); the Isomer-compiled build dialling out and a hosted XCTest transport
  are still open.
- **Headful Windows' pictures**: windows_launcher.sh answers a test's
  pictures with none (Linux's renderer writes its frame since 0.48).
- **TLS on Windows**: swift-nio-ssl has no Windows yet (its #567), so
  IsomerRemote (gRPC) and `exec:`/`unix:` are left out there; a Windows app
  dials out and a Windows test drives over plain WebSockets.
- **`isomer_test`** (step 4): one test source against Isomer's frameworks on
  Linux and Apple's in an XCTest bundle.
- **The DOM renderer** (owner, 2026-11-08): the web's React renderer replaced
  by one that applies the tree's patches to the DOM itself, held to the
  Storybook's pictures (0.48, the owner's choice of 2026-11-08).
- **The Playground over sessions** (owner, 2026-11-08): the hot reloader a
  head paired with a headless app, a rebuild swapping the app; Playgrounds
  peer to peer (headless wasm in a browser one Playground proxies, drawn by
  another).
- **Android's thin client in CI.** It was checked by hand on an emulator
  (drawn, tapped, typed into). The `android` job could run it: the app built
  headless for the runner, the x86_64 APK, `adb reverse` to its port.
- **TLS for WebSockets.** gRPC serves TLS (`grpcs`, IsomerGRPCServer's
  `tls`); the WebSocket listener is plaintext, for a local network or behind
  a proxy that terminates TLS.
- **The client's measurements.** Text is measured on the server as the
  headless host measures it; a client could send its fonts' metrics in
  `start` (a table per size and weight) for what the app computes from them.
- **Reconnecting.** A dropped connection ends its session (the app's run);
  resuming one (the app kept for a while, the client given the whole tree
  again) is open, as are recording a session and replaying it.

## Android below API 28 (2026-11-06)

Done with Swift 6.4 (0.41): swift.org's 6.4 Android SDK is built at API 23
with NDK r30, so its own fallbacks are compiled in (the runtime's
`strtod_l`, swift-foundation's `getgrgid`/`getgrnam`, corelibs'
`posix_spawn`) and no shim of Isomer's is needed. An app sets
`android.ndk(api_level = 23)` and `isomer_android_app(min_sdk_version = 23)`
(README, "Android below API 28"); rules_swift#2000 (in the registry's
4.2.2.isomer.3) reads the SDK's minimum and leaves out RELR below 28.
Isomer's Kotlin calls above 23 are behind version checks (#96).

- Open: Shireworks' api23 emulator config doesn't boot yet (Shireworks),
  so CI tests at 28+; draft isomer#92 ran the Storybook on Android 6.0.
- Later: 32-bit ARM (armeabi-v7a), if an app needs it.

## SwiftUI's next gaps (after 0.42's)

- Compose's DatePicker shows no label: `DatePicker("Day", …)` draws only
  the date's button, where Apple's puts the label on the left and the
  control on the right (the Storybook's DatePicker story).
- CGFloat and Double don't convert implicitly (SE-0307) on wasm and Android:
  //core_graphics/tests:conversion_check_wasm and _android fail with
  "standard library type 'Double' is missing or broken" under Swift 6.4.2,
  on main too, though CGFloat has `init(_: Double)` and Double
  `init(_: CGFloat)`. An app's `let width: Double = rect.width` fails
  there. CI's build doesn't include the check; it should once it passes.
- `AnyGradient.colorSpace(_:)` (needs `Gradient.ColorSpace` on gradients)
  and `GraphicsContext.Shading`'s gradients.
- The web's guest has no time zone (WebAssembly carries no tz database):
  a DatePicker there shows the user's instant in UTC. The page could pass
  its zone (`Intl.DateTimeFormat().resolvedOptions().timeZone`) and Isomer's
  Foundation resolve it, which needs FoundationInternationalization's data.
- Compose draws an elliptical gradient as its radial one (centred, to the
  far edge), as it draws every radial gradient: a brush sized to the node.

## Upstream releases, no forks

The goal: every dependency at an upstream tagged release (a BCR version, a
SwiftPM version, a swift.org toolchain), with no forks, no patches and no
git or archive overrides; the project's registry then holds only the
project's own modules. Every change we carry has an upstream PR now
(2026-11-04, drafts unless noted); each patch or fork goes when a release
has it.

- **rules_swift** (the registry's 4.2.2.isomer.3: upstream 4.2.2 and a
  patch per PR, from its head):
  - bazelbuild/rules_swift#1860 (open): the metadata-driven wasm SDK and its
    wasip1-threads variant;
  - #1990 (open, on #1860): a single-threaded and a threads wasm SDK side
    by side;
  - #1989 (merged after 4.2.2): the wasm SDK's clang resource directory for
    C compiles;
  - #1995 (open): Swift/C++ interop on Android;
  - #1985 (merged after 4.2.2): swift.org's release metadata through 6.4.2;
  - #2000 (open, rebased over #1998 at ab75b825): Android down to the
    Swift SDK's own minimum (6.4's: 23), no RELR below 28. Upstream main
    has #1998 (merged 2026-11-06, b7e99a5b), which fails below API 28: a
    rules_swift release with #1998 and not #2000 needs the registry's patch
    to remove `_check_android_api` and its call too (#2000's head does);
  - #1988 (draft): `swift.windows_sdk`, Windows built on Linux with the
    builder's own SDKs (Isomer's tools/windows, upstream's
    tools/windows_sdk), which tools/windows then gives way to.
  - explicit modules (`swift.emit_c_module` + `swift.use_c_modules`):
    bazelbuild/rules_swift#1909 (the non-Xcode toolchains; our Android and
    wasm findings added) and #1997 (C++ on Apple). On the non-Xcode
    toolchains (Linux, Android, wasm) no C module is precompiled and no
    system module (SwiftShims, the libc module) supplied, though implicit
    module maps are turned off ("no such module", "missing required module
    'SwiftShims'"); on Apple a C++ library's module is precompiled as C,
    and the system-module scan never reaches libc++'s `std` or CxxStdlib.
    Nothing in Isomer to change: an app that needs explicit modules waits
    for those.
- **swift-foundation** (a Swift package through rules_swift_package_manager
  at swift-6.4.2-RELEASE's commit, with patches; no fork since 0.40):
  - swiftlang/swift-foundation#2409 (merged): `createDirectory(withIntermediateDirectories:)`
    stops at "/" (WASI); patched in until a release has it;
  - CharacterSet, NSString's string API and `String(format:)` are in
    //foundation; upstream's own CharacterSet (#2314) arrives with the
    next major release, and ours then gives way;
  - (the wasi-libc emulation defines its Swift targets' Clang importer
    needs: rules_swift_package_manager#2640 passes their cSettings, as SwiftPM
    does; no patch of swift-foundation since 0.44);
  - Isomer's own, with no upstream form: ICU linked from the Swift SDK
    (not swift-foundation-icu from source), Apple's signatures and
    swift-foundation's extra declarations made internal, `package` on the
    string helpers //foundation uses (a copy would need its 2.8 MB Unicode
    tables and the standard library's SPI: until upstream's next major
    release brings CharacterSet, #2314, and its string API). Off Darwin its
    `.diacriticInsensitive` and `.widthInsensitive` comparison is
    `fatalError("not implemented yet")`: worth reporting upstream.
- **WasmKit** (AttilaTheFun's fork, and two patches): swiftwasm/WasmKit #513
  (iOS guard pages), #514 (Android's software bounds checks), #515 (MSVC's C),
  #516 (constant-pool reservations), #517 (internal calls off the native
  stack) and #518 (the dispatch fusions, on #517). #517's CoreMark needs a
  measurement on a quiet machine.
- **rules_swift_package_manager**: cgrindel/rules_swift_package_manager#2621
  (draft): Windows hosts.
- **hermetic_android_toolchains**: keith/hermetic_android_toolchains#110
  (draft): Linux hosts of any CPU. Carried as the registry's
  0.5.0.isomer.1 (bazel_registry#42) since 0.42, so consumers need no
  override; the entry goes when a release has #110.
- **rules_apple** (rules_applecross's patches): bazelbuild/rules_apple #3114
  to #3124 (drafts, tracked in apple-cross-toolchain/rules_applecross#273);
  three workarounds stay in rules_applecross until upstream fixes exist.
- **apple_support**: its patch is upstream in 2.11.0 (#669): move to 2.11.0
  and drop it.
- **The threads Swift SDK** for wasm: swiftlang/swift#92018 is merged; the
  fork goes when swift.org publishes a wasip1-threads SDK.

## Swift, not Python

The tools should be Swift wherever Swift can do the job, with no Python in
the repository: executable targets (`swift_binary`, or a package's `swift
run`), CoreGraphics and ImageIO for images.

- **Run by Bazel** (`py_binary`, on rules_python 2.0.2's hermetic Python
  3.12):
  - swift_ffi's `export_list.py` (a reactor's exports);
  - tools/wasm's `icu_data.py`, `sdk_exports.py` and `serve.py` (the web
    apps' `bazel run`, swift_map's too), and its `site_imports_test.py`;
  - the network probe's `network_check.py`.

  With these in Swift, rules_python and its toolchain leave MODULE.bazel.
- **Run by CI:** the proof (`tools/proof/proof.py`, which CI's
  `tools/ci/proof.sh` runs on every platform: its builds, its leases, the
  apps' launches, story switching, the hold-still status bars and the
  window crops with Pillow). Its comparing and its `proof.json` are
  Swift already (`tools/ci/proof_compare.swift`).
- **Run by hand or by agents:**
  - the headless Chrome driver (`tools/testing/cdp.py`, and swift_map's
    copy);
  - the parity reports (`tools/parity`);
  - the SwiftUI audit (`tools/swiftui_audit`, nine scripts);
  - `tools/foundation/check_link.py` and `tools/symbols/generate.py`;
  - the version stamp (`examples/tools/stamp_storybook.py`);
  - the pixel benchmark.

## No Node

Node never runs in an Isomer app. It is in the build and the tests (rules_nodejs
6.7.5's hermetic Node; never npm), and it can go too:

- **TypeScript.** swift_ffi's `ts_swift_library` compiles the generated web
  bindings with `tsc` 5.8.3, through aspect_rules_ts and aspect_rules_js. If
  swift_ffi generated JavaScript itself (with a `.d.ts` for typed callers),
  `tsc` would go.
- **esbuild** bundles the Metal web tests and swift_ffi's web example, run
  through aspect_rules_esbuild's Node launcher. Serving those as plain ES
  modules, as the web runtime already is, removes it.
- **Tests run in Node:** tests/web_files (`file_system_test`, `blocks_test`),
  tests/web_network (`network_test`) and swift_ffi's web example. They could
  run in headless Chrome, the browser the code is for.
- **Dev tools in Node:** tools/testing's `cdp_shot.js`, `cdp_eval.js`,
  `run_files_check.js`, `run_network_check.js` and `network_server.js`, and
  tools/metal's `run_metal_check.js` and `validate_wgsl.js`. They would be
  Swift, with the Chrome driver (`cdp.py`, above).

With all of them gone, rules_nodejs, aspect_rules_js, aspect_rules_ts and
aspect_rules_esbuild leave MODULE.bazel. Electron's `main.js` runs in
Electron's own Node, part of the Electron app rather than the build.

## Hermetic builds (tabled)

- **Swift 6.4 everywhere (done in 0.41).** The host, wasm, Android and
  Windows toolchains moved from 6.3.2 to swift.org's 6.4.2: rules_swift
  4.2.2.isomer.3, NDK r30, swift-foundation at swift-6.4.2-RELEASE's
  commit (no fork since 0.40), compiled features' Observation from 6.4.2's
  sources, SwiftUI's macros on every platform, and the Playground's
  on-device compilers' build scripts at swift-6.4.2-RELEASE. rules_apple
  and apple_support had moved in 0.40. rules_applecross still brings
  swift.org's 6.4.0 (the Swift that built Xcode 27.0's SDKs) for the Apple
  targets alone. Left from it:
  - the wasi-threads SDK: none until Swift 6.5, the first release with
    swiftlang/swift#92018; the threaded reactors and their tests wait;
  - swift-syntax is still 603.0.2 (BCR) for swift_ffi's plugin and
    analyzer.
- **Building on a Mac without Xcode.**
  - rules_applecross stages the SDKs from the SDK archive on a Mac with no
    Xcode (its #213).
  - Bazel's XcodeLocalEnvProvider still looks up an installed Xcode
    (xcode-locator, then `xcrun --sdk … --show-sdk-path`) for every action
    that names XCODE_VERSION_OVERRIDE or APPLE_SDK_PLATFORM. Linux hosts
    skip it.
  - Bundling on a Mac runs Xcode's own tools, while the clean-room
    actool, ibtool and codesign exist only as Linux builds.
  - The exec configuration's host tools (swift-syntax and the macros,
    swift_ffi's generator, flatc, protoc) need a C/C++ toolchain and a
    macOS SDK: perhaps the staged MacOSX.sdk with the hermetic `llvm`
    clang.
  - The Linux-native targets, built from a Mac, need a Linux sysroot.
  - To check first: nested virtualization, so that a macOS VM runs the
    Linux-container build itself.

## Consuming the SwiftUI module from packages

- **Apple framework for the `SwiftUI` module.** A SwiftPM package whose
  sources `import SwiftUI` (e.g. MessagesUI) currently reaches our module
  on wasm/Android/Linux/Windows only through rules_swift_package_manager's
  `target_deps` hook, which rewrites the generated package target's
  dependencies to add `@isomer//:swift_ui`. That requires the
  ability to rewrite a package's dependency graph; a prebuilt framework
  (static or dynamic, an xcframework per platform slice) is just a linker
  flag, so any build system could link it. Decide static vs dynamic, how
  the per-platform host modules (IsomerBridge, SwiftUIExtensions, the
  skim Foundation) ship alongside, and whether the module name `SwiftUI`
  can coexist with the system framework on Apple targets (it should never
  be linked there — the system SwiftUI is the drop-in).

- **Pure SwiftPM (and other build systems) for swift_ffi.** On the Swift
  side all the C-ABI codegen is done by the `@ExportedInterface` /
  `@ExportedFunction` macros, so a package only needs the macro plugin and
  the runtime library. The analyzer + generator (TypeScript, Kotlin, C++,
  Rust, C hosts) are a separate CLI today, driven by the Bazel aspect;
  expose them as a SwiftPM build-tool plugin (and a plain CLI invocation)
  so a package can produce its bindings without Bazel, then add
  integrations for other build systems — a Gradle plugin for the Kotlin
  facade + JNI adapter, an npm/tsc step for the web bridge.

Decided since (the proof's shape, 2026-11-01): pull requests and main's
commits get the build and the checks alone; the proof runs by hand, the
full set (605 pictures) to propose a release, compared with the previous
release's, and after the fact on earlier commits to bisect a regression.
A release is promoted only from a main commit whose proof is in: Reviews'
Publish waits for it. Still to do: Reviews' release page holds Publish
until the commit's proof is there.
