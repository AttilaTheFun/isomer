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

- **AOT-compile wasm reactors under WAMR — mostly DONE.** `//:wamrc` builds from
  hermetic-llvm (LLVM 22) on macOS **and Linux** hosts; `--define wamr_aot=1`
  compiles the AOT loader into `@wamr` on every platform (including MSVC), and
  `wasm_runtime_load()` dispatches on magic bytes. Measured cold start on the
  greeter reactor: macOS ~10x (266→30 ms), Linux ~8x (273→35 ms). Remaining:
  - **Windows .aot loading works, but needs `--size-level=0`.** A msvc-ABI
    .aot cross-produced with `wamrc --target=x86_64 --target-abi=msvc
    --size-level=0` (large code model — no 32-bit absolute relocations) loads
    and runs on Windows; verified with the greeter reactor. At the default
    size level the load fails (`IMAGE_REL_AMD64_ADDR32` truncation — the
    Windows loader can't place a ~25 MB SwiftWasm .aot in the low 2 GB the
    32-bit relocs need, and `--size-level=1` didn't resolve it either).
    Remaining: size-level=0 makes wamrc dramatically slower on big reactors
    (~25 min vs ~1.5 min for a 10 MB module) and the .aot a bit larger —
    either WAMR's Windows `os_mmap` low-address strategy gets fixed upstream
    (unlocking the default size level) or the release pipeline eats the
    compile time.
  - **wamrc on a Windows host** is deliberately out of scope (LLVM-from-source
    under MSVC); Windows .aot files are cross-produced.
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
- **A cleaner prebuilt-reactor story.** The Windows wasm cell commits a ~10 MB
  `greeter_reactor.wasm` because the SwiftWasm cross-compile toolchain isn't
  registered on Windows. Prefer cross-building it on Linux CI and fetching it (or
  a hot-reload path) over committing a binary blob.

## Runtime & generator

- **c-host generator parity.** The `c-host-wasm` generator skips `@ExportedStruct`,
  `async`, and interface-returning functions (they're listed in a header comment);
  the Swift host supports them. Close the gap so a C host reaches the full greeter
  surface — struct marshalling is straightforward; async needs a C-side pump.
- **Multiple reactors per process in the WAMR c-host.** `swift_ffi_wamr` currently
  assumes one reactor per process (the `swift_ffi` native table is registered
  globally). Support several concurrent reactors for hosts that load more than one
  module.

## Example matrix

Fill the remaining `example_<platform>_<mode>_application` cells (see the matrix
in README.md):

- **macOS** — both modes: a `macos_application` compiled cell, and a native-Swift
  wasm cell over the swift-host bindings (`//swift_ffi/examples/shared/greeter_host`) plus
  an embedded engine.
- **Android / iOS wasm cells** — run the reactor on-device under WAMR (Android
  via a JNI shim; iOS via the C host or a Swift host), the mobile peers of the
  Linux/Windows wasm cells.

## Bridge surface

- Optionals and arrays/dictionaries of bridgeable types.
- Typed error payloads (errors currently cross as their message string only).
- Timer support for the wasm cooperative executor
  (`swift_task_enqueueGlobalWithDelay_hook`).
- Effectful interface methods (async / throwing), today allowed only on free
  functions.
- Idiomatic Apple/Linux/Windows consumer surfaces beyond the raw C header.
