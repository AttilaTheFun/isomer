# Isomer's Swift SDKs (0.56)

Isomer's Foundation built into the Swift SDKs themselves, so that every
`import Foundation` on Android and the web is Isomer's: an app's own Swift,
a Swift package's, a Bazel module's, with no `@isomer//:foundation` edge
anywhere and no corelibs Foundation beside it. A consumer registers them
with one line a platform, in the `swift` block it already has (README,
"Isomer's Swift SDKs").

## Why

Until 0.56 every library that imported Foundation on Android or the web had
to depend on `@isomer//:foundation` (a Swift package through
`configure_package(target_deps = …)`), or it found the Swift SDK's corelibs
Foundation, which linked beside Isomer's: duplicate symbols, or (on Android)
OpenSSL's symbols undefined, since corelibs' FoundationNetworking needs
them. Every package an app took needed that edge declared, and a package
nobody declared failed late. With the SDK's Foundation being Isomer's,
nothing needs declaring.

## The spike (2026-11-15)

Android arm64, swift.org's 6.4.2 SDK, in a leased container: corelibs
Foundation, CoreFoundation, curl, libxml2 and OpenSSL taken out, Isomer's
Foundation family put in, the SDK registered with rules_swift as any other.
A plain library that only imports Foundation, a SwiftProtobuf user with its
Foundation edge removed, and the Android Storybook each linked exactly one
Foundation, Isomer's. The SDK's static libraries went from 208 MB to 144 MB.
What it taught:

- **Autolink entries are fixed when the importing module compiles.** A
  module's object records the libraries its imports name, by their link
  names at that moment; a link directive added afterwards changes nothing.
  So the family is compiled with `-module-link-name` for every module, and
  the helpers no client imports are folded into the archives clients do
  autolink: swift-collections and the C shims into FoundationEssentials',
  IsomerFoundation, IsomerDispatchTime and (on wasm) CWasiThreadIdentity
  into Foundation's. swift.org's SDK does the same with swift-collections
  (`_FoundationCollections`).
- **A module imported internally autolinks nothing for its clients.**
  FoundationInternationalization imports ICU (`_FoundationICU`) internally,
  so it asks its clients for it by `-public-autolink-library`, as
  swift-foundation's CMake build does.
- **One object a module.** A static archive's member is linked only when a
  symbol in it is wanted, and a file of conformances alone defines nothing a
  client names: Foundation's NSNumberBridging.swift (Swift's numbers
  bridging to NSNumber, which `json["n"] as? Int` needs) was dropped, and
  the cast failed. So each Swift module is compiled whole into one object
  (`-num-threads 0`): a module linked at all is linked whole, as Bazel links
  a library built from source, and `--gc-sections` still drops what
  nothing reaches. (Not objects merged by `ld -r` afterwards: wasm-ld's
  loses the retain flag on Swift's metadata, which the final link then
  collects.)
- **rules_swift took an Android SDK by checksum only**, its URL
  download.swift.org's. rules_swift#2012 adds `url` (below).

## The repository

[AttilaTheFun/isomer_hermetic_toolchains](https://github.com/AttilaTheFun/isomer_hermetic_toolchains),
a fork of swiftlang/swift-foundation, public. A branch per Swift release,
`isomer-<version>` (`isomer-6.4.2` first): swift-foundation's release tag,
then Isomer's patches as commits (those isomer applied to swift-foundation
until 0.56: #2409's createDirectory at the root, the SDK's ICU linked by name
and Android's fts_open, `package` on the Essentials helpers Isomer's
Foundation searches strings with, Apple's signatures where swift-foundation's
differ), then Isomer's additions, rebased onto each new release.

On that branch, beside swift-foundation's sources:

