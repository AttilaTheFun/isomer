# Apple's frameworks in Isomer's Swift SDKs (a design, for review)

The aim: an iOS or macOS app's Swift, which on Apple's platforms links
Apple's frameworks, builds and links for Android and the web against
Isomer's, without changes or with as few as possible. On Apple's platforms
`import SwiftUI` needs no dependency in a BUILD file or a Package.swift: the
framework is the SDK's, and links what it needs itself. Isomer's should be
the same. UIKit, AppKit and Objective-C are out of scope: code that reaches
for them uses Isomer's cross-platform APIs (`Clipboard`, the platform
modifiers) behind `canImport`.

Foundation, FoundationNetworking, CoreGraphics and Combine have been the
SDK's on Android and the web since 0.56 (docs/hermetic_toolchains.md). This
is the rest: SwiftUI and the frameworks its interface names.

Nothing here is built yet. The decisions it needs are at the end.

## Three things, kept apart

- **The SDK**: the Apple-named modules, and the Isomer* modules they depend
  on privately. Each platform has a default SDK: Android's and the web's are
  Isomer's. On iOS and macOS the default is Apple's, and Isomer's is an
  alternative, for example to drive an app from the CLI while it draws
  with native SwiftUI (apple/compiled is that today, as a Bazel
  configuration). An SDK can be built from source or used prebuilt.
- **The renderer**: plugged in through IsomerSwiftUI's FFI, never part of
  the SDK.

  | Platform | Renderers |
  | --- | --- |
  | iOS, macOS | native SwiftUI, or the GPU renderer on Metal |
  | Android | Jetpack Compose, or the GPU renderer on OpenGL |
  | Web | the DOM renderer, or the GPU renderer on WebGPU |
  | Linux | the GPU renderer on OpenGL |
  | Windows | the GPU renderer on DirectX |

- **What the host injects**: the platform's side (Android's Kotlin runtime,
  the page's JavaScript, the network transports, the keychain) is injected
  by the host, through the FFI, into the Isomer* modules the SDK's modules
  depend on privately. So no SDK module names a platform's runtime, and the
  Kotlin and JavaScript stay where they are: isomer_android's rules, the
  web's runtime files.

A headless app is a plain `swift_binary` on macOS, Linux or Windows with
no renderer, usually serving WebSocket or gRPC. Optionally it uses the
headless head, the GPU renderer's layout engine drawing nothing. It needs
the Linux and Windows SDKs (phase 2), or Isomer's on macOS (phase 3).

## What moves into the Android and web SDKs

