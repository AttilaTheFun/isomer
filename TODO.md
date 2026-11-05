# TODO

Open items that are not yet tracked in code or docs.

## Move isomer to the Isomer Swift organization (after the next release)

GitHub's hosted-runner limits are per account (20 jobs at once on the free
plan, 5 of them macOS): in an organization of its own, isomer's tests stop
sharing a pool with visor's and agent_ui's. Moved between releases:

- Transfer the repository to the organization (GitHub redirects the old
  URL, archives included, while nothing new takes `AttilaTheFun/isomer`).
- Register our self-hosted runners again under the new owner: OS Server's
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

The Build workflow's `proof` job pictures the Storybook and the Playground
on every platform after each commit merges to main (the core set, 136
pictures, about 40 min after the build), each compared with the newest
commit before it that has a proof (AGENTS.md). Two runs of one commit
(40960663857, 40967787636) matched on 135 of 136 screens; the other is
iOS 26's glass restart button over 2048, in tools/ci/proof_ignore.txt.

- **Reviews' Publish waits for the proof** of the release's commit (a
  change in Reviews).
- **The full set's live stories don't hold still yet**:
  `controls.progress` (an indeterminate spinner), `isomer.webview` (a live
  page), `isomer.video` (a remote video), `isomer.map` (OpenStreetMap
  tiles), `images.async` (a remote image). They need bundled content and
  paused animations under the proof, or listed regions; two full runs
  compared would say which really move. The full set runs only by hand.
- **The Pokédex reads PokéAPI live.** Its pictures have held still so far.
- **Proofs last 90 days** (artifacts): a commit's proof could be attached
  to its release so a later one still has it.
- **Actions write for the Claude app**, so agents can start a full proof or
  rerun a failed job.
- **oss**: `oss machine ssh` printed a lease's JSON, passwords included,
  when its lookup failed (run 40955851424; that VM is deleted). proof.py
  now redacts it; oss itself should not print it.

## Slots and app distribution (2026-11-03, done but for these)

The proof's Mac part runs on a `mac` slot of OS Server's primary macOS VM
(#64) and its iPhone part in a simulator inside that VM (#65); the
Storybook and the Playground publish an Alpha of each main commit to
Applications Server (#59, #60, #62). Left:

- **Production promoted, not rebuilt**: the release job asks Applications
  Server to stamp the release commit's Alpha (BuildVariant rewritten,
  re-signed) once it has that route; it rebuilds with `--config=prod` today.
- **Android on a slot**: the proof's Android part still uses an emulator on
  OS Server's Mac. It moves when OS Server has an Ubuntu primary VM (held
  for the Mac Studio) or Android emulators in containers (being tried).

## The platforms' tests in containers (2026-11-04): what's left

Every platform's Storybook is now tested where it runs (AGENTS.md,
"Platform tiers"): the web, Linux and the GL checks in CI's build container,
Windows built on Linux and run under arm64 Wine, Android on Cuttlefish in a
container with its own KVM, the iPhone and the Mac on slots. Left:

