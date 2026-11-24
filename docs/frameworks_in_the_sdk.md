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

Nothing here is built yet.

## Three pieces

Two are precompiled into the SDK. The third is built from source with the
app, from isomer.

1. **Apple's frameworks, Isomer's versions** (SDK, precompiled): Foundation,
   Combine, CoreGraphics, OSLog, UniformTypeIdentifiers, CoreTransferable,
   PhotosUI, and SwiftUI. All are full implementations except SwiftUI,
   which is a **facade**: its public types (`View`, `Text`, the stacks, the
   modifiers, `@State`, `App`) and what they hold, with nothing behind them
   but calls to the runtime. Any of the others may later move its
   implementation out the same way: that's a private change.
2. **The Isomer\* binding modules** (SDK, precompiled), which the frameworks
   depend on privately: an API between the facade and the runtime.
   IsomerSwiftUI declares the runtime's protocol and holds the runtime
   bound to it, set when the process starts.
3. **IsomerSwiftUIImplementation** (isomer, built from source): the runtime
   itself (building, layout, diffing, state, animation, partial frames, the
   render tree's encoding) implementing IsomerSwiftUI's protocol, and bound
   to it as the app starts.

SwiftUI and IsomerSwiftUI have no SwiftProtobuf. SwiftProtobuf sits between
the runtime and the renderer, on isomer's side, where
`@isomer//:swift_protobuf` (0.60) lets an app share its own.

Alongside, and kept apart from the SDK:

- **The renderer**: plugged in through the FFI.

  | Platform | Renderers |
  | --- | --- |
  | iOS, macOS | native SwiftUI, or the GPU renderer on Metal |
  | Android | Jetpack Compose, or the GPU renderer on OpenGL |
  | Web | the DOM renderer, or the GPU renderer on WebGPU |
  | Linux | the GPU renderer on OpenGL |
  | Windows | the GPU renderer on DirectX |

- **What the host injects**: the platform's side (Android's Kotlin runtime,
  the page's JavaScript, the network transports, the keychain) is injected
  by the host through the FFI into the Isomer\* modules. No SDK module names
  a platform's runtime: the Kotlin and JavaScript stay with isomer_android's
  rules and the web's runtime files.

Each platform has a default SDK: Android's and the web's are Isomer's. On
iOS and macOS the default is Apple's, and Isomer's is an alternative, for
example to drive an app from the CLI while it draws with native SwiftUI
(apple/compiled is that today, as a Bazel configuration). A headless app
is a plain `swift_binary` on macOS, Linux or Windows with no renderer,
usually serving WebSocket or gRPC. Optionally it uses the headless head,
the GPU renderer's layout engine drawing nothing.

## How the pieces meet

- **The facade's primitives are data.** `Text`, `VStack` and `.padding`
  hold their parameters. What turns them into nodes, today each primitive's
  `makeNode` in shared/swift_ui_core, moves into the implementation.
- **No dynamic casts to find a primitive.** IsomerSwiftUI declares a
  visitor protocol with a method per primitive; each facade primitive calls
  its own (`visitor.visit(self)`), and the implementation is the visitor.
  Dispatch is static. A new primitive is a new requirement with a default
  implementation, which library evolution allows.
- **State, environment and animation** go through the same protocol: a
  property wrapper asks the runtime for its location, as it connects today.
- **Binding.** The implementation exports a bind call that the host makes as
  it loads (JNI's load on Android, the page's boot on the web), before the
  facade's `App.main` runs, alongside what the host injects. The bind checks
  versions both ways: the runtime names the facade versions it supports,
  and fails clearly otherwise.
- **Linking.** An app's own libraries declare nothing. isomer's app rules
  (`isomer_android_app`, `isomer_web_app`, `isomer_application`) link the
  implementation and the host into the final binary, as they link the hosts
  now.
- **Library evolution.** The facade and the binding modules are built
  resilient, so a newer runtime runs under an older SDK, and their interface
  is a contract. Calls from an app into the facade aren't specialized across
  it unless they're `@inlinable`, as with Apple's SwiftUI: measure that on
  the Storybook.
- **Macros.** `@State` and `@Entry` are macros. Their plugin, a program for
  the building machine, ships in the SDK bundle, built for each build
  machine (macOS arm64, Linux x86_64 and arm64) and named by the bundle's
  toolset.json, so a consumer's compiler finds it with no flag.
- **The Isomer module** (Isomer's own API: WebView, Map, MetalView,
  Clipboard, the platform modifiers) is in the SDK too, so `import Isomer`
  needs no dependency either. On Apple's platforms it stays the package's.

## Binary compatibility with Apple's, where it's cheap

A facade designed now decides whether an app's own Apple build could one day
run against Isomer's frameworks without its source (docs/roadmap.md,
"Research"). That needs the facade to be binary-compatible with Apple's, not
only source-compatible:
- **the module named `SwiftUI`, mangling as Apple's does**, so the app's
  references to Apple's symbols name ours. The strict-subset rule already
  keeps the names; the mangling follows from the module's name and the
  declarations';
