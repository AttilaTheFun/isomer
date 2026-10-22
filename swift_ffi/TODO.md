# TODO

Planned work for swift_ffi, roughly grouped — a place to capture direction, not
a commitment or a schedule. Loosely, the path to a clean first open-source
release, then the deeper technical roadmap.

## Open-source readiness

- **LICENSE — DONE.** Apache-2.0 (LICENSE + NOTICE).
- **Make the repo public** and drop the remaining "private" framing.
- **CI (GitHub Actions).** Build and test the examples on a platform matrix —
  Linux (swift.org toolchain), macOS (Xcode), Windows (swift.org) — so pushes are
  gated. This is also what forces the hermetic-toolchain and test work below.
- **Consumer quickstart — DONE.** README's "Getting started" is the
  MODULE.bazel + annotate + wrap walkthrough; docs/examples.md is the working
  reference.
- **CONTRIBUTING.md** — mostly superseded by the docs/ split (structure.md,
  toolchains.md, examples.md carry the operational content). Remaining: a thin
  CONTRIBUTING.md pointing at those, plus PR expectations, once the repo is
  public.
- **Publish to a registry** (BCR or a private one) so consumers use a plain
  `bazel_dep` instead of a `git_override` commit pin. Also swap the `rules_swift`
  git_override for a plain `bazel_dep` at the next rules_swift release (see
  MODULE.bazel).
- **Lockfile policy.** Decide whether `MODULE.bazel.lock` is committed and keep it
  clean/reproducible — right now overrides churn it. Pin it (and enforce in CI)
  or `.gitignore` it, but be consistent.

## Testing

- **Automated test suite — unit half DONE.** The analyzer, generator, and
  macro plugin now have real unit suites (`bazel test //swift_ffi/...`:
  analyzer source→IR including `any` canonicalization and Result unwrapping;
  every generator backend pinned on a fixture module; macro expansion +
  diagnostics via SwiftSyntaxMacrosTestSupport). Still open: c-host and
  swift-host round-trip tests over a real reactor, and CI-gating the examples.
- **Un-gate the examples from macOS/arm64.** The Android emulator and Electron are
  pinned to macOS/arm64, so the android/web cells only run there. Wire Linux
  (and where possible Windows) hermetic toolchains so those cells run in CI and
  for non-Mac contributors.

## Toolchain & build

- **A proper hermetic Electron app rule.** The current web example driver
  (`examples/web/example_web_wasm_application` — a `sh_binary` + `main.js` +
  `//tools:electron.bzl`) is a bring-up hack that only exists to run the example.
  Replace it with a real, reusable rule that packages a bundled web app into a
  hermetic Electron shell — something a consumer could use for their own app, not
  just the greeter.
- **Shrink the wasm reactor.** Swift wasm reactors are large (~10 MB for the
  greeter). Add a size pass (`wasm-opt -Oz`, dead-export stripping once the
  export set is known) so the deliverable — and the committed prebuilt below — is
  smaller.

## Runtime & generator

- **c-host generator parity.** The `c-host-wasm` generator skips `@ExportedStruct`,
  `async`, and interface-returning functions (they're listed in a header comment);
  the Swift host supports them. Close the gap so a C host reaches the full greeter
  surface — struct marshalling is straightforward; async needs a C-side pump.

## Example matrix

Fill the remaining `example_<platform>_<mode>_application` cells (see the matrix
in README.md):

- **Native wasm cells** — a native-Swift host over the swift-host bindings
  (`//swift_ffi/examples/shared/greeter_host`) and WasmKit, on macOS, Linux,
  Windows, Android and iOS. The C-host Linux/Windows wasm cells ran the
  reactor under WAMR (`//swift_ffi/runtime/c_host_wamr`) and were removed
  with it in 0.38 (WasmKit has no C API).
- **macOS compiled cell** — a `macos_application`.

## Bridge surface

- Optionals and arrays/dictionaries of bridgeable types.
- Typed error payloads (errors currently cross as their message string only).
- Timer support for the wasm cooperative executor
  (`swift_task_enqueueGlobalWithDelay_hook`).
- Effectful interface methods (async / throwing), today allowed only on free
  functions.
- Idiomatic Apple/Linux/Windows consumer surfaces beyond the raw C header.