- **The proof's Linux and Windows parts** still lease whole VMs. Linux's
  could move to the container's Xvfb (its pictures then lose GNOME's title
  bar, a one-time change); Windows' pixels stay Windows' (a Windows slot of
  a Windows primary, OS Server's backlog for the Mac Studio). The proof's
  Android part could use the container phone once its boot is fast enough.
- **Android in a container doesn't finish booting on a Mac**, so CI tests
  Android on an emulator leased from OS Server (the Mac's own hypervisor).
  Cuttlefish in a container with its own KVM (tools/ci/android_device.sh)
  boots far into the system server, which then restarts each time
  WebView's zygote times out starting. Not nesting: Virtualization's vCPU
  threads aren't real-time, and macOS's timer leeway makes every timed wait
  in a guest oversleep by about half (OS Server's maintainers measured it;
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

## Upstream releases, no forks

The goal: every dependency at an upstream tagged release (a BCR version, a
SwiftPM version, a swift.org toolchain), with no forks, no patches and no
git or archive overrides; the project's registry then holds only the
project's own modules. Every change we carry has an upstream PR now
(2026-11-04, drafts unless noted); each patch or fork goes when a release
has it.

- **rules_swift** (the registry's 4.1.0.isomer.3):
  - bazelbuild/rules_swift#1860 (open): the metadata-driven wasm SDK and its
    wasip1-threads variant;
  - #1990 (open, on #1860): a single-threaded and a threads wasm SDK side
    by side (`rules_swift_wasm_threads_beside.patch`);
  - #1989 (open): the wasm SDK's clang resource directory for C compiles
    (`rules_swift_wasm_clang_resource_dir.patch`);
  - #1995 (open): Swift/C++ interop on Android
    (`rules_swift_android_cxx_interop.patch`);
  - the worker's copy fix is upstream since 4.2.0 (#1905): the patch goes
    with the move to a 4.2 release;
  - #1988 (draft): `swift.windows_sdk`, Windows built on Linux with the
    builder's own SDKs (Isomer's tools/windows, upstream's
    tools/windows_sdk), which tools/windows then gives way to.
- **swift-foundation** (the registry's 6.3.2.isomer.2: swiftlang's
  swift-6.3.2-RELEASE and patches; no fork since 0.40):
  - swiftlang/swift-foundation#2409 (merged): `createDirectory(withIntermediateDirectories:)`
    stops at "/" (WASI); patched in until a release has it;
  - Android's `fts_open` workaround isn't needed upstream: the Android Swift
    SDK's apinotes fix it, but rules_swift's Android toolchain compiles with
    the static resource directory, which has none (`swift-<arch>/apinotes`
    only): a rules_swift change to load them, then the patch goes;
  - CharacterSet, NSString's string API and `String(format:)` are in
    //foundation; upstream's own CharacterSet (#2314) arrives with the
    next major release, and ours then gives way;
  - Isomer's own, with no upstream form: the Bazel build, Apple's signatures
    and swift-foundation's extra declarations made internal, `package` on
    the string helpers //foundation uses.
- **WasmKit** (AttilaTheFun's fork, and two patches): swiftwasm/WasmKit #513
  (iOS guard pages), #514 (Android's software bounds checks), #515 (MSVC's C),
  #516 (constant-pool reservations), #517 (internal calls off the native
  stack) and #518 (the dispatch fusions, on #517). #517's CoreMark needs a
  measurement on a quiet machine.
- **flatbuffers** (the registry's 25.12.19.isomer.1): google/flatbuffers#9461
  (open): FlatBuffers without Foundation on WASI (Android's part of
  `flatbuffers_foundation_wasi.patch` stays ours); the Swift Vectors glob is
  fixed upstream (#8875) and goes with the next release.
  `flatbuffers_dev_dependencies.patch` (its JS, TS, Go and gRPC dependencies
  dev-only, so no rules_foreign_cc in a consumer's graph) is ours to keep
  until the BCR's entry does the same, or upstream's MODULE.bazel.
- **rules_swift_package_manager**: cgrindel/rules_swift_package_manager#2621
  (draft): Windows hosts.
- **hermetic_android_toolchains**: keith/hermetic_android_toolchains#110
  (draft): Linux hosts of any CPU.
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
  - the Playground's `dev_compile_server.py`;
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
  - the version stamps (`examples/tools/stamp_storybook.py`, the
    Playground's `stamp.py` and `template_history.py`);
  - the Playground's e2e runner (`tests/e2e/run.py`);
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

- **Swift 6.4.0 everywhere.** Isomer pins Swift 6.3.2 for its host, wasm
  and Android toolchains. Moving all of them to 6.4.0 (the Swift that built
  Xcode 27.0's SDKs) means:
  - rules_swift 4.x, with the two patches in tools/patches ported (a new
    registry version);
  - rules_apple 5.x and apple_support 2.10, with rules_applecross's patches;
  - the swift-foundation fork on 6.4.0;
  - the wasi-threads SDK for 6.4;
  - swift-syntax 604;
  - the Playground's on-device compilers.

  rules_applecross alone doesn't need it: it brings swift.org's 6.4.0 for
  the Apple targets only, beside 6.3.2.
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
