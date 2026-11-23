# Roadmap

What comes next, in order. The north star: an iOS or macOS app's Swift,
written against Apple's frameworks, builds for Android, the web, Linux and
Windows against Isomer's without changes, or with as few as possible
(UIKit, AppKit and Objective-C aside). Progress is measured by the apps we
onboard and what each one needs: the Storybook, the Playground, Visor,
Convo, downstream apps' pass-backs, and later an Android Shireworks and the
Nimbus iPhone app.

## 0.60 (releasing)

Partial frames that stay partial (dead animations no longer force whole
rebuilds), a view's state lasting as long as the view, as in SwiftUI, an
app's own SwiftProtobuf (`@isomer//:swift_protobuf`), and Android layout and
stroke fixes.

## 0.61: the runtime, behind the interface

Changes that need no SDK work, before the SDK rework moves the runtime
behind its binding:

- **`@State` as Apple's 27 SDK's macros store it.** Isomer's SwiftUI is
  versionless: the macro form is the one on every platform and OS version
  (the Playground's in-browser compilers, which can run no compiler plugin,
  keep the property wrapper over the same storage). What changes is the
  storage behind the expansion: `State` holds its value inline and
  `LazyState` its thunk or value, each with an optional location the
  runtime writes into its copy of the view before `body`, as Apple's does.
  No box is allocated per state per view construction.
- **Bindings backed by the state's location,** with no get and set closures
  behind every `$x`.
- **The render tree's wire format written and read by hand** (step 2,
  below), the same bytes with no protobuf message made per node: encoding
  28–38% faster in the headless Storybook.
- **`borrowing` and `consuming` on the hot paths** (step 1, below) measured
  neutral and was left out: the retain traffic is in what the build stores.
- **State lifetime's follow-ups** (below).

Each measured with the headless Storybook before and after.

## 0.62: Apple's frameworks in Isomer's Swift SDKs

docs/frameworks_in_the_sdk.md is the design. In three pieces:
- the frameworks, precompiled in the SDK, with SwiftUI a facade;
- the Isomer\* binding modules, precompiled in the SDK;
- the runtime, built from source in isomer.

Its phases:

1. The split, in isomer, from source: the facade, the binding modules and
   the implementation (a visitor, binding at load with a version check).
   The Storybook's proof and every test unchanged.
2. Android's and the web's SDKs carry the facade, the binding modules, the
   other frameworks, the Isomer module and the macro plugin. `import
   SwiftUI` needs no dependency there.
3. Linux's and Windows' SDKs: Foundation, then the rest.
4. Isomer's SDK on Apple's platforms, as an alternative to Apple's.

## Fewer heap allocations in the runtime

Retain, release, deallocation and malloc were about a fifth of an Android
profile's samples in a downstream app on 0.58. Each step is measured with
the headless Storybook (whole and partial frames, `-c opt`) against the same
stories, before and after.

1. **`borrowing` and `consuming` on the hot paths** (tried for 0.61:
   neutral, 0.98–1.03 of the time before). The copies the compiler made were
   closure captures and stored values, which only steps 3 and 4 remove.
2. **The encoder and the tree's readers by hand** (0.61). The encoder writes
   tree.proto's bytes into one buffer through a `~Copyable` writer and the
   readers decode straight from the bytes, with no message made per node.
   Not through `Span`/`OutputSpan`: before iOS 26 they need a compatibility
   library embedded in the app, and Isomer's floor is iOS 16.
