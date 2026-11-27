# Prebuilt Swift libraries beside an Isomer app on Android

A Swift library that an app takes as files, built elsewhere (by another
team, in another repository, on another schedule), not compiled from source
in the app's Bazel graph, and that uses Isomer's Swift: its Foundation, its
SwiftUI, or the Isomer module. There are two ways to ship one:

- **(a) A shared library over the shared platform**: the library is
  `lib<name>.so`, linked against Isomer's shared platform library
  (`libisomer_platform.so`); the app links its own library against the same
  platform and ships all three.
- **(b) A static archive and a `.swiftinterface`**: the library is
  `lib<Module>.a` with its module (the textual `.swiftinterface`, and the
  binary `.swiftmodule`, which Bazel imports on Android today: below); the
  app links the archive into its one JNI library, as if the library's code
  were its own.

Both bind the library's code to one build of Isomer and one Swift
toolchain. Neither makes a library that keeps working across Isomer
versions: that needs Isomer's own modules built with library evolution,
which they are not (below).

The examples' `//tests/prebuilt_swift_library` builds a library both ways
and an app taking each, and checks the APKs (CI's container build runs it).

## What pins a prebuilt library to an Isomer version

A Swift binary is compiled against the modules it imports and their
dependencies, and off Apple's platforms none of them promises a stable
binary interface:

- **Isomer's modules are compiled without library evolution** (README,
  "Swift features, Java and library evolution"), but for Foundation,
  FoundationNetworking, IsomerFoundation, CoreGraphics and Combine, which
  Isomer's Swift SDKs build resilient since 0.56 (swift-foundation's
  FoundationEssentials beneath them stays fragile): SwiftUI with IsomerSwiftUI
  beneath it, PhotosUI, UniformTypeIdentifiers, the Isomer module, os and
  OSLog, and swift_ffi's runtime. A library that uses any of them was
  compiled against their exact layouts: a struct's size and its fields'
  offsets, an enum's cases, a class's vtable, a protocol's witness table,
  and the bodies of their `@inlinable` code, inlined into it. It reaches
  them by mangled name.
- **Swift's own ABI is stable only on Apple's platforms.** On Android the
  standard library, the runtime, Concurrency and Dispatch are the Android
  Swift SDK's, linked into the app (into its library, or into the
  platform), and the library's code must come from the same compiler and
  SDK: isomer's MODULE.bazel names them (swift.org's 6.4.2 today).
- **Isomer's build settings change its modules too**: what the library was
  built with, the app must build with, among them
  `--@isomer//foundation:internationalization` (Foundation's
  FoundationInternationalization), examples/.bazelrc's
  `--config=isomer_library_evolution` (Isomer's modules resilient: a
  different ABI) and `--@isomer//headless`.

So a prebuilt library and the app must use **the same isomer version**
(MAJOR.MINOR.BUILD, or the same commit between releases: a build can change
a layout that no public interface shows, and versions follow the public
interface, not the binary one), **the same Swift toolchain and Android
SDK**, and the same Isomer settings. An `internal import` of an Isomer
module changes none of this: it keeps the module's types out of the
library's interface, but the library's code still calls it.

What breaks when they differ, at best to worst:

