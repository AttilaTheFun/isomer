# Open items (2026-10-13, 0.31 pre-release)

What is left after 0.31's work, to choose the next work from. Where Isomer
is a subset of Apple's interfaces, declaration by declaration (with the
conformances, Sendable and overloads its types lack), is
[parity/missing/](parity/missing/) (SwiftUI's is
[parity/missing/SwiftUI.md](parity/missing/SwiftUI.md)); where it is a
superset (what `--check` keeps out, what it does not see, and what Isomer
adds in modules of its own) is [parity/superset.md](parity/superset.md).
This file is everything else. Check the code before relying on an item: it may be done
by the time you read it.

## Platform tiers

Linux and Windows are T3, wasm and Android T2, iOS and macOS T1 (2026-10-13).

| Tier | Platforms | Verified on a change |
|---|---|---|
| T1 | iOS, macOS | simulators, the Mac |
| T2 | wasm (web, Electron), Android | headless Chrome, the hermetic emulator |
| T3 | Linux, Windows | built and run on oss machines from the Mac: Linux in a container (`tools/linux/build.sh`) and run in a Linux VM, Windows on the Windows VM with the Swift build layer (the Playground's `tests/proof/proof.py`) |

## Releases

- isomer 0.31 is a pre-release on `release-0.31` (isomer, visor_isomer,
  the Playground, the swift-foundation fork's `isomer` branch), not
  tagged; Visor's v0.31 is released. Tagging and merging to main wait for
  the maintainer's review.
- rules_swift is pinned with a `git_override` (MODULE.bazel and
  examples/MODULE.bazel): replace it with a plain `bazel_dep` at the next
  rules_swift release.

## Linux and Windows (T3)

- **Both are built and run on oss machines (0.38).** Linux builds in an
  oss container (`tools/linux/build.sh`) and runs in a Linux VM; Windows
  builds and runs on the oss Windows VM with the Swift build layer
  (tools/ci/oss/windows-swift.ps1: Visual Studio's build tools, Swift,
  Python), in MSVC's environment with Git's bash and POSIX tools (the
  release proof, tools/proof/proof.py, says how): the Storybook drawn by
  each platform's renderer, and the Playground compiling projects there
  and running them in the WasmKit loader's window. Linux's Playground
  carries the swift.org toolchain's frontend and wasm-ld (shared/compiler);
  Windows' takes them from the build VM's installed Swift, since rules_swift
  has no Windows host toolchain to assemble them from. Visual Studio and an
  installed Swift are a stopgap until the hermetic toolchains replace them.
- **Windows' Swift 6.3.2 can't link `AttributedString.runs`** (its
  Foundation doesn't export the descriptor of _FoundationCollections'
  `BigString.Index`, on ARM64 and x64 alike), so there `Text(AttributedString)`
  shows its text unstyled (shared/swift_ui_core/AttributedText.swift).
- **Windows' hosts draw every frame** (the compiled app's loop and the
  wasm cell's, paced by Present; Linux's draw on demand), so an idle
  window costs about a core under a VM's software D3D (WARP).
- **WasmKit's WASI opens no directory on Windows**, so a guest there has
  no file system at all (no /tmp, no home); on Linux it has /tmp.
- **Linux and Windows still use the toolchain's Foundation**
  (swift-corelibs-foundation), not Isomer's: `URLSession` is in
  FoundationNetworking there (code imports it under `os(Linux) ||
  os(Windows)`), and Isomer's CoreGraphics is built over it as the part it
  lacks (`ISOMER_CORELIBS_FOUNDATION`: CGVector, CGAffineTransform, CGPath,
  CGColor; CGFloat, CGPoint, CGSize and CGRect are corelibs'). Moving them
  onto Isomer's Foundation would make every platform's Foundation one
  source.
- **The desktop wasm hosts give a guest no home or platform channel** on
  Linux and Windows (their `WasmKitRuntime` gets no `homeDirectory` or
  `bundleIdentifier`, their `WasmFeatureRuntime` no `onPlatformCommand` or
  `hostValue`): a guest's FileManager directories are not writable,
  `@AppStorage` does not persist, the clipboard does nothing. Their
  network transports are URLSession's (0.38, as Apple's WasmView's).

## WasmView on Apple (T1)

- **`Map` in a reactor under WasmView is its placeholder**, with either
  renderer: the guest draws the real map only when its host says it draws
  `map` host views (`iso_hot_configure` `maps` = `drawn`, 0.38), and
  neither Apple renderer does yet. The SwiftUI tree renderer would show
  SwiftMap's Apple view for the node; the GPU one (GPUTreeServicesHost)
  would draw its tiles, as the Linux and Windows loaders do.
- **The SwiftUI tree view differs from Apple's SwiftUI** in the Storybook
  compiled against Isomer (0.38.13's proof, review-ios-storybook-isomer,
  each story beside Apple's shot of it):
  - a custom `Shape`'s path is drawn as its frame's rectangle;
  - `LazyVGrid`'s adaptive columns are too many and don't stretch to the
    width (5 fixed columns where Apple fits 4);
  - `Stepper`'s buttons are tinted, not Apple's grey ones;
  - `ProgressView` centres its label;
  - `OutlineGroup`'s rows put the disclosure chevron first, without
    Apple's trailing one;
  - `ContentUnavailableView`'s description is smaller than Apple's.

## Android (T2)

- **WasmView on Android gives a guest no home** (it passes none), so a
  wasm feature's files and `@AppStorage` do not persist there; Apple's
  WasmView passes the app's container. The network transports are
  injected (WasmNetworkHosts.kt).
- SwiftGPU on Android works as a library but is not an endorsed app path;
  Compose is the renderer.
- **`Map` under Compose is its placeholder** (the Storybook's Map story
  shows it): only the GPU renderer draws SwiftMap's tiles on Android
  (AndroidBridge sets `Renderer.hostRendersMaps` there alone), where the web's
  React renderer composites them. Compose needs a map host view of its own.

## The web (T2)

- **The web's fastbuild overflows the stack** (the Playground's and the
  Storybook's: "RangeError: Maximum call stack size exceeded", a
  WebAssembly native stack overflow, in FlatTreeEncoder's flatten); `-c
  opt` builds work and are what ships (playground/docs/playground_web.md).
  The tree is shallow (the Storybook's is 14 levels); unoptimized,
  `flattenNode` (shared/renderers/TreeEncoder.swift, one ~900-line
  function) has so many wasm locals that each frame V8's baseline compiler
  gives it is large. Splitting it into smaller functions is the likely fix.
- Browsers cannot speak gRPC: a web client goes through gRPC-Web and a
  proxy (Envoy).

## Apple's interfaces (all platforms but Apple's)

- **Most of each interface is not there yet**: SwiftUI 24% of Apple's
  counted declarations, Foundation 39%, CoreGraphics 31%, Metal 24%
  (docs/parity/README.md has the table; parity/missing/ the lists). The
  SwiftUI areas planned next are in parity/missing/SwiftUI.md's table.
- **Sendable is reported, not enforced.** `--check` fails on a conformance
  Apple's type lacks, but not on Sendable and the other marker protocols:
  some Isomer types are Sendable where Apple's are not (Apple marks its
  button and form styles `~Sendable`), and some of Apple's are where
  Isomer's are not (`Text`, `Image`, the shapes): parity/superset.md and
  each module's missing list name them.
- **ImageIO is not a strict subset yet** (it came before the rule): it
  declares `CGImage` (CoreGraphics' on Apple), CF typealiases of Swift
  types where Apple's are classes, and public underscored host hooks.
  parity.py reports it as a known gap without failing `--check`
  (tools/parity/reasons/ImageIO.json says what the fix is).
- **`.keyboardType(_:)` is iOS-only**: its parameter is UIKit's
  `UIKeyboardType`, which no Apple-named module off Apple has (IsomerUIKit
  is gone), so code asks for a number pad under `#if canImport(UIKit)` (a
  number-entry field's `numberPad()`), and the reimplementation's text fields get
  the default keyboard (the hosts still read a node's keyboard type; nothing
  sets it). A way to choose one off Apple without Isomer API in SwiftUI is
  open. (On iOS, in a compiled feature, Isomer's SwiftUI has it, as Apple's.)
- **A compiled feature (an Apple app's Swift against Isomer's frameworks)
  is iOS 16** (AGENTS.md, "Apple apps compiled against Isomer"), by choice:
  15 would need Isomer's own `Duration`, `Clock` and `Regex` (the standard
  library's are iOS 16), and overriding the standard library is not wanted
  library. Isomer's Synchronization there is `Mutex` only, Observation lacks
  `Observations` (iOS 18 concurrency runtime), CoreTransferable is the
  built-in conformances only (no `transferRepresentation`), and Foundation
  is still Apple's.
- **A text field's `selection` where a host doesn't report it**
  (shared/swift_ui_core/TextSelection.swift): the web, Compose and the Apple
  tree view on iOS 18 and macOS 15 report the caret and show a selection the
  app sets (0.33, examples' selection_probe_* apps); below iOS 18 (the
  compiled blue Visor's iOS 16), and in the GPU renderer's, Linux's and
  Windows' fields, the binding still follows the end of the text.
- **QuickLook (`quickLookPreview`) is only in compiled Apple features**:
  the web and Android have no preview to present (an AgentUI attachment
  there opens its own viewer). A host-presented one on each would let the
  module join their SDKs.
- **Attributed text on Apple platforms reads Apple's attribute scope**
  (AGENTS.md, "Apple apps compiled against Isomer"): only the system's
  named colours and text styles (at each weight, bold, italic) come
  through; another colour or a sized font is drawn as the text's own.
- **Link runs' own colours**: the Apple host draws a link run in its own
  colour when it has one (as SwiftUI does an attributed link with a
  foreground colour); whether the React and Compose hosts do is unchecked.
- **Combine's side of SwiftUI is not planned** (`ObservableObject`,
  `@StateObject`, `onReceive`): Observation and Swift concurrency instead.
  On Android a library's `DispatchQueue.main.async` still runs (the host
  drains libdispatch's main queue); wasm has no Dispatch at all (`#if
  canImport(Dispatch)`).
- Later, not 0.31 (docs/isomer_031_plan.md): Metal backends for Android,
  Windows and Linux; wasm to native Metal on Apple platforms; SwiftUI's
  shader effects; Metal 4; a MapKit subset for `Map`; `URLSession` and
  `FileManager` over the web's own APIs; a separate `IsomerServer`; SwiftPM.

## Applications

- **A WasmView guest's first requests wait for its first draw** (0.35
  candidate, 2026-10-17: acceptable for now, a possible improvement): at a cold start the blue Visor's
  sign-in leaves about 0.4 s after the store asks for it on the simulator,
  because WasmKitRuntime holds the guest's main-actor jobs
  while a tree is undrawn (`treeUndrawn`, which keeps a chat's place while
  pages load in above it) and a guest thread's swift_ffi calls wait for the
  main thread (`onMain`), which is drawing the first screen. Options: start
  work enqueued before the first tree without waiting for its draw (but not
  later trees'), or a faster first commit.

- **Consumers on Foundation's services** (the plan's phase 12): Visor
  Isomer moved (visor_isomer db8894b). Other applications' file stores and
  host HTTP are their own to move; not checked here.
- **Playground projects**: an unedited project made from a template by any
  earlier build is brought to the current template at launch (the Playground
  `TemplateHistory`, rebuilt from git history by
  `playground/tools/playground/template_history.py`); an edited one keeps its source and
  needs a manual update where 0.31 removed API it used (`ObservableObject`,
  `DispatchQueue`, the injected services).
- **The Playground's macro toolchain is built outside Bazel**:
  `playground/tools/browser_toolchain`'s scripts build the WASI
  compiler and `MacroPlugins.wasm` (ObservationMacros, SwiftMacros), and
  Android's prebuilt plugins are staged by `stage_toolchain.sh`; a toolchain
  bump means running them again by hand.
