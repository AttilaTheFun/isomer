# Isomer's hermetic toolchains (0.55)

Isomer's Foundation built into the Swift SDKs themselves, so that every
`import Foundation` off Apple's platforms is Isomer's: an app's own Swift,
a Swift package's, a Bazel module's, with no `@isomer//:foundation` edge
anywhere and no corelibs Foundation beside it. One line of a consumer's
MODULE.bazel chooses the toolchains; for Apple's platforms that line can be
Xcode's instead, and the same apps build.

## Why

Today every library that imports Foundation on Android or the web must
depend on `@isomer//:foundation` (a Swift package through
`configure_package(target_deps = …)`), or it finds the Swift SDK's corelibs
Foundation, which links beside Isomer's: duplicate symbols, or (on Android)
OpenSSL's symbols undefined, since the SDK's FoundationNetworking needs
them. Every package an app takes needs that edge declared for it, and a
package nobody declared fails late. With the SDK's Foundation being
Isomer's, nothing needs declaring.

## The spike (2026-11-15)

Android arm64, swift.org's 6.4.2 SDK, in a leased container
(/tmp/sdk-foundation-spike): corelibs Foundation, CoreFoundation, curl,
libxml2 and OpenSSL taken out, Isomer's Foundation family put in, the SDK
registered with rules_swift as any other. A plain library that only
imports Foundation, a SwiftProtobuf user with its Foundation edge removed,
and the Android Storybook each linked exactly one Foundation, Isomer's.
The SDK's static libraries went from 208 MB to 144 MB; the Storybook's
native library from 64 MB to 45 MB and its APK from 28 MB to 22 MB (part of
that is the SDK's Foundation being optimized, not a like-for-like build).
What it taught:

- **Autolink entries are fixed when the importing module compiles.** A
  module's object records the libraries its imports name, by their link
  names at that moment; a link directive added afterwards changes nothing.
  So the family is compiled with `-module-link-name` for every module, and
  the helpers no client imports are folded into the archives clients do
  autolink: swift-collections and the C shims into FoundationEssentials',
  IsomerFoundation and IsomerDispatchTime into Foundation's. swift.org's
  SDK does the same with swift-collections (`_FoundationCollections`).
- **The C shims' target is `_FoundationCShims.rspm_c`** under
  rules_swift_package_manager.
- **rules_swift takes an SDK by checksum only** (`swift.android_sdk(sha256
  = …)`, its URL download.swift.org's), so the spike supplied the archive
  through `--distdir`.

## The repository

AttilaTheFun/isomer_hermetic_toolchains, a fork of
swiftlang/swift-foundation (renamed from AttilaTheFun/swift-foundation),
public. A branch per Swift release, `isomer-<version>` (`isomer-6.4.2`
first): swift-foundation's release tag and Isomer's patches as commits
(those isomer applies today: #2409, the SDK's ICU and fts_open, the
package helpers, Apple's interface), rebased onto each new release.

On that branch, beside swift-foundation's sources:

- `Isomer/`: what Isomer adds to Foundation (isomer's foundation/: the
  classic-Foundation layer, URLSession over host transports, Bundle's
  strings, UserDefaults, …), and the other modules an SDK carries with it:
  CoreGraphics, Combine, IsomerFoundation, IsomerDispatchTime. They move
  out of isomer, which then takes them from the SDK.
- A Bazel module, `isomer_hermetic_toolchains`: the SDKs it publishes, by
  URL and checksum, and their registration.
- CI that builds each SDK in a container and publishes it as a release
  asset: swift.org's SDK for the target, corelibs out, the family in
  (built optimized, with link names, the helpers folded), its
  `swift-sdk.json` and checksum kept.

## The SDKs, in order

1. Android: arm64 first (the spike's), then x86_64 and armv7. Gate: the
   Storybook on an emulator, every story drawn as today, and isomer's
   Foundation tests.
2. wasm (wasip1): the web Storybook in Chrome, the WASI Foundation tests.
3. Linux and Windows, which use corelibs Foundation today: their hosts and
   their Foundation tests move to Isomer's.

The threads SDK follows Swift 6.5 (TODO.md, "wasi-threads").

## Apple's platforms

Apple's real Foundation, untouched. The module registers rules_applecross's
toolchains (Xcode's SDKs from an archive, its actool, ibtool and codesign),
so Xcode is needed only to run an iOS app, never to build one. The
constraint: a consumer's one line choosing the toolchains, swapped for
apple_support's local Xcode toolchain, builds the same apps with no other
change.

## What a consumer writes

    bazel_dep(name = "isomer_hermetic_toolchains", version = "6.4.2.N")
    toolchains = use_extension("@isomer_hermetic_toolchains//:extensions.bzl", "toolchains")
    use_repo(toolchains, …)
    register_toolchains("@isomer_hermetic_toolchains//:all")

rules_swift's `swift` extension takes its SDK tags from one module only and
downloads from swift.org: until it takes a URL (a pull request through the
Upstream session, carried meanwhile as the registry's rules_swift
4.2.2.isomer.4), the module declares the SDKs' repositories itself.

## isomer after the move

- Package.swift: Foundation, FoundationNetworking, CoreGraphics, Combine and
  IsomerFoundation only on the platforms whose SDK lacks them; off Apple
  they are the SDK's.
- `@isomer//:foundation` stays as an empty group on those platforms, so
  existing BUILD files keep working, and the `configure_package(target_deps
  = …)` an app declared for Foundation can go.
- isomer depends on `isomer_hermetic_toolchains` by version; the toolchains
  move on their own cadence, a new Swift release a new branch and version.

## Open

- swift-collections inside the SDK under its own module names: an app that
  builds swift-collections itself would see two. Private names in the SDK
  (as swift.org's `_FoundationCollections`) are the likely answer.
- An archive folded from several modules keeps every object; whether a
  conformance only reachable through one is kept needs a run, not just a
  link (the gate above).
- FoundationInternationalization (ICU): a second SDK variant, or the ICU
  data an app's flag adds.
