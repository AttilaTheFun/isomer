# AGENTS.md — the Playground (isomer/playground)

Context for AI agents (and new humans) working on the Playground. README.md
says what it is and where things are; the parent checkout's AGENTS.md is
Isomer's own guide. If something here contradicts the code, trust the code
and update this file.

## What it is

The Isomer app (com.LoganShire.Isomer; the Playground, as this module is
still named): one SwiftUI shell on six platforms, and Isomer's integration
test app. Its sidebar has three sections:

- **Projects**: write SwiftUI on the device (an agent writes it, or you do),
  build it there with a Swift compiler the app carries, run it on Isomer.
  Where a compiler is: iOS, Android, the web.
- **Hot Reloaders**: follow an app published to a URL (versions.json and its
  reactors), run its newest version, reload as new ones appear. Every
  platform.
- **Gallery**: Isomer's apps and components (isomer's `//gallery`, the
  library the examples' apps show too), drawn by the app's own renderer, and
  "Run as wasm": the Gallery's reactor (`shared/gallery_reactor:gallery.wasm`,
  carried by every app) on the platform's engine. Every platform.

The shell is `shared/app` (App.swift: the sidebar and a page per selection,
Visor's two-column shape; a phone opens on the sidebar), compiled against
Apple's SwiftUI on iOS and macOS and Isomer's elsewhere. What is
platform-bound is the host's: `PlaygroundHostService` (shared/app/Services.swift:
compiling, running a reactor, the chat's network, the renderer choice, the
capabilities that decide which sections show) and `PlaygroundSurfaces` (the
run surface, the code editor). The hosts:

| Platform | App | Host | A run (a build, a reactor) |
| --- | --- | --- | --- |
| iOS | `apple/playground_ios_application` | `apple/host` (AppleHost: the embedded compiler, the in-app web run, OpenRouter sign-in) | WasmView on WasmKit, SwiftUI or Metal |
| macOS | `apple/isomer_macos_application` | `apple/host` | WasmView on WasmKit (a sheet) |
| Android | `android/playground_android_application` | Kotlin (PlaygroundServices.kt) | RunActivity (a process of its own), WasmView on WasmKit |
| Web | `web/playground_web_application` | index.html | the page's runner (hot_runner.js), the browser's engine |
| Linux | `linux/isomer_linux_application` | `shared/desktop_host` | the WasmKit loader's window (`isomer_wasm_loader`) |
| Windows | `windows/isomer_windows_application` | `shared/desktop_host` | the WasmKit loader's window |