- **`@frozen` types laid out as Apple's**, since their layout is baked into
  an app's code (0.61's `State` already is: `_value` and `_location`);
- **Apple's `@usableFromInline` internals present**, since Apple's
  `@inlinable` code inlined into an app calls them;
- **protocols' requirements** that an app's conformances refer to (a View's
  `body`), under the same descriptors.

Nothing here is built for it yet. The rule for the facade: where matching
Apple's binary interface costs nothing, match it; where it costs, decide then.

## Sources and releases

- **All three pieces' sources stay in isomer** for now. The SDK's build
  checks out isomer at a tag and builds the facade and the binding modules
  into the SDK, as it builds Foundation's. A change to the facade goes with
  the implementation in one pull request.
- **From source:** isomer's own builds build all three from source, as
  today, so a change is tested before any SDK has it.
- **Releases:** a new SDK when the facade's or the binding modules'
  interface changes. The runtime ships with each isomer release, and the
  version handshake says which SDKs it runs under.

## What an app changes

- **Nothing in its Swift.** That's the point.
- In its BUILD files and Package.swift: no SwiftUI, OSLog or Isomer
  dependency for Android and the web. `@isomer//:swift_ui` and its siblings
  stay as empty targets (as `@isomer//:foundation` did in 0.56), so
  existing files keep building.
- Its MODULE.bazel registers the SDK (one line per platform, as now). A
  wrapper rule that adds SwiftUI to every `swift_library` goes.

## Phases

1. The split, in isomer, from source: the facade, the binding modules and
   the implementation, with the visitor, the binding and the handshake. The
   Storybook's proof and every test must be unchanged. In steps, each a
   pull request that leaves them so, each measured with the headless
   Storybook:
   1. **Views say what they are, as Apple's do.** `View` takes Apple's
      requirements, `static func _makeView(view: _GraphValue<Self>, inputs:
      _ViewInputs) -> _ViewOutputs` and `_makeViewList`, with defaults: a
      composite view builds its body, a primitive its node, a `Shape` its
      path. The build calls the view's own `_makeView` through the type it
      opened, so the casts, the conformance index and the kind caches that
      answer "what is this view" today (Node.swift, ConformanceIndex.swift,
      FieldRecords.swift) go. Apple's names and signatures, so the
      facade's View mangles as Apple's (below).
      Measured against the iOS 27 SDK's interfaces: of Isomer's 103
      primitive views, Apple's SwiftUI declares a public `_makeView` on 18;
      the shapes take Apple's public `Shape` default and the internal ones
      (`_ForegroundFill`, the modifiers' views) may answer privately, which
      leaves about 35 public views (Button, List, TextField, Toggle,
      NavigationStack, ScrollView, Picker…) that are primitives in Isomer
      and composites in Apple's. Those become what Apple's are: a public
      `body` over an internal primitive, the strict subset's rule kept,
      the body's step transparent to the view's path (no new segment), so
      no state or node identity moves.
   2. **Content held by its type, as Apple's is:** `TupleView<T>` holds
      `value: T` (a tuple, built by `ViewBuilder`'s parameter packs) rather
      than `[any View]`, and a container's children are walked through
      `_makeViewList`, with no existential per child.
   3. **The primitives as data, the visitor in IsomerSwiftUI:** each
      primitive's `_makeView` calls the visitor's method for it; the
      runtime's building moves behind the visitor.
   4. **The modules apart:** SwiftUI (the facade), IsomerSwiftUI (the
      protocol and the binding), IsomerSwiftUIImplementation (the runtime),
      with the bind call and the version handshake.
2. Android and web SDKs carry the facade, the binding modules, the other
   frameworks, the Isomer module and the macro plugin. isomer's labels
   become empty there. Measure the result on the apps we have (the
   Storybook, Playground, Visor, Convo) and on a downstream app's diff.
3. Linux and Windows SDKs: Foundation, then the rest; headless apps there
   get the same.
4. Isomer's SDK on Apple's platforms, as an alternative to Apple's (the
   compiled configuration becomes an SDK).

## The implementation as an embedded-capable core (2026-11-23)

The owner's direction: a fast core that compiles for Embedded Swift, with
the full SwiftUI interface layered on it, as Apple's SwiftUI stands on
SwiftUICore (docs/roadmap.md, "Embedded Swift"). As much as possible goes
in the core, short of costing the full interface's compatibility or speed.
So the implementation is written to need no reflection, no dynamic casts
and as few existentials as it can (phase 1's steps 1 and 2 remove the
largest), and what can't be embedded (`AnyView`'s erasure, `ObservableObject`
and Combine, any value in the environment) stays in the layer above.

## Decided (2026-11-22)

- Three pieces: the frameworks (SwiftUI a facade) and the binding modules
  in the SDK, the implementation in isomer. No SwiftProtobuf in the SDK.
- The macro plugin in the SDK bundle.
- The Isomer module in the SDK.
- All sources in isomer for now.
- The other frameworks stay whole in the SDK; moving an implementation out
  later is a private change.