- the app's compiler refuses the library's `.swiftinterface` (it names an
  API this Isomer no longer has, or Swift's syntax moved on), or a binary
  `.swiftmodule` outright (a module "compiled with" another Swift "cannot
  be imported by" this one);
- the app's link, or its load, fails on a symbol the app's Isomer lacks;
  with a shared library (route a), the load: `UnsatisfiedLinkError: dlopen
  failed: cannot locate symbol "$s10Foundation…"`, when the app starts;
- nothing fails, and the library reads a struct whose fields moved, calls a
  vtable slot that now holds another method, or runs an inlined body whose
  invariants changed: memory corruption, wrong values, crashes far from the
  cause. Neither route detects it.

Record what a library was built with, and check it in the app's build: the
isomer version (the library's MODULE.bazel), the Swift toolchain (a
`.swiftinterface`'s first lines, `// swift-compiler-version:` and `//
swift-module-flags:`, say which compiler and target built it), the ABIs
(arm64-v8a, x86_64), and any of the settings above. Naming the release for
them (`greeter-1.4-isomer-0.56.3-swift-6.4.2.tar.gz`) makes a mismatch
visible before it links.

## (a) The shared platform

With the shared platform (README, "One platform library for several apps")
the Swift runtime, the standard library, Foundation, SwiftUI and the rest of
Isomer's SDK are one library, `libisomer_platform.so`
(//android/libraries/swift_ui:isomer_platform, swift_ffi's
`kt_swift_platform`), every symbol exported. The app's own library links
against it; so can a prebuilt one, and then one runtime, one Foundation and
one Isomer serve both in the process.

**The author builds** the library's Swift as `swift_library` targets
(`alwayslink = True`: nothing in the shared library refers to them, so
without it none of their code is linked) against Isomer's targets, and
links them over the platform with `isomer_android_shared_library`
(android/module/defs.bzl):

```starlark
load("@isomer_android//:defs.bzl", "isomer_android_shared_library")

swift_library(
    name = "greeter",
    srcs = ["Greeting.swift"],
    alwayslink = True,
    library_evolution = True,  # for the .swiftinterface; see (b)
    module_name = "Greeter",
    deps = ["@isomer//:foundation"],
)

isomer_android_shared_library(
    name = "greeter_android",  # :libgreeter_android.so
    deps = [":greeter"],
)
```

`lib<name>.so` needs `libisomer_platform.so` (DT_NEEDED) and holds none of
what the platform holds: it is linked through swift_ffi's
`swift_platform_library`, which leaves the platform's archives out, puts
the platform first on the link line (the runtime resolves to it, not to a
second copy) and links with `-z defs` (a symbol neither defines fails the
link, not the load). Its own symbols are exported (the Swift Android
toolchain's `--exclude-libs,ALL` is left out, as the platform's own link
leaves it out). It ships with each module's `.swiftmodule`, which the app
imports, and its `.swiftinterface` (with `library_evolution`), one set per
ABI.

**The app takes it** with the platform always on, the module, the `.so` to
link against and to ship:

```starlark
cc_import(name = "greeter_so", shared_library = "android/arm64-v8a/libgreeter_android.so")

swift_import(
    name = "greeter",
    module_name = "Greeter",
    swiftmodule = "android/arm64-v8a/Greeter.swiftmodule",
    deps = [":greeter_so"],
)

cc_library(name = "greeter_native", srcs = ["android/arm64-v8a/libgreeter_android.so"])

isomer_android_app(
    name = "my_app",
    swift_library = ":app_swift",  # its deps: ":greeter", Isomer's as always
    package = "com.example.myapp",
    shared_platform = True,
    extra_binary_deps = [":greeter_native"],
)
```

`shared_platform = True` (on `isomer_android_app`, `isomer_android_library`
and `isomer_android_aar`) links the app against the platform and ships it
whatever `--@isomer//tools/android:shared_platform` says. The APK's
lib/<abi>/ then holds `libisomer_platform.so`, the app's
`lib<app>_runtime_bindings.so`, which needs both, and the library's `.so`.
An AAR (`isomer_android_aar(shared_platform = True, extra_native_libs =
[...])`) carries the same three.

**What pins it.** The library was linked against one build of
`libisomer_platform.so`; at load it binds, by name, to the one the app
ships, which the app built from its own isomer. Nothing checks that the
two are the same build. They are when the isomer version, the Swift
toolchain and the Isomer settings above are the same. The platform also
follows `--@isomer//swift_ffi/rules:libcxx` (libc++ inside it, local to
it, by default); the library's own C++, if any, is README's "One C++
runtime with other libraries"'s.

**The cost.** The platform exports every symbol, so nothing of Isomer is
dead-stripped: the Storybook measured 19.8 MB of platform and 0.6 MB of
app library at 0.42, against 16.2 MB as one library. An app alone in its
process with no prebuilt library is smallest as one library.

**Not with the default one library.** Without the platform, the app's
library holds its runtime and Isomer privately (only its JNI entry points
are exported), so a prebuilt `.so` has nothing to bind to; one holding its
own runtime and Isomer would put two of each in the process, whose types,
objects and main actor are not the same: nothing Swift can cross between
them.

## (b) A static archive and a `.swiftinterface`

**The author builds** the library's `swift_library` targets with
`library_evolution = True`, for Android (`--platforms=@isomer//tools/platforms:android_arm64`,
and `android_x86_64` if the app ships that ABI), against Isomer's targets
from the same isomer version as the app's. rules_swift compiles them with
`-enable-library-evolution` and emits `<Module>.swiftinterface` (and
`<Module>.private.swiftinterface`, for `@_spi`) beside `lib<name>.a` and
`<Module>.swiftmodule`. A release of the library is, per ABI, each
module's archive, `.swiftmodule` and interface.
The archive holds the library's own objects alone, none of its
dependencies' (not Foundation's, not the runtime's): the app links those.

**The app takes it** with a `swift_import` in its Swift library's deps:

```starlark
swift_import(
    name = "greeter",
    module_name = "Greeter",
    archives = ["android/arm64-v8a/libGreeter.a"],
    swiftmodule = "android/arm64-v8a/Greeter.swiftmodule",
    # What the library imports and links: Isomer's targets.
    deps = ["@isomer//:foundation"],
)
```

The app's compiler imports the module (against Isomer's modules from its
own graph, which `deps` gives it), and the archive is
linked into `lib<app>_runtime_bindings.so` with the app's Swift: one
library, its one Foundation and its one copy of Isomer, as if the code
were the app's. `deps` must name every Isomer target the library uses:
Bazel reads no autolink entries from a prebuilt archive, so a library it
doesn't name is not linked (an undefined symbol at load). Foundation is
the Swift SDK's (Isomer's, since 0.56), so the library and the app link the
one Foundation whether `deps` names it or not; the library is built with
the same Isomer SDK as the app. No `extra_binary_deps`: there is no second `.so`. It works
with the platform too (the archive is linked into the app's library, which
binds to the platform). With `--config=android_release` the linker drops
what of the archive the app doesn't reach, as it does Isomer's.

**`swift_import` links its archives whole.** rules_swift's `swift_import`
links every archive it is given with `alwayslink` (rules_swift 4.3.0, with no
attribute to turn it off): every object of the archive goes into the app's
library, whether anything reaches it or not. A library whose archive carries
objects the app also links another way (generated protobuf code compiled
into both, say) then fails with duplicate symbols, and one that pulls in
large unused code keeps it. Give the archive as a `cc_import` instead,
linked lazily, and the module alone through `swift_import`:

```starlark
cc_import(
    name = "greeter_archive",
    static_library = "android/arm64-v8a/libGreeter.a",
    # Lazily: only the objects something reaches, as a cc_library's archive.
    alwayslink = False,
)

swift_import(
    name = "greeter",
    module_name = "Greeter",
    swiftmodule = "android/arm64-v8a/Greeter.swiftmodule",
    deps = [":greeter_archive", "@isomer//:foundation"],
)
```

Lazily linked, an archive's object the app's code never names is left out,
so a library that registers itself at load (a static initializer, an
`@_cdecl` the host looks up by name) must be linked whole, or named by
something that is.

**Debug information stays in the archive's objects.** The app's link
carries the objects' DWARF into its unstripped library (what a symbolicated
crash reads); an archive stripped before it ships leaves the library's
frames without lines. Ship the objects with their debug information, and
let the app's release build strip its own `.so` as it does Isomer's.