Launch hooks (the process environment natively; an Android intent's `ISO_`
string extras; the web page's `ISO_` query parameters): `ISO_OPEN_APP=<entry>`
opens a Gallery entry (GalleryEntry.slug: pokedex, todo, map, controls…),
`ISO_RUN_GALLERY_WASM=1` runs it as wasm, `ISO_RUN_REACTOR=<url>` runs a
reactor, `ISO_PLAYGROUND_OPEN_PROJECT=<id or name>` and `ISO_OPEN_RELOADER=<name>`
open a project or a reloader.

History: `examples/*/playground_*` in isomer until 0.15, then a repository
of its own (pinning isomer by commit), back in isomer as `playground/` at
0.35, a demo of what Isomer does.

## The module

| Directory | What |
| --- | --- |
| `apple/` | the iOS app and its embedded-compiler staging scripts, the Mac app, `host` (the Apple host and @main), `platform_services_host` (the services a run gets in WasmView) |
| `android/` | the Android app (Kotlin host: compile, run, chat, the web run), `platform_services` (the services a run gets), the transcript stress app |
| `web/` | the web app, the splash page (the whole site is `//web/splash_web_application:site`), the transcript stress app |
| `linux/`, `windows/` | the desktop apps (built in an oss container on a Mac, and on Windows) |
| `shared/` | `app` (the shell), `desktop_host` (Linux and Windows), `gallery_reactor`, `sample_sources` (the templates' sources), `transcript_stress_application` |
| `tools/` | `playground_toolchain` (the iOS and Android compilers), `browser_toolchain` (the compiler as WebAssembly), `playground` (dev compile server, headless Chrome drivers, the site's packaging and the hot-reload publish scripts, template history), `patches` and `signing` (below) |
| `tests/` | `templates` (every template compiles), `e2e` (what a reader does, on an emulator and a simulator), `proof` (the Gallery on every platform and renderer), `ios_ui_probe` (a manual XCUITest) |
| `docs/` | `playground.md` (the iOS app), `playground_web.md` (the web app, the site, publishing) |
| `third_party/swift_packages` | the module's SwiftPM graph: AgentUI and OpenRouterKit |

- **A Bazel module of its own** (`isomer_playground`), consuming isomer
  exactly as `examples/` does: `bazel_dep(name = "isomer")` +
  `local_path_override(path = "..")`. The root module's `.bazelignore` lists
  `playground`, so isomer's `//...` never sees it; run Bazel from
  `playground/`. Labels here are this module's (`//apple/...`); isomer's are
  `@isomer//...`.
- **Root-only overrides are repeated** (bzlmod honours them from the root
  module only): flatbuffers' two patches, rules_foreign_cc, the Swift and
  Android toolchain tags and registrations, the Maven install over a
  vendored lock. The rules_swift and swift-foundation forks come by version
  from the project's registry (.bazelrc lists it before the BCR), patches
  and all. `examples/MODULE.bazel` is the reference: when isomer changes an
  override or a version there, change it here the same way.
  `tools/patches/*.patch` are copies of `examples/tools/patches`
  (`cmp` them). The Playground declares only the single-threaded wasm SDK.
- **The SwiftPM graph** (agent_ui and open_router_cli, public) is pinned by
  revision in `third_party/swift_packages/Package.swift` + `Package.resolved`
  (re-resolve with `swift package resolve` there, then delete `.build`), and
  resolves under this module's own extension identity
  (`third_party/swift_packages/extensions.bzl`). Its targets that import
  SwiftUI or Foundation depend on `@isomer//:swift_ui` and
  `@isomer//:foundation` (`configure_package` in MODULE.bazel): Isomer's on
  wasm and Android, nothing on Apple.
- **Signing is the builder's**: an iPhone build takes its Apple team from
  `ISOMER_TEAM_ID` (`common --repo_env=ISOMER_TEAM_ID=<team>` in an untracked
  `.bazelrc.user` here; `tools/signing`, as the examples'). No team, profile,
  device identifier or person's name goes in a tracked file.
- **Versions**: the apps display the number of the Isomer release they ship
  with (iOS `Info.plist`, Android `version_name`); build numbers
  (`CFBundleVersion`, `version_code`) are integers that only go up.

## Rules

- **The staged compilers** (`apple/playground_ios_application/embedded_toolchain`,
  `android/playground_android_application/toolchain`) are gitignored (the
  repository root's `.gitignore`) and about 1 GB together. Both carry the
  toolchain's prebuilt macro plugins (ObservationMacros, SwiftMacros) and
  the in-process plugin server; the browser's compiler runs them as one wasm
  module (tools/browser_toolchain/README.md "Macros"). A fresh clone does
  not have them, and the apps then build but cannot compile; never delete
  them from a checkout that has them.
- **Copies of the examples' files**: `shared/sample_sources` is
  `examples/shared/example_application`'s (the template sources),
  `apple/platform_services_host` is `examples/apple/platform_services_host`,
  `android/platform_services` is the examples' `AppServices.kt` and
  `platform_services_wasm`. Another module's files cannot be labels here, so
  they are copied: when the examples' change (or isomer's platform services
  change shape), these follow by hand. `samples.bzl` drops `import` lines
  (and the Linux/Windows `FoundationNetworking` block) when it assembles a
  template.
- **Templates out of the box**: a project made from a template and never
  edited takes the current template at launch (`TemplateHistory`, the
  fingerprint of every version ever shipped). After a template changes (a
  sample source, `samples.bzl`, `Splash.swift`) and the change is committed,
  run `tools/playground/template_history.py` and commit what it writes.
- **The web-run site** of the iOS and Android apps takes its bridge from the
  web app's compiled bindings (`//web/playground_web_application:app_bridge_js_files`):
  a platform service the page injects must exist there.
- **Publishing** the web site or a hot-reload feed is deliberate, never part
  of a build or a test. The site: `tools/playground/package_site.sh` makes
  `isomer-site.tar.gz`, `gh release upload <tag> isomer-site.tar.gz` attaches
  it to a release, and the repository's `.github/workflows/pages.yml` deploys
  it to https://attilathefun.github.io/isomer/ when the release is published
  (or by hand; docs/playground_web.md "Publishing"). Never commit the site:
  it is about 115 MB of compiled output. A hot-reload feed:
  `tools/playground/publish_hot_reload.sh`.
- **A person's own phone is not a test device.** Install a build there only
  when its owner asks, read the installed version back, and stop: no
  launching, tapping, screenshots or autorun hooks unless they ask for
  exactly that. Test on the iOS simulator and the Android emulator (or a
  phone kept for testing, through `ANDROID_SERIAL`).

## Verifying

- `bazel test //...` from `playground/`: the site-import tests (a page with
  a missing module is silently blank) and `templates_compile_test` (every
  template compiles and links against the Playground SDK with the host
  toolchain). On every change of isomer or a dependency.
- `bazel build //...`, and the apps as they ship:
  `--ios_multi_cpus=sim_arm64 //apple/playground_ios_application`,
  `-c opt //web/splash_web_application:site`,
  `-c opt //android/playground_android_application`.
- **`tests/e2e/run.py [android] [ios]`** before a build goes to anyone's
  phone or a release: what a reader does, against the builds that get
  installed. Android (the hermetic emulator, `emulator-5554` only, booted
  if none is up and killed after; the app's data cleared first, so the
  projects are the templates'): the app compiles 2048 on the emulator, then
  every other template (the Pokédex's `@Observable` needs the staged macro
  plugins); "Run on the web" must serve a page that loads in headless Chrome
  with no failed request or script error (`page_check.js`), and "Run" must
  start the build in its own window and survive a swipe. iOS (its own
  simulator, `playground-e2e`): "Run on the web" must show the project
  inside the app's Safari view, read through Isomer's XCUITest driver
  (`examples/tests/safari_probe` in the parent checkout). It exists because
  "Run on the web" reached phones blank twice: the site's file list missing
  a module, then a stale APK.
- **The Gallery on every platform**: `tests/proof/proof.py [ios] [macos]
  [android] [web] [linux] [windows] --review <dir>` shoots the main menu and
  every Gallery entry with each platform's renderers, in the app and as
  wasm (folders `<platform>-<renderer>`, e.g. `ios-wasm-metal`), on oss
  leases (the web in headless Chrome here). Linux builds in an oss container
  (isomer's tools/linux/build.sh); Windows builds on the oss Windows VM
  (`--config=swift-6.3.2`: Visual Studio's build tools, Swift, Python; isomer's
  tools/ci/oss/windows-swift.ps1), in MSVC's environment with Git's bash.
- **A release's proof**: `tests/e2e/run.py --review <dir> [--commit <sha>]`
  also writes the review store's runs (app "Isomer", the version
  `version_name` says: stamp the release's into the working tree first, as
  CI does): each app's screens in portrait and landscape, and each road of
  the run recorded. They go to the review server with the review tooling's
  `publish_proof` (`bazel run //reviews/harnesses:publish_proof -- runs
  <folder of review-<run> folders> --commit <sha>` in the reviews checkout,
  `REVIEW_SERVER_CODE` from `reviews-server code` on its Mac, never on a
  command line). Reviews holds a release until its commit has them.
- iOS: on a simulator. `bazel run //apple/playground_ios_application:run`
  builds, installs and launches there with the host toolchain; with the
  embedded compiler staged for the simulator the app compiles in-process, and
  `SIMCTL_CHILD_ISO_PLAYGROUND_AUTORUN=native` builds a sample and logs
  `[playground] compiled N bytes`. Shut the simulator down after.
- Android: on isomer's hermetic emulator (`bazel run @isomer//tools/android/emulator
  -- -no-window`); kill it afterwards.
- Web: serve the site (`bazel run //web/splash_web_application:serve`, or
  the dev compile server, docs/playground_web.md) and drive it with
  `tools/playground/cdp_eval.js`; the manual
  `//web/playground_web_application:smoke` test does a whole
  compile-run-tap. Stop every server and headless Chrome you start.
- On a phone, when its owner asks for the build:
  `DEVICE=<udid> apple/playground_ios_application/install_device.sh` and
  `tools/install_android.sh <serial>`. Both BUILD and then install (never
  install an APK or IPA from a path an earlier build left: 0.19's Android
  install was a build from before the last fix); the Android one also checks
  the packaged "Run on the web" site and has ART compile the app ahead of
  time (`cmd package compile -m speed`: a sideloaded app's Kotlin and
  Compose otherwise run interpreted until the phone's idle maintenance).
  Neither launches the app.

## What a build runs on

WasmKit (the optimized fork, isomer's MODULE.bazel `wasmkit`) on every
native platform since 0.38; WAMR is gone.

- **iOS**: in-process under `WasmView`, on WasmKit (`WasmRuntimeRegistry`'s
  default), drawn by the SwiftUI tree renderer or, by the Settings choice,
  SwiftGPU over Metal; or in Safari ("Run on the web").
- **macOS**: under `WasmView` in a sheet, the SwiftUI tree renderer.
- **Android**: in its own window and process (`RunActivity`, `:run`) under
  the Android WasmView: WasmKit as a Swift library of its own
  (isomer's android/libraries/wasm_view:engine_native), which is why a run
  has a process of its own (one Swift runtime a process); or in a Chrome tab.
- **Web**: in the page, on the browser's own WebAssembly engine.
- **Linux, Windows**: the WasmKit loader's window, a child process.
