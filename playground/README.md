# The Playground

Write SwiftUI on your device, build it there, and run it there: one SwiftUI
app on iOS, macOS, Android, the web, Linux and Windows, built on
[Isomer](../README.md). A project is a `.swift` file; Run compiles it to
WebAssembly with a Swift compiler the app carries, and shows the result on
Isomer's SwiftUI. An agent page (AgentUI) can write and fix the project for
you. New projects start from the canned examples: Counter, 2048, Hacker
News, Meme Creator, Pokédex, Date Planner, Map Explorer, Floating Menu, and
"This website".

| | Target | Renderer | Projects (compiler) | A run |
| --- | --- | --- | --- | --- |
| iOS | `//apple/playground_ios_application` | SwiftUI; Metal for runs | swift-frontend and lld linked into the app | WasmView (WasmKit), or Safari |
| macOS | `//apple/playground_macos_application` | SwiftUI | — | WasmView (WasmKit) |
| Android | `//android/playground_android_application` | Compose, OpenGL | swift-frontend and wasm-ld in the APK | its own window (WasmKit), or Chrome |
| Web | `//web/playground_web_application` | React, WebGPU | the compiler as WebAssembly, in a Worker | in the page |
| Linux | `//linux/playground_linux_application` | OpenGL | — | its own window (WasmKit) |
| Windows | `//windows/playground_windows_application` | Direct3D | — | its own window (WasmKit) |

The six apps share one shell (`shared/app`) and the canned examples
(`shared/sample_sources`). Isomer's SwiftUI API is shown and proven by the
Storybook (isomer's `examples/`).

Also here, because it exercises the same agent page (AgentUI on Isomer): the
transcript stress apps, `//web/transcript_stress_web_application` and
`//android/transcript_stress_android_application` (source in
`shared/transcript_stress_application`): a long agent conversation, to see
how a large transcript scrolls and streams. The web app is published with a
front page beside it (`//web/splash_web_application`, the whole site is its
`:site`).

## Build

`playground/` is a Bazel module of its own (`isomer_playground`), which
consumes the parent checkout the way an application consumes isomer, as
`examples/` does: `bazel_dep(name = "isomer")` with a `local_path_override`
on `..`. Run Bazel from here:

```sh
cd playground
# iOS simulator, compiling with the host toolchain
bazel run //apple/playground_ios_application:run
# iOS, onto a phone (installs, does not launch; the compiler must be staged
# first, see below; the Apple team comes from .bazelrc.user, see below)
DEVICE=<udid> apple/playground_ios_application/install_device.sh
# the web site
bazel build -c opt //web/splash_web_application:site
# Android
bazel build -c opt //android/playground_android_application
bazel test //...
```

An iPhone build is signed with your own Apple team: put
`common --repo_env=ISOMER_TEAM_ID=<your team id>` in a `.bazelrc.user` here
(untracked; `tools/signing`). Simulator, web and Android builds need nothing.

The compilers are not in git; they are far too large. They are built once by
`tools/playground_toolchain` (iOS, Android) and `tools/browser_toolchain`
(web), then staged into gitignored directories by
`apple/playground_ios_application/build_embedded_toolchain.sh` and
`android/playground_android_application/stage_toolchain.sh`. Without them the
iOS and Android apps build but cannot compile; the READMEs in those tools
directories are the instructions.

## Where things are

- `docs/playground.md`: the iOS app. `docs/playground_web.md`: the web app,
  the site and publishing.
- `tools/playground`: the web dev compile server, headless Chrome drivers, the
  site's packaging script and the hot-reload publish script.
- `MODULE.bazel` repeats isomer's root-only overrides (bzlmod honours them
  from the root module only), as `examples/MODULE.bazel` does; keep the two in
  step. Outside this repository an application depends on an isomer release
  by version from the project's registry (or a `git_override` of a commit)
  instead of the `local_path_override`.
- `AGENTS.md`: how the module is laid out, built and tested, and its rules.

The web site is https://attilathefun.github.io/isomer/ (the Playground at
`playground/`): `tools/playground/package_site.sh` packages it as
`isomer-site.tar.gz`, which is attached to a GitHub release
(`gh release upload <tag> isomer-site.tar.gz`), and the repository's
`.github/workflows/pages.yml` deploys it to GitHub Pages when the release is
published, or by hand (`docs/playground_web.md`, "Publishing").

This was `examples/{apple,web,android}/playground_*` in this repository until
Isomer 0.15 (tag `v0.14`), then a repository of its own until it came back
here, as `playground/`, at 0.35.
