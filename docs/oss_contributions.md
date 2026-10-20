# Planned open-source contributions

Isomer is built on a stack of open Swift/Bazel infrastructure. Where we
need a capability that belongs upstream, we upstream it rather than fork
permanently — consuming a `git_override` on our fork branch only until the PR
merges. This doc tracks the planned and in-flight contributions.

## rules_swift (bazelbuild/rules_swift)

We upstream Swift-SDK cross-compilation support here. Consumed via `git_override`
on upstream `main` (currently `4428a62`) until a release cuts.

| # | Contribution | Status |
|---|---|---|
| — | wasm/Android/Windows/linkshared/SDK-framework cross-compile (#1817–#1821, #1830) | ✅ merged |
| — | Android API-level target triple fix (#1859) | ✅ merged (retired our fork carry) |
| 1 | **`wasm32-unknown-wasip1-threads` variant for `swift.wasm_sdk`** | 🔨 in progress (draft PR) |

**#1 — threads wasm SDK variant.** `swift.wasm_sdk` currently hardcodes the
single-threaded `wasm32-unknown-wasip1` triple and derives the swift.org release
URL. This PR adds a `threads = True` option that selects
`wasm32-unknown-wasip1-threads`, accepts an explicit `url`+`sha256` (swift.org
publishes no threads bundle — the threads SDK comes from swiftwasm releases), and
injects the threads build/link flags into the generated wasm toolchain
(`-matomics -mbulk-memory -mthread-model posix -pthread -ftls-model=local-exec`;
link `--import-memory --export-memory --shared-memory --max-memory=…`). Backwards
compatible (default off). This is what lets `bazel build` produce a threaded
reactor for the wasi-threads parallelism tier (see
[benchmarks.md](benchmarks.md#parallelism-wasi-threads--android-compute-microbenchmark)).
Files: `swift/extensions.bzl` (`_setup_wasm_sdk`, tag attrs),
`swift/internal/extensions/swift_sdks.bzl` (`_swift_wasm_sdk_impl` triple/path),
`swift/internal/extensions/swift_sdk_releases.bzl` (URL override),
`swift/internal/extensions/toolchains.bzl` (threads flags).

## swiftwasm (swiftwasm/swift) — Swift Concurrency on wasi threads

**The big one.** Today, Swift compiled for `wasm32-unknown-wasip1-threads` runs with a
**single-threaded cooperative** global executor: `Task`/`TaskGroup`/`async let`
do NOT fan out across wasi threads by default. Our interim fix is a **custom
`TaskExecutor`** bound over a wasi-threads pool (`WasiThreadPoolExecutor` in the
spike): it correctly dispatches concurrency jobs across N threads (verified
N concurrent jobs in flight), and a background `Task` on the pool keeps the main
thread **fully responsive** (UI-throughput retention ~1.00 under a saturating
background thread — measured, benchmarks.md). That is the property that matters
for apps: heavy work leaves the UI thread free, which single-threaded JS
structurally cannot do.

**But two distinct gaps remain, and they need upstream work:**

1. **Default executor.** The concurrency runtime's default global executor should
   be multithreaded on `wasip1-threads` (like Darwin/libdispatch), so idiomatic
   `async` parallelizes without a custom executor. (The interim executor above
   demonstrates the seam.)
2. **Compute codegen (the deeper one).** Empirically, CPU-bound *Swift* compute
   does **not scale** across wasi threads even with a perfect executor and native
   AOT — an identical pthread harness in the same module measured **C 3.67× vs
   Swift 0.87×** at 4 threads (macOS and Pixel 3a, interp and AOT). Threads run
   concurrently (responsiveness holds), but parallel *throughput* is
   memory-bandwidth-bound — consistent with SwiftWasm codegen keeping hot state
   in the shared linear-memory shadow stack rather than wasm locals/registers,
   so N threads contend on the shared memory bus. C compute (register-resident)
   scales fine, proving the wasi-threads mechanism itself is sound. The upstream
   fix is a **codegen** improvement (promote hot locals to wasm locals; avoid
   per-iteration shared-memory traffic) so Swift parallel throughput matches C.

The upstream fix: teach Swift's concurrency runtime to use a **multithreaded
work-stealing global executor** on `wasip1-threads`, the way it does on Darwin
(libdispatch) and Linux (the cooperative pool built with threading). Concretely:

- Provide a `wasip1-threads` global-executor implementation that spawns a pool of
  wasi threads (`__wasi_thread_spawn`) and enqueues jobs across them, instead of
  the single-threaded cooperative default selected for `-mthread-model single` /
  no-Dispatch wasm builds.
- Wire the runtime's `swift_task_enqueueGlobal` / `swift_task_asyncMainDrainQueue`
  hooks to that pool when built for the threaded triple; keep the cooperative
  executor for the non-threads triple.
- Ensure the concurrency runtime's synchronization (job queues, actor locks) uses
  the atomics the threaded target already enables.

This is the change that makes idiomatic `async`/`await` parallel on wasm "for
free," so app code doesn't have to reach for pthreads or a custom executor. It is
the natural home for the capability our interim custom executor demonstrates.

Scope/sequencing: land the interim custom executor in-tree first (unblocks us),
prototype the runtime executor against a swiftwasm dev snapshot, then propose it
upstream (swiftwasm, and ultimately swiftlang/swift). Related: the WAMR threads
build (`--define wamr_threads=1`, vendored in swift_ffi) and the version-matched
SDK constraint were worked out in a plan outside this repository.

## swift-sdk-generator (swiftlang/swift-sdk-generator) — optional

To keep a single toolchain pin, we may need a **version-matched** threads SDK
built for our exact swift.org release (swiftmodule compatibility is exact-patch;
the public swiftwasm threads SDKs track their own release cadence). If the
generator's threads path needs fixes to emit a `wasip1-threads` SDK for a stock
swift.org toolchain, those go here.
