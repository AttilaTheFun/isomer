# AGENTS.md — the Playground (isomer/playground)

Context for AI agents (and new humans) working on the Playground. README.md
says what it is and where things are; the parent checkout's AGENTS.md is
Isomer's own guide. If something here contradicts the code, trust the code
and update this file.

## What it is

The Playground (com.LoganShire.IsomerPlayground, "Playground"): one SwiftUI
shell on six platforms for writing SwiftUI on the device (an agent writes
it, or you do), building it there with a Swift compiler the app carries,
and running it on Isomer. New projects start from its canned examples, the
templates (`shared/sample_sources`: Counter, 2048, Hacker News, Meme
Creator, Pokédex, Date Planner, Map Explorer, Floating Menu, and "This
website"), which live only here. Isomer's SwiftUI API is proven by the
Storybook (isomer's `examples/`), not here.

The shell is `shared/app` (App.swift: the projects in a sidebar and the
project open, Visor's two-column shape; a phone opens on the sidebar),
compiled against Apple's SwiftUI on iOS and macOS and Isomer's elsewhere.
What is platform-bound is the host's: `PlaygroundHostService`
(shared/app/Services.swift: compiling, running a build, the chat's network,
the renderer choice, the capabilities: "projects" where it compiles) and
`PlaygroundSurfaces` (the run surface, the code editor). The hosts:

| Platform | App | Host | A build runs in |
| --- | --- | --- | --- |
| iOS | `apple/playground_ios_application` | `apple/host` (AppleHost: the embedded compiler, the in-app web run, OpenRouter sign-in) | WasmView on WasmKit, SwiftUI or Metal |
| macOS | `apple/playground_macos_application` | `apple/host` (AppleHost: the compiler it carries, run as processes) | WasmView on WasmKit (a sheet) |
| Android | `android/playground_android_application` | Kotlin (PlaygroundServices.kt) | RunActivity (a process of its own), WasmView on WasmKit |
| Web | `web/playground_web_application` | index.html | the page's runner (hot_runner.js), the browser's engine |
| Linux | `linux/playground_linux_application` | `shared/desktop_host` (the compiler beside the app, run as processes) | the WasmKit loader's window (`playground_wasm_loader`) |
| Windows | `windows/playground_windows_application` | `shared/desktop_host` (the same) | the WasmKit loader's window |

Launch hooks (the process environment natively; an Android intent's `ISO_`
string extras; the web page's `ISO_` query parameters):
`ISO_PLAYGROUND_OPEN_PROJECT=<id or name>` opens a project,
`ISO_PLAYGROUND_RUN_PROJECT=<id or name>` opens it and builds and runs it,
`ISO_PLAYGROUND_AUTORUN=all` compiles every project.

History: `examples/*/playground_*` in isomer until 0.15, then a repository
of its own (pinning isomer by commit), back in isomer as `playground/` at
0.35, a demo of what Isomer does.

## The module

| Directory | What |
| --- | --- |
| `apple/` | the iOS app and its embedded-compiler staging scripts, the Mac app, `compiler` (how both build a project: ToolchainCompiler and its backends, the iPhone's in-process compiler), `host` (the Apple host and @main), `platform_services_host` (the services a run gets in WasmView) |
| `android/` | the Android app (Kotlin host: compile, run, chat, the web run), `platform_services` (the services a run gets), the transcript stress app |
| `web/` | the web app, the splash page (the whole site is `//web/splash_web_application:site`), the transcript stress app |
| `linux/`, `windows/` | the desktop apps (built in an oss container on a Mac, and on Windows) |
| `shared/` | `app` (the shell), `compiler` (what every Playground that carries its compiler shares: the build's arguments, the SDK, the build with a compiler carried as files, and that compiler assembled for the app, toolchain.bzl), `desktop_host` (Linux and Windows), `sample_sources` (the templates' sources), `transcript_stress_application` |
| `tools/` | `playground_toolchain` (the iOS and Android compilers), `browser_toolchain` (the compiler as WebAssembly), `playground` (dev compile server, headless Chrome drivers, the site's packaging and the hot-reload publish scripts, template history), `patches` and `signing` (below) |
| `tests/` | `templates` (every template compiles), `e2e` (what a reader does, on an emulator and a simulator), `ios_ui_probe` (a manual XCUITest); the release's proof is isomer's `tools/proof/proof.py` |
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
  them from a checkout that has them. The Mac's and Linux's are not
  staged: Bazel assembles them from the toolchains rules_swift registered
  for wasm32 (shared/compiler/toolchain.bzl: the host toolchain's
  swift-frontend, wasm-ld, macro plugin server and plugins, thinned to
  arm64 on a Mac, and the wasm SDK's sysroot and static stdlib, about
  470 MB: the Mac's Resources, beside the Linux app). Windows has no such
  toolchain in rules_swift; its package takes the build VM's installed
  Swift's (isomer's tools/proof/proof.py does), with the wasm SDK's data
  and the Playground SDK from the Mac. Linux's lld wants Ubuntu 24.04's
  libxml2 and ICU 74, which its package.sh carries in lib/.
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
- **A release's proof** is isomer's `tools/proof/proof.py`: the Storybook
  and the Playground on every platform, each with its one renderer
  (`review-<platform>-storybook`, `review-<platform>-playground`: the review
  server files only `review-` folders; app "Storybook" and "Playground", the
  version `version_name` says). The Playground's: its projects, a project
  open, and 2048 and the Pokédex built on the device and running. Stamp the
  build's version into the working tree first, as CI does
  (`tools/playground/stamp.py 0.38.N` here, the examples'
  `tools/stamp_storybook.py 0.38.N`), and check the files out after. The
  web Playground's compiler is the in-browser one an earlier site staged
  (`--web-toolchain <its playground/toolchain>`). The runs go to the review
  server with the review tooling's `publish_proof` (`bazel run
  //reviews/harnesses:publish_proof -- runs <folder of review-<run>
  folders> --commit <sha>` in the reviews checkout, `REVIEW_SERVER_CODE`
  from `reviews-server code` on its Mac, never on a command line). Reviews
  holds a release until its commit has them. `tests/e2e/run.py` still
  drives what a reader does on an emulator and a simulator before a build
  goes to a phone.
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
