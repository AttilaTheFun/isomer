# Library evolution off Apple: `--@isomer//:library_evolution`

An app that builds its own Swift libraries with library evolution
(`-enable-library-evolution`: rules_swift's `library_evolution = True` or the
`swift.enable_library_evolution` feature) imports Isomer's Foundation, SwiftUI,
os and the rest, which are built without it. Swift reports each such import
(lib/Sema/ImportResolution.cpp):

    error: module 'SwiftUI' was not compiled with library evolution support;
    using it means binary compatibility for 'MyLibrary' can't be guaranteed

`--@isomer//:library_evolution` (off by default) builds Isomer's modules
resilient, and the report goes. (Foundation, FoundationNetworking,
IsomerFoundation, and on Android and the web CoreGraphics and Combine, are
the Swift SDK's since 0.56: Isomer's SDKs build them resilient whatever the
flag, as an Apple SDK's are, so an app's library can import them publicly
either way; docs/hermetic_toolchains.md.) This page is what it costs, measured on the
Android Storybook, and why it stays a flag.

## The report, exactly

What Swift 6.4.2 (the toolchain Isomer builds with) does with a *public*
import of a module built without library evolution into one built with it,
checked with swiftc directly and with the Storybook's modules:

| The importing library | What Swift reports |
| --- | --- |
| library evolution | a warning |
| ... and `-warnings-as-errors` | still a warning: the diagnostic is declared an error and limited to a warning, and `-warnings-as-errors` doesn't raise it again |
| ... and InternalImportsByDefault (or AccessLevelOnImport) at `-library-level api` or `spi`: a library built for distribution | an **error** |
| `internal import` (or `@_implementationOnly`) of the module | nothing |

The diagnostic has no group (`-print-diagnostic-groups` prints none), so
`-Wwarning <group>` can't name it and nothing turns the error off. So:

- **Library evolution off Apple buys nothing** (README, "Swift features"):
  Isomer's modules are linked into each app, and nothing on Android, the web,
  Linux or Windows swaps a module beneath an app. Turning it off there for
  your own targets (`features = select({"@platforms//os:android":
  ["-swift.enable_library_evolution"], ...})`) is the cheapest way out.
- **An `internal import`** where your library's interface doesn't use the
  module.
- **Not `-library-level api`** off Apple, or not InternalImportsByDefault: a
  warning then, which Swift 6.4's warnings-as-errors leaves alone.
- **`--@isomer//:library_evolution`** when the library is built for
  distribution on those platforms too, its interface uses Isomer's types,
  and it must stay resilient there.

## What the flag does

Two halves, both in tools/library_evolution/defs.bzl:

- **Isomer's Bazel modules** (the Isomer module, the Android and web hosts,
  IsomerGPURenderer, os and OSLog, IsomerNetworkHost, PlatformServices,
  IsomerFFI, SwiftGPU, SwiftMap's engine, Metal, IsomerMetal,
  IsomerMetalWeb) add `LIBRARY_EVOLUTION_COPTS`, a select on the flag.
- **The Swift package's modules** (Foundation, FoundationNetworking,
  IsomerFoundation, CoreGraphics, Combine, IsomerSwiftUI, SwiftUI,
  CoreTransferable, UniformTypeIdentifiers, ImageIO, PhotosUI and the driving
  modules) are rules_swift_package_manager's generated targets, reached only
  through `one_configuration` (foundation/defs.bzl). Its transition, with the
  flag on, adds rules_swift's per-module copts
  (`--@rules_swift//swift:per_module_swiftcopt=<label>=-enable-library-evolution`)
  for each package target, by its canonical label
  (`@@rules_swift_package_manager++swift_deps+swiftpkg_isomer//:SwiftUI.rspm.__impl`).

Not the `swift.enable_library_evolution` feature: isomer's REPO.bazel and
one_configuration keep a consumer's features off Isomer, and the feature would
make swift-foundation, its collections and SwiftProtobuf resilient too, which
no app imports. With the flag off nothing changes: the configurations are
main's (the Storybook's modules' configuration ids are the same), so the
cache's entries still apply.

`--config=isomer_library_evolution` in examples/.bazelrc is now this flag. It
was a list of per-module copts by Bazel label, written before Foundation and
SwiftUI moved into isomer's Swift package (0.43, 0.44): its labels for those
named `one_configuration` wrappers and `swift_library_group`s, which compile
nothing, so Foundation, SwiftUI, PhotosUI and ImageIO stayed fragile under
it (and IsomerAndroidHost and IsomerGPURenderer weren't listed).

examples' `//tests/library_evolution:library_evolution_test` builds a library
for distribution (library evolution, warnings as errors, InternalImportsByDefault,
`-library-level api`) that publicly imports Combine, CoreGraphics,
CoreTransferable, Foundation, FoundationNetworking, Isomer, Observation, os,
OSLog, PhotosUI, SwiftUI and UniformTypeIdentifiers, for Android and the web,
with the flag on. Without the flag the same library fails with the error
above on every one of those imports but Observation (the toolchain's,
resilient already).

## Measurements (2026-11-15)

The Android Storybook (`//android/storybook_android_application:storybook_android_application_apk`,
`-c opt --config=alpha --config=ci_device`, arm64), built twice in a
Shireworks container (4 CPUs, 8 GB): as it is, and with every one of
Isomer's 22 modules the app links resilient (12 of the package's, 10 of
the Bazel module's; checked in each compile's command line with `bazel
aquery`). The flag's build is the second, byte for byte in size.

