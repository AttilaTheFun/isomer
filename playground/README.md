# Playground

Write SwiftUI on the device, build it there, run it there. A project is one
or more `.swift` files; Run compiles them to WebAssembly with a Swift compiler
the app carries, and shows the result on [Isomer](../README.md)'s SwiftUI.
An agent page (AgentUI) can write and fix the project for you.

It lives in the isomer repository as a demo of what Isomer does: one SwiftUI
source for the app's own screens on iOS (Apple's SwiftUI), the web and
Android (Isomer's), a Swift compiler built for each of them, and user code
run on Isomer's wasm hosts.

| | Target | Compiler | Runs a build |
| --- | --- | --- | --- |
| iOS | `//apple/playground_ios_application` | swift-frontend and lld linked into the app | natively in the app (WasmView), or in Safari |
| Web | `//web/playground_web_application` | the same compiler as WebAssembly, in a Worker | in the page |
| Android | `//android/playground_android_application` | swift-frontend and wasm-ld as native executables in the APK | in the app (Compose), or in a Chrome tab |

The three apps share their screens (`shared/playground_ui`) and their sample
projects (`shared/sample_sources`, the example apps' own sources).

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
  step. Outside this repository an application swaps the
  `local_path_override` for a `git_override` of isomer's commit.
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