- `Isomer/Sources`: what Isomer adds to Foundation (isomer's `foundation/`
  until 0.56: the classic-Foundation layer, URLSession over the host's
  transports, Bundle's strings, UserDefaults, …), and the modules an SDK
  carries with it: FoundationNetworking, IsomerFoundation, CoreGraphics,
  Combine, IsomerDispatchTime, IsomerFoundationInternationalization. Their
  targets follow swift-foundation's in its Package.swift, so a release's
  manifest rebases under them.
- `sdk/build.sh <sdk>`: swift.org's SDK for the target, corelibs Foundation
  out, the family in, built `-c release` by SwiftPM in a Linux container;
  then a client package built against the result and checked: what `import
  Foundation` autolinks, that the program has Isomer's Foundation and
  nothing of corelibs', that a resilient library at `-library-level api`
  can publicly import Foundation, CoreGraphics and Combine, and on wasm the
  program and two swift-testing tests run under the toolchain's WasmKit.
  Reproducible: the same bundle from any checkout, its file times those of
  the last commit to what goes into it.
- `.github/workflows/isomer_sdk.yml`: the four SDKs built on each push to an
  `isomer-*` branch, and on an `isomer-*` tag a draft release with them,
  their `.sha256` files, and notes giving the consumer's lines.

## The SDKs

Each a swift.org 6.4.2 SDK with the family switched in, in two variants:

| | plain | -i18n |
| --- | --- | --- |
| Android (aarch64, x86_64, armv7) | `swift-6.4.2-RELEASE_android.artifactbundle.tar.gz` | `swift-6.4.2-RELEASE_android-i18n.artifactbundle.tar.gz` |
| WebAssembly (wasm32-unknown-wasip1) | `swift-6.4.2-RELEASE_wasm.artifactbundle.tar.gz` | `swift-6.4.2-RELEASE_wasm-i18n.artifactbundle.tar.gz` |

released as `isomer-6.4.2.N` (from .1), at
`https://github.com/AttilaTheFun/isomer_hermetic_toolchains/releases/download/isomer-6.4.2.N/<name>`.

- **Plain**: Foundation without FoundationInternationalization, and no ICU
  linked: `Calendar`'s symbols English, formatting and parsing absent, as
  isomer's Foundation was without `--@isomer//foundation:internationalization`.
- **-i18n**: Foundation re-exports FoundationInternationalization, which
  links the SDK's own ICU (`lib_FoundationICU.a`, swift.org's): dates,
  numbers, lists and measurements formatted as on Apple's platforms. ICU's
  data is tens of megabytes of an app; on the web `isomer_web_app(icu_locales
  = [...])` keeps only the languages named (tools/wasm/icu_data, as before:
  it trims the data the link reads from the SDK's ICU), and ICU_DROP leaves
  out the legacy converters and the CJK word dictionaries.
- **Resilient**: Isomer's own modules in the SDKs (Foundation,
  FoundationNetworking, IsomerFoundation, CoreGraphics, Combine) are built
  with library evolution, as an Apple SDK's Foundation is, so an app's
  library built for distribution can import them publicly
  (docs/library_evolution.md measured no frame time and about 3% of the
  library for all of Isomer's modules). swift-foundation's own modules stay
  as upstream builds them.
- **Not in them**: XCTest on wasm (corelibs XCTest is built on corelibs
  Foundation; swift-testing stays, over this Foundation), corelibs'
  FoundationXML, and, on Android, curl, libxml2 and OpenSSL, which only
  corelibs' FoundationNetworking used. The Android SDKs' dynamic resources
  stay swift.org's: rules_swift links Swift statically.

## What a consumer writes

One snippet a platform, each standing alone, in place of
`swift.android_sdk()` and `swift.wasm_sdk()` (README, "Isomer's Swift SDKs",
has them with their checksums):

```starlark
# If you build for Android:
swift.android_sdk(
    url = "https://github.com/AttilaTheFun/isomer_hermetic_toolchains/releases/download/isomer-6.4.2.1/swift-6.4.2-RELEASE_android.artifactbundle.tar.gz",
    sha256 = "…",
)
# If you build for the web:
swift.wasm_sdk(
    url = "https://github.com/AttilaTheFun/isomer_hermetic_toolchains/releases/download/isomer-6.4.2.1/swift-6.4.2-RELEASE_wasm.artifactbundle.tar.gz",
    sha256 = "…",
)
```

and the `-i18n` URL (with its own sha256) if the app formats dates or
numbers. An app that builds for Android alone registers no wasm SDK.

After changing an SDK's URL (or upgrading Isomer or rules_swift), a build
that kept its output base may report a module "defined in both" (`module
'_Builtin_stddef' is defined in both '…/_swift_module_cache/…' and '…'`):
`bazel clean` once. Android and wasm compiles build their Clang modules
implicitly, into a module cache Bazel keeps across builds a configuration
each, and the modules cached before the change still name the old build of
one the new SDK builds again. A clean build, as CI's are, never sees it.
rules_swift#2016 is where a cache keyed by the SDK is being discussed.

`swift.wasm_sdk` takes `url` through rules_swift#1860 (a patch of the
registry's rules_swift 4.3.0.isomer.1) and `swift.android_sdk` through
rules_swift#2012 (in rules_swift 4.3.0; generic: any Swift SDK artifact bundle
at any URL); isomer asks for 4.3.0.isomer.1, and MVS gives it every
consumer.

