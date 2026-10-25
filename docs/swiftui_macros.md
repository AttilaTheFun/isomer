# SwiftUI's macros

Since the iOS 27 SDK, Apple's SwiftUI declares `@State` and `@Entry` as
macros, implemented by Xcode's `SwiftUIMacros` plugin. Isomer's SwiftUI
declares them the same way (`shared/swift_ui_core/Macros.swift`), and
`//swift_ui_macros:SwiftUIMacros` implements them.

## How the plugin works

The plugin is built for the host, as swift_ffi's is. Every library that
compiles the SwiftUI core lists it in `plugins`
(`swift_ui_macros/defs.bzl`), and rules_swift then loads it for every
module that depends on one.

Its expansions are Apple's, learned only black-box: small views were
compiled against Apple's SwiftUI and the compiler printed the expansions
(`-Xfrontend -dump-macro-expansions`). Apple's plugin was not opened.

The @State part comes from the clean-room plugin in
AttilaTheFun/rules_applecross (`tools/apple_tools/swiftui_macros`,
Apache 2.0), with observers added. @Entry is new.

The expansions name `SwiftUI` where Apple's name `SwiftUICore`. A core
compiled under another module name (IsomerCore, IsomerGPUTreeView) aliases
`SwiftUI` to itself, and so must the modules that use `@State` against it
(`tests/renderer`).

| Macro | Notes |
| --- | --- |
| `@State`, `@State(initialValue:)`, `@State(wrappedValue:)` | A private state with an initial value is stored as `LazyState`, its value made once, when the view is first installed. Other states are stored as `State`. `willSet` and `didSet` run as closures around the write, with the old value read first when `didSet` uses it. |
| `_StatePropertyWrapperStorage`, `_StateInitialStoredValue`, `_StateProjectedValue`, `_PropertyWrapperProjectedValue` | The helpers the `@State` expansion uses. |
| `@Entry` | Works in `EnvironmentValues`, `Transaction`, `ContainerValues` and `FocusedValues`. Isomer has keys for `EnvironmentValues` only so far. A default made by a call gets Apple's `_typeCheck`, and a class default gets its warning. A closure-typed entry gets Apple's warning. |
| `__EntryDefaultValue`, `_SwiftUIEntryTypeCheck` | The helpers the `@Entry` expansion uses. |

Not implemented:
- `@Animatable` and `@AnimatableIgnored`: Isomer has no `Animatable` yet.
- `_EntryDefaultValue`.
- `_SwiftUIState`.
- `#Preview` and `@Previewable`.

## Where the macros are declared

The macros are declared only by **Swift 6.4 and later**:
`#if compiler(>=6.4)`.
- **Why:** Apple's expansion gives a private `@State` a private property
  with an init accessor. Swift 6.3.2 then makes the view's memberwise
  initializer private, so `Foo(x: 1)` becomes inaccessible. Swift 6.4 does
  not.
- **Apple platforms:** builds use Xcode's 6.4, so they have the macros.
  That includes the apps compiled against Isomer
  (`storybook_isomer_ios_application`) and the hosted cores.
- **Other platforms:** wasm, Android, Linux and Windows build with
  swift.org 6.3.2. There `@State` is the property wrapper alone until
  Isomer's toolchain is 6.4.

`wasm/libraries/hot_swift_ui` never declares them
(`-DISOMER_NO_SWIFTUI_MACROS`). It is the SwiftUI the Playground's compilers
build against, in a browser or on an iPhone, and no compiler plugin can run
there.

## Checks

- `bazel test //swift_ui_macros:tests` checks the expansions as swift-syntax
  lays them out.
- `swift_ui_macros/compare_with_xcode.sh` compiles `swift_ui_macros/probes/`
  against Apple's SwiftUI twice:
  - **With Apple's plugin, and with ours** (built to name `SwiftUICore`).
  - **Then compares** what the compiler prints.
  - **Identical:** `StateBasics`, `StateVariants` and `Entry`.
  - **Whitespace only:** `Observers` and `EntryDefaults` differ in the
    indentation inside observer closures, and in an empty closure default
    (`{}` printed `{` newline `}`).
- `//tests/renderer:mock_renderer_test`'s `checkStateMacro` checks two
  things:
  - a private state's initial value is made once, under 6.4;
  - `didSet` runs after the write.