### Size

| | as it is | resilient | change |
| --- | ---: | ---: | ---: |
| `libstorybook_android_application_runtime_bindings.so` | 35,103,768 B | 36,041,584 B | +937,816 B (+2.7%) |
| its `.text` | 12,731,860 B | 13,021,932 B | +290,072 B (+2.3%) |
| its `.eh_frame` | 1,604,316 B | 1,643,740 B | +39,424 B |
| its `swift5_typeref` | 178,287 B | 203,951 B | +25,664 B |
| the .so compressed in the APK | 10,100,459 B | 10,266,676 B | +166,217 B (+1.6%) |
| the APK | 19,343,203 B | 19,507,043 B | +163,840 B (+0.85%) |
| dispatch thunks (`…Tj`) | 736 | 1,444 | +708 |
| method lookup functions (`…Mu`) | 30 | 109 | +79 |

### Build

Every Swift compile and link done in the container (the rest from the
cache), after a `bazel clean`:

| | as it is | resilient |
| --- | ---: | ---: |
| the APK's build, wall | 318 s (326 s) | 360 s (334 s) |
| critical path | 255 s | 290 s |
| SwiftUI's compile | 23.0 s | 25.3 s |
| Foundation's compile | 7.1 s | 8.8 s |

(In brackets the first pair, whose baseline had some actions in Bazel's own
cache.) Nothing failed to build resilient: all 22 modules compile. They warn
(none of these warnings in a module built with warnings as errors) where
they publicly import what stays fragile beneath them (FoundationEssentials,
Dispatch, SwiftProtobuf, the wire protos' Swift), and where a Swift 5
module switches exhaustively over another Isomer module's enum that is now
resilient (`@unknown default` wanted).

### Frames

On a Shireworks Android emulator (API 35, 1080×2400, 4 vCPUs), each APK
installed in turn, the order alternating each round, the same steps every
run (a shell script on the device, driven over `sw machine adb`):

- **the story walk**: 41 stories opened in turn through `iso://story/<id>`
  (no network content, nothing animating forever), 1.5 s each;
- **the scroll**: the list of stories, six swipes up and six down;
- **startup**: `am start -W`'s TotalTime, cold.

Android's frames (`dumpsys gfxinfo <package> framestats`, dumped after
each step so none falls out of its window; frames with flags left out), 6
runs of each, pooled:

| | as it is | resilient |
| --- | ---: | ---: |
| walk: frames | 504 | 504 |
| walk: frame time, median / p95 / p99 | 17.5 / 35.9 / 74.4 ms | 17.5 / 36.6 / 56.3 ms |
| walk: UI thread, median / p95 / p99 | 5.7 / 16.5 / 30.2 ms | 5.6 / 16.3 / 30.8 ms |
| scroll: frames | 4,250 | 4,575 |
| scroll: frame time, median / p95 / p99 | 17.3 / 44.8 / 102.2 ms | 17.3 / 28.3 / 53.9 ms |
| scroll: UI thread, median / p95 / p99 | 1.3 / 6.9 / 25.5 ms | 1.2 / 5.1 / 11.7 ms |
| startup, median (6 runs) | 247 ms | 253 ms |

Swift's own work per frame, the runtime's `iso:render` trace section
(`SwiftUIBridge.nativeRender`), under atrace across the same walk and scroll,
5 runs of each:

| | as it is | resilient |
| --- | ---: | ---: |
| frames rendered | 865 | 865 |
| `iso:render`, median / p95 / p99 | 2.24 / 4.28 / 8.31 ms | 1.95 / 4.00 / 5.89 ms |
| per run, median of the medians | 1.94 ms | 1.94 ms |
| per run, summed (median of the runs) | 424 ms | 430 ms |
| startup, median (5 runs) | 235 ms | 235 ms |

No difference shows: the medians agree, and the tails differ by which runs
an emulator on a shared machine disturbed (the as-it-is scroll's p99 is one
such run). Resilience costs a call through a thunk, or a size read at run
time, where code crosses into a resilient module for something it would
have inlined; a frame of the Storybook's spends a couple of milliseconds in
Swift, and Compose's work and the emulator's drawing set its time. An app
with heavier Swift per frame would see more than this does.

The stories render the same: seven pages pictured both ways (the list,
gradients, grid, Markdown text, pickers, sections, an `@Observable`) are
byte-identical PNGs.

## Why a flag, off

- It costs size (+2.7% of the app's library, +0.85% of the APK) and build
  time (about a tenth more for an optimized build), and frames the
  Storybook couldn't measure, for a guarantee nothing off Apple uses.
- On, it changes what app code must write: an exhaustive `switch` over an
  Isomer enum then wants `@unknown default` (a warning, an error in Swift 6
  mode), as Apple's SwiftUI enums already do but Isomer's own (`JSONValue`,
  the transports' events) haven't.
- Off, nothing changes for anyone, and the cache stays shared.

It would be worth a default only if Isomer promised a stable binary interface
from one build to the next, so that a library built against one build of
Isomer could run against another (README's prebuilt library beside the app,
TODO.md); it doesn't, and resilience alone wouldn't give that.
