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
- **`borrowing` and `consuming` on the hot paths,** and **spans in the
  encoder and the tree's readers** (below, steps 1 and 2).
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

1. **`borrowing` and `consuming` on the hot paths** (0.61). The build and
   encode paths pass `BuildContext`, `EnvironmentValues` and nodes by value
   through deep recursion. Borrowing them where they're only read, and
   consuming them where ownership moves, removes retain and release traffic
   with no change of types.
2. **Spans in the encoder and the tree's readers** (0.61). The encoder
   writes into a buffer owned by a `~Copyable` writer through
   `OutputSpan`/`MutableSpan`, with no copy-on-write checks or intermediate
   arrays. The readers read nodes straight from a `Span` over the bytes,
   allocating nothing per node.
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

## Also open

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