**The `.swiftinterface`, not yet through Bazel on Android.** rules_swift's
`swift_import(swiftinterface = ...)` compiles the interface into a module
with its SwiftCompileModuleInterface action, which rules_swift 4.2.2's
non-Apple toolchain (swift_toolchain.bzl, the one Android's Swift SDK
builds with) runs without the SDK: no `-sdk`, and not the toolchain's
copts, where the Android SDK's resource directory is (Apple's toolchain
passes its SDK to that action). It fails on the
interface's first line, "no such module 'Swift'". Until rules_swift gives
that action the SDK (TODO.md), an app on Android imports the binary
`.swiftmodule`: readable only by the compiler build that wrote it, which
this route requires anyway, so it pins nothing more. The interface still
ships beside it: the module's API as text, for people and tools, and what
an app imports once rules_swift compiles it.

**Library evolution, and its warning.** Library evolution is here only for
the interface (the compiler emits a `.swiftinterface` only with it): the
library's own types become resilient to the app, but the library is still
bound to Isomer as above, since Isomer's modules are not resilient. Its
import of one of them warns: "module 'SwiftUI' was not compiled with
library evolution support; using it means binary compatibility for
'GreeterView' can't be guaranteed". That is true. The warning has no
diagnostic group (`-Wwarning` can't exempt it from warnings-as-errors).
Two ways to a clean build:

- **`internal import`** of the Isomer modules the library uses inside its
  functions only (`internal import Foundation`): the interface doesn't
  import them, and nothing warns. The interface can then name none of their
  types: a library whose API is the standard library's types and its own.
- **`public import`** where the interface needs Isomer's types (a `View`
  in its API): the warning stays; build that module without
  warnings-as-errors (`features = ["-swift.treat_warnings_as_errors"]`), or
  with Isomer's modules resilient as well (`--config=isomer_library_evolution`
  in examples/.bazelrc), which the app must then build with too.

Or build without library evolution and ship the `.swiftmodule` alone: no
warning, and no interface to read.

## What the test checks

examples/tests/prebuilt_swift_library: two modules, PrebuiltGreeter
(Foundation behind an `internal import`) and PrebuiltGreeterView (a SwiftUI
`View` in its interface, a `public import`: it warns, as above), built with
library evolution; their archives, modules and interfaces taken as files
(`swift_library_artifacts`; the interfaces built, the modules imported),
and an app taking each route
(`isomer_android_app`). check.sh reads each APK with the NDK's llvm-nm and
llvm-objdump:

- route (b): the app's library needs no Foundation of the Swift SDK's,
  holds no CoreFoundation runtime (only corelibs' Foundation brings it) and
  defines Isomer's; it defines each module's symbols from the archives
  (those the linker keeps) and leaves nothing they use (Foundation's,
  SwiftUI's, the runtime's) undefined, Foundation's defined in it; the
  archives define none of Foundation's own;
- route (a): lib/arm64-v8a/ holds the platform, the app's library and the
  prebuilt one; the prebuilt library needs the platform, exports its
  module, and takes every Swift symbol it uses from the platform, Foundation
  among them; the app's library needs both and takes the module from the
  prebuilt library; neither defines any Swift symbol the platform exports.

`bazel test //tests/prebuilt_swift_library:prebuilt_swift_library_test` in
the examples' module (a `build_test`: nothing runs or draws).