## isomer after the move

- **Package.swift**: no Foundation, FoundationNetworking or IsomerFoundation
  target, and no swift-foundation dependency: no target depends on a
  Foundation, and `import Foundation` is the SDK's. CoreGraphics and Combine
  stay, for Linux and Windows only, whose Foundation is still the
  toolchain's corelibs.
- **`@isomer//:foundation` and `@isomer//:isomer_foundation`** stay as empty
  dependencies, so BUILD files and `target_deps` that name them keep
  working; isomer's own `configure_package(target_deps = …)` for Foundation
  (SwiftProtobuf's, swift-foundation's patches, FoundationInternationalization's)
  are gone, as are the examples'. `//core_graphics` and `//frameworks/combine`
  are nothing on Android and the web (the SDK's) and the package's elsewhere.
- **`foundation/`'s sources moved** to isomer_hermetic_toolchains'
  `Isomer/Sources`, the one copy Android and the web build from.
  `core_graphics/` and `frameworks/combine/` stay here for Linux and Windows
  (the SDK has a copy of each: a change goes to both until those platforms'
  SDKs carry them), and so does FileWrapper.swift
  (`shared/swift_ui_corelibs`), compiled into Linux's and Windows' SwiftUI.
- **`--@isomer//foundation:internationalization`** stays: on Android and the
  web it checks that the SDK registered is the -i18n one (a module that
  compiles only against it, foundation/internationalization), so a build
  that asks for internationalization can't quietly get the plain SDK.
  Nothing else follows it any more: the SDK chosen decides.
- **Foundation's tests** (`foundation/tests`, `frameworks/combine/tests`,
  `core_graphics/tests`) build against the SDK's modules: isomer's own
  module registers the -i18n SDKs (so the internationalization checks and
  ICU's trimming run), the examples the plain ones (as the Storybook and
  most apps use).
- **tools/parity** reads Foundation, CoreGraphics and Combine on the web from
  the SDK (swift-symbolgraph-extract, as Observation's), and classes a
  declaration of swift-foundation's by its module where the SDK's modules
  carry no source locations.

## Later

- **Linux and Windows SDKs**, which use corelibs Foundation today: their
  hosts and their Foundation tests move to Isomer's, and isomer's
  `core_graphics/`, `frameworks/combine/` and FileWrapper.swift go with them.
- **A Bazel module with one line**, `isomer_hermetic_toolchains`, once the
  SDKs are more than two: its SDKs by URL and checksum and their
  registration, and Apple's platforms through rules_applecross's toolchains
  (Xcode's SDKs from an archive, its actool, ibtool and codesign), so that
  swapping that line for apple_support's local Xcode toolchain builds the
  same apps with no other change. rules_swift's `swift` extension takes its
  tags from the root module only, so until then the consumer's own block
  registers the SDKs.
- **The threads SDK** follows Swift 6.5 (TODO.md, "wasi-threads").
- **swift-collections inside the SDK under its own module names**: an app
  that builds swift-collections itself would see two. Private names in the
  SDK (as swift.org's `_FoundationCollections`) are the likely answer.
