# TODO

The Playground's own open items (they left isomer's TODO.md with it at 0.15;
isomer's docs/open_items.md is the framework's list).

## Toolchain

- **Package the in-app Swift compiler as a reusable Swift package /
  framework.** Everything that makes `swift-frontend` + `lld` run inside
  an iOS app (tools/playground_toolchain: the cross-compile campaign, the
  idempotent-init and signal-handler re-entry patches, the swift-syntax +
  in-process macro plugin server, the short-named embedded frameworks,
  the `iso_swiftc_main` / `iso_wasm_ld_main` entry shims, WASI sysroot +
  static stdlib data) currently lives in
  apple/playground_ios_application. Extract it into an
  `EmbeddedSwiftCompiler` package (xcframework of the static compiler libs
  + the framework set + a resource bundle for the sysroot, with a Swift
  API: compile(sources:) → wasm / diagnostics, parse-only check) so other
  apps can compile Swift to wasm on device without repeating the campaign.
  See docs/playground.md ("Device packaging") for the constraints the
  package has to preserve.

- **A standalone bundle-building kit for hot reloaders.** Publishing a
  version for a Playground hot reloader (`tools/playground/publish_hot_reload.sh`)
  needs a wasm bundle, and building one today means the Playground's own
  in-app toolchain or the Bazel tree. Neither the wasi-threads fork nor the
  isomer sources are required: the inputs are the swift.org toolchain
  (Xcode's Swift has no wasm backend), the public swiftwasm SDK
  (sysroot + static stdlib), and Isomer compiled for wasm as prebuilt
  swiftmodules/archives plus the link recipe (reactor entry, exports,
  16 MiB stack, whole-archive) — the same three pieces the Playground embeds.
  Package them as a downloadable kit with a `build_bundle.sh` that runs the
  Playground's two compile/link invocations, so a remote Claude Code / Codex
  session goes from `App.swift` to a published version with only that
  download. Prerequisite once public: codify the tree wire format
  (tree.fbs Patches) and the `iso_hot` export ABI with versioning, since a
  bundle must match the framework revision of the Playground it targets
  (today: the Playground's SDK stamp); the kit should carry that revision.

## Playground unification

Done in 0.38: one shell, `shared/app`, on all six platforms (the agent
session, transcript, composer, editor, run cover, settings and project
store shared; the host's `PlaygroundHostService` does the platform's part).
What the iPhone app had before and the shared agent doesn't yet:

- Anthropic keys used directly (it speaks OpenRouter only now).
- Streamed replies (the host's `chat` answers whole).
- Images in a message, and multi-file projects.
- The agent's screenshot, crash-log and web-search tools.
- The model catalog sheet.

## Playground agent

- More injected services beyond those in isomer's `shared/platform_services`
  (keychain, OAuth, timers, analytics, configuration, the image picker,
  device motion; the network and files are Foundation's since 0.31):
  location, camera/photos, notifications — each a swift_ffi interface
  implemented by every host and described to the agent in the system prompt.
- swift_ffi: async interface methods on Swift-OWNED instances are callable
  from wasm/TS consumers only (they complete through `async_complete`);
  Kotlin/Swift-host callers and C++/Rust consumers still get a runtime
  error for them.