| Module | Today | In the SDK |
| --- | --- | --- |
| SwiftUI | isomer's package (`@isomer//:swift_ui`) | yes, resilient, with IsomerSwiftUI beneath it |
| Observation, Synchronization | the toolchain's | as now |
| OSLog (`Logger`) | `@isomer//:os_log` | yes |
| UniformTypeIdentifiers, CoreTransferable, PhotosUI | the package's | yes |
| ImageIO | the package's | yes, once it is a strict subset (docs/parity) |
| Isomer (Isomer's own API: WebView, Map, MetalView, Clipboard, …) | the package's | yes: Apple's platforms take it from the package, as now |
| The platform's host's Swift (IsomerAndroidHost, IsomerWebHost) | the platform's `swift_ui` group | yes, privately: what `App.main` hands the process to, and what the host injects into |
| The renderers' Swift (IsomerGPURenderer) | Bazel modules | no: a renderer is chosen by the app, linked by its rules |

`import SwiftUI` then autolinks SwiftUI, IsomerSwiftUI and the platform's
host's Swift, as `import Foundation` autolinks its family now. An app's
`@main App` runs on Android when its JNI library is loaded by
isomer_android's activity, and on the web when the page boots the
reactor, as now.

## The two things that don't fit as they stand

**1. SwiftProtobuf beneath SwiftUI.** IsomerSwiftUI writes the render tree
with SwiftProtobuf (FlatTreeEncoder, Wire_Node). An SDK that carried
SwiftProtobuf as `SwiftProtobuf` would clash with an app's own (the reason
for `@isomer//:swift_protobuf`, #286). The options:
- (a) The SDK carries it under a private module name (as swift.org's
  `_FoundationCollections`), built from swift-protobuf's sources with its
  module renamed. Then an app's SwiftProtobuf and the SDK's never meet.
- (b) The render tree's Swift writer and reader are hand-written against
  protobuf's wire format, as the web's (runtime/flat_tree.js) and Android's
  (FlatTree.kt) readers already are. SwiftUI then needs no SwiftProtobuf at
  all. The driver's and session's messages (IsomerWire) stay
  SwiftProtobuf's, outside the SDK.

  (b) is less to carry and removes a dependency from every app, at the
  cost of keeping the hand-written code in step with tree.proto, which
  tools/ could check. **Recommended: (b).**

**2. SwiftUI's macros.** `@State` and `@Entry` are macros (since 0.39),
expanded by the SwiftUIMacros plugin. A plugin is a program for the
machine doing the build, not for the SDK's target. An SDK artifact bundle
can carry one per build machine (macOS arm64, Linux x86_64 and arm64),
named by its toolset.json's compiler flags (`-load-plugin-executable`). A
consumer's toolchain then finds it with no flag of its own. The plugin is
small (swift-syntax, statically linked). **Recommended:** carry it in the
bundle, built by the SDK's own CI for each build machine. Isomer's Bazel
rules already know where it is, for apps built from source.

## From source, or prebuilt

One source, two ways to build it:
- **SwiftUI's sources stay in isomer**, beside the renderers and the
  hosts, which change with them. They don't move to isomer_hermetic_toolchains
  as Foundation's did: SwiftUI changes with every isomer release, and
  Foundation with Swift's.
- **The SDK's build checks out isomer at a tag** and builds the SwiftUI
  family into the SDK, as it builds Foundation's.
- **From source:** isomer's own builds and an app that asks for it
  (`--@isomer//:frameworks=source`) build SwiftUI from isomer's package, as
  today, with the SDK's SwiftUI left out of the link. That's how isomer is
  developed and tested before an SDK exists for a change.
- **Prebuilt:** the default for an app. The SDK registered is the one
  released with the isomer version the app depends on.

This ties SDK releases to isomer's. An isomer release N names SDK
`isomer-6.4.2.<n>` built from isomer N's tag, and the SDK's
release run follows isomer's (Reviews approves both, as now). The JavaScript
and Kotlin halves and the SDK's Swift half are then always from the same
release.

## What an app changes

- **Nothing in its Swift.** That's the point.
- In its BUILD files and Package.swift: no SwiftUI, OSLog or Isomer
  dependency for Android and the web. `@isomer//:swift_ui` and its siblings
  stay as empty targets (as `@isomer//:foundation` did in 0.56), so
  existing files keep building.
- Its MODULE.bazel registers the release's SDK (one line per platform, as
  now). A wrapper rule that adds SwiftUI to every `swift_library` (as one
  consumer has) goes.

## Phases

1. Android and web SDKs carry the SwiftUI family, with the macro plugin;
   SwiftProtobuf goes from SwiftUI by option (b); isomer's labels become
   empty there. Measure the result on the apps we have (the Storybook,
   Playground, Visor, Convo) and on a downstream app's diff.
2. Linux and Windows SDKs: Foundation, then the SwiftUI family; headless
   apps on Linux and Windows get the same.
3. Isomer's SDK on Apple's platforms, as an alternative to Apple's, for
   driving an app with the native renderer (apple/compiled's
   configuration becomes an SDK).

## Decisions needed

1. SwiftProtobuf: (a) a private copy in the SDK, or (b) a hand-written
   writer and reader with no SwiftProtobuf in SwiftUI. Recommended: (b).
2. The macro plugin carried in the SDK bundle, per build machine.
   Recommended: yes.
3. SDK releases tied to isomer's, one per isomer release. Recommended: yes.
4. The Isomer module in the SDK too, so `import Isomer` needs no dependency
   either. Recommended: yes.