3. **Nodes in an arena** (after the SDK rework, when the runtime is the
   implementation's own). Render nodes as structs in a `~Copyable` arena,
   one buffer a tree, children by 32-bit index, not reference-counted
   objects: building is a bump allocation, and a tree is freed at once.
   Partial frames keep last frame's tree, so the arena is generational: a
   subtree reused from an earlier tree is shared by generation or copied
   across.
4. **Interned paths** (with step 3). A view's path is a string today, hashed
   and prefix-scanned throughout (rebuild sites, the build cache, state keys,
   the live owners). Interned once to an integer at build, as the node's
   identity in the arena, they make those lookups integer work.
5. **The `@State` macro's own optimizations** (with step 3): a static state
   layout per view type, and change detection without casts. These depart
   from Apple's exact expansion, so source-compatibility tests replace the
   identical-expansion check, and the expansion's helpers live in the binding
   module the SDK rework creates.

## Embedded Swift: a kernel without reflection, then an e-ink host

Embedded Swift as a platform, starting with an e-ink reader on an ESP32-C3
(RISC-V, about 400 KB of RAM, a 160 MHz core; Embedded Swift builds for it
through ESP-IDF). Isomer's core as it is won't compile there: Embedded Swift
has no reflection (`Mirror`), no unspecialized generics, few existentials
(`AnyView`, the type-erased view boxes, `Any`-typed state slots), no
metatype-keyed lookups (the environment's keys), and no Foundation or
Observation. Most of what it rules out is also what the allocation work
above measures as cost, so the work is shared: static dispatch, no boxing,
no reflection and fewer heap objects per view per frame speed up every
platform. What it adds is code size (every generic specialized), which the
web, where the wasm is downloaded, has to measure.

Apple's interface keeps what can't be embedded (`AnyView`, `ObservableObject`
and Combine, any value in the environment), so it is a split, not a
replacement: an **embedded-clean kernel** (layout, the diff, state storage,
the tree and its wire format) under a **full layer** with the compatibility
unmodified apps need, as 0.62 separates SwiftUI's interface from its
implementation.

1. **The measure** (after 0.62): the core compiled with Embedded Swift
   (`-enable-experimental-feature Embedded`, `riscv32-none-none-eabi`) in a
   container, its errors sorted by kind. That sizes the rest. Check
   `KeyPath` and Observation's registrar early: `@Observable` stands on both.
2. **The kernel, a piece at a time**, each benchmarked with the headless
   Storybook on desktop before and after, with the arena and interned paths
   above.
3. **An e-ink host on the ESP32-C3**: the display's controller over SPI,
   frames as 1- or 2-bit framebuffers with partial-refresh regions, buttons
   as input, a simple executor for `.task` and the frame loop.

## Research: running an app's own Apple build on Android

A mode for apps whose source isn't available, or that build with another
build system. The idea: take a developer's own, unencrypted iOS build
(arm64 Mach-O), load its code unchanged in an Android process, or convert it
to an ELF shared library, with its imports pointed at Isomer's frameworks,
and package it as an APK. The CPU is the same (arm64), so no instruction is
translated, as Switch games run natively on iPhones. What differs is the
surface the binary calls:
- **Swift's runtime on Darwin is built with Objective-C interop** (class
  metadata's layout, String's bridging): a Darwin-ABI runtime on Android,
  with a minimal Objective-C runtime;
- **the frameworks must be binary-compatible with Apple's**, not only
  source-compatible: the same mangled names, `@frozen` types laid out as
  Apple's, and Apple's `@usableFromInline` internals that its `@inlinable`
  code, inlined into the app, calls (docs/frameworks_in_the_sdk.md,
  "Binary compatibility");
- **Darwin's C ABI and libSystem** (variadic calls, `long double`, errno and
  struct layouts) through shims;
- **resources:** compiled asset catalogs, binary-plist strings, fonts.

App Store builds are encrypted, and anything using UIKit or Objective-C
directly is out of scope, so the target is pure SwiftUI apps.

**First step, a day's work and entirely static:** list every symbol a few
unencrypted builds import (the Storybook's iPhone app, Visor, Reviews), by
library (SwiftUI, Foundation, libswiftCore, libobjc, libSystem), and count
how many Isomer already provides under the same mangled names. That turns
"theoretically possible" into a number. After 0.62.

## Also open

- **Partial frames where the renderer draws its own chrome** (the GPU
  renderers on every platform, and headless, which lays chrome out as they
  do): today every frame there is built whole, by design, because drawn
  navigation stacks and split views animate their transitions in the core.
  Building them in place means keeping that chrome's state across frames.

- **Android: one slow frame on each navigation push** (120–200 ms in a
  downstream app; its Swift build is cheap). The likely cause is the top
  screen's `SubcomposeLayout`, composed fresh and measured twice in one
  frame; a Perfetto trace with Compose's tracing would confirm it. Next
  after the downstream's re-profile on 0.60, beside the SDK work: it is the
  Android renderer's, not the core's.
- **State lifetime's follow-ups:**
  - escape or hash `.id` and ForEach ids that contain "/" or "#" in a
    view's path;
  - the state of views first built outside a frame's build (menu content,
    drawn chrome) is kept forever;
  - a TabView's tabs exposed to the driver.
- **The web's dashed strokes:** built-in shapes draw their stroke as a CSS
  border, which can't set dash lengths.
- **rules_android 0.6 as isomer_android's floor:** CI's SDK smoke test
  builds the JNI library and a WASI command with it, not the APKs.
- **Upstream:** rules_swift_package_manager's Go dependencies
  (cgrindel/rules_swift_package_manager#2696), and rules_android's tools'
  protobuf-java (bazelbuild/rules_android#602).
