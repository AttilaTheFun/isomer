# AGENTS.md — swift_ffi

> **Part of the isomer repository since 2026-10-02.** This was a repository
> and Bazel module of its own; it is now the `swift_ffi/` directory of the one
> `isomer` module. Labels are `//swift_ffi/...` from the repository root
> (`@isomer//swift_ffi/...` from another module), dependencies and toolchains are in
> the root `MODULE.bazel`/`.bazelrc`, and a consumer pins isomer, not this.
> Where the text below says "this repo", read "this directory"; the layering
> rule is unchanged (nothing here depends on anything outside `swift_ffi/`).

Operating context for AI agents working in this repo. Last updated
2026-07-19. If anything here (or in docs/) contradicts the code, trust the
code and update the doc.

## Read this first

Almost everything you need is in the human-facing docs — don't rediscover it:

- [README.md](README.md) — what the project is, the consumer surface.
- [docs/structure.md](../docs/swift_ffi/structure.md) — the map: every target, the
  pipeline, where a change starts. **Start here before editing.**
- [docs/types.md](../docs/swift_ffi/types.md) / [docs/ownership.md](../docs/swift_ffi/ownership.md) —
  the bridge contract. Generated-shape constraints marked "do not simplify"
  are load-bearing; regressions surface only at runtime.
- [docs/toolchains.md](../docs/swift_ffi/toolchains.md) — pins and build gotchas
  (`SwiftCompile=local`, ts_project-from-consumer-repo, stale outputs, …).
- [docs/examples.md](../docs/swift_ffi/examples.md) — the matrix and what each cell
  verifies.

## Conventions this repo holds you to

- **Commit straight to `main`** — no feature branches. swift_gpu, swift_map
  and the SwiftUI libraries build against this directory in the same commit,
  so a change here and its fixes above land together.
- **Idiomatic output is the product.** Generated Kotlin/TS must look
  hand-written — real types, `use`/`using` support, no C-isms leaking. Judge
  generator changes by reading the emitted source, not just by green tests.
- **Keep the docs in sync with the emitters.** The bridgeable-type tables
  (README + docs/types.md) and the generator encode the same contract; a
  surface change updates both in the same commit. Same for
  `MODULE.bazel`/`.bazelrc` comments — they are the authoritative rationale
  for every pin; preserve and update them, and let docs/toolchains.md follow.
- **Hermetic everywhere except Apple's local Xcode.** Never reach for a host
  JDK, Node, or `ANDROID_HOME`; if a tool is missing, it belongs in
  MODULE.bazel.

## Verifying your work

- `bazel test //swift_ffi/...` — plugin, analyzer, and generator suites.
  Generator tests assert on emitted text; intentional output changes mean
  updating expectations, not weakening assertions.
- Build the affected example cells; run the runnable ones for your host OS
  (macOS: web + android + ios; the desktop wasm/compiled cells need their
  own OS). BUILD files are maintained by hand (the gazelle setup did not
  come along in the fold).
- Warnings are errors for swift_ffi's code (the `package(features = …)` at
  the top of every BUILD file here, which a new package must carry too);
  don't suppress — fix.
