# AGENTS.md — the Playground (isomer/playground)

Context for AI agents (and new humans) working on the Playground. README.md
says what it is and where things are; the parent checkout's AGENTS.md is
Isomer's own guide. If something here contradicts the code, trust the code
and update this file.

## What it is

The Playground apps: write SwiftUI on the device, build it there with a
Swift compiler the app carries, run it on Isomer. One app on iOS
(`apple/playground_ios_application`), the web (`web/playground_web_application`,
with the site's front page in `web/splash_web_application`) and Android
(`android/playground_android_application`). Their screens are one SwiftUI
source (`shared/playground_ui`, and the web app's Swift, which Android
compiles too), built against Apple's SwiftUI on iOS and Isomer's elsewhere.
The transcript stress apps (`shared/transcript_stress_application`, web and
Android) are here because they exercise the same agent page (AgentUI).

History: `examples/*/playground_*` in isomer until 0.15, then a repository
of its own (pinning isomer by commit), back in isomer as `playground/` at
0.35, a demo of what Isomer does.

## The module

| Directory | What |
| --- | --- |
| `apple/` | the iOS app, its embedded-compiler staging scripts, `platform_services_host` (the services a run gets in WasmView) |
| `android/` | the Android app (Kotlin host: compile, run, chat, the web run), `platform_services` (the services a run gets), the transcript stress app |
| `web/` | the web Playground, the splash page (the whole site is `//web/splash_web_application:site`), the transcript stress app |
| `shared/` | `playground_ui` (the shared screens), `sample_sources` (the templates' sources), `transcript_stress_application` |
| `tools/` | `playground_toolchain` (the iOS and Android compilers), `browser_toolchain` (the compiler as WebAssembly), `playground` (dev compile server, headless Chrome drivers, the site's packaging and the hot-reload publish scripts, template history), `patches` and `signing` (below) |
| `tests/` | `templates` (every template compiles), `e2e` (what a reader does, on an emulator and a simulator), `ios_ui_probe` (a manual XCUITest) |
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

- **iOS**: in-process under `WasmView`, on the Apple host's default engine
  (WAMR's interpreter; `WasmViewModel.playground()` takes it from
  `WasmRuntimeRegistry`), drawn by the SwiftUI tree renderer or, by the
  Settings choice, SwiftGPU over Metal; or in Safari ("Run on the web").
- **Android**: in its own window and process (`RunActivity`, `:run`) under
  the Android WasmView, WAMR's interpreter; or in a Chrome tab.
- **Web**: in the page, on the browser's own WebAssembly engine.
