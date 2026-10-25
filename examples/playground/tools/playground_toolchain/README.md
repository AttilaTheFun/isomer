# The on-device Swift toolchain campaign

Cross-compiles swift-frontend + lld for iOS (device AND simulator) as static
libraries — the embedded compiler the Playground app links
(`apple/playground_ios_application`, docs/playground.md). Run the
phases from a workspace directory holding `swift` + `llvm-project` +
`swift-syntax` + `cmark` worktrees at `swift-6.3.2-RELEASE` (the tag MUST
match the SwiftWasm SDK release for swiftmodule compatibility):

    ./build_phase_a_tablegens.sh                      # host llvm/clang-tblgen
    ISO_PLATFORM=iphoneos        ./build_phase_b_ios_llvm.sh   # LLVM+clang+lld
    ISO_PLATFORM=iphoneos        ./build_phase_c1_cmark.sh
    ISO_PLATFORM=iphoneos        ./build_phase_c2_swift.sh     # swift-frontend
    ISO_PLATFORM=iphonesimulator ...                  # same three, sim variant

Then stage into the app: `build_embedded_toolchain.sh` in the playground
package. Apply `swift-embedded-idempotent-init.patch` to the swift worktree
first — it makes `initializeSwiftModules` idempotent, which repeated
in-process `swift::mainEntry` calls require (re-registering the SIL bridged
classes aborts otherwise).

Macro support: pass `-DSWIFT_BUILD_SWIFT_SYNTAX=TRUE` (the c2 script does)
with `swift-experimental-string-processing` checked out beside the others
(same tag — canImport(_CompilerRegexParser) otherwise finds Xcode's macOS
module under `-disable-target-os-checking` and fails on missing @_spi
symbols; and DISABLING the regex parser instead trips a cmake export error,
so provide the source). The syntax-enabled frontend dynamically links 13
`lib_CompilerSwift*.dylib`s and the build emits
`libSwiftInProcPluginServer.dylib` + prebuilt macro plugins under
`lib/swift/host/` — build_embedded_toolchain.sh stages them all. When the
configure's Swift compiler changes, `rm -rf` the build dir: incremental
reconfigures corrupt the language-test cache.

Key facts discovered building this (also in docs/playground.md):
- CMAKE_SYSTEM_NAME=iOS needs CMAKE_MACOSX_BUNDLE=OFF, and breaks every
  `STREQUAL "Darwin"` gate (FindUUID, Libdispatch) — seed UUID_* and
  SWIFT_ENABLE_DISPATCH=OFF.
- BOOTSTRAPPING_MODE=CROSSCOMPILE-WITH-HOSTLIBS links the OS Swift runtime.
- SwiftCompilerSources must be compiled by a swiftc that understands the
  iOS SDK's swiftinterface (Xcode's), with a shim `bootstrapping0/lib/swift`
  resource dir carrying the clang builtin headers.
- Native helper tools (swift-compatibility-symbols, swift-def-to-strings-
  converter, swift-serialize-diagnostics) must exist in
  SWIFT_NATIVE_SWIFT_TOOLS_PATH — build them for the host with -fno-rtti.
- The frontend's link closure is minable from build.ninja; add liblldCommon
  + liblldWasm and a wasm-only `lldMain` entry (LLD_HAS_DRIVER(wasm)).

## Patches

- `swift-embedded-idempotent-init.patch` — repeated in-process
  `swift::mainEntry` re-registered SIL bridged classes and aborted.
- `llvm-signal-handler-reentry.patch` — LLVM's signal-callback table holds
  8 entries and `InitLLVM` registers one per invocation; the 9th in-process
  build aborted. Re-points the existing slot. Apply to llvm-project, then
  `ninja -C build/<suffix>-llvm LLVMSupport` and re-stage (no swift rebuild).

## Framework names

Host dylibs are shipped as embedded frameworks with short names
(`frameworkize_host.sh` `short_name`): install_name_tool rewrites load
commands in place only when the new path fits, and simulator dylibs have no
header padding. Add a case there when the toolchain gains a dylib.

## Android

The same compiler for the Android Playground
(`android/playground_android_application`), built for the Android
arm64 host with the NDK Bazel fetched (hermetic_android_toolchains) and the
Android Swift SDK bundle rules_swift fetched — nothing in Bazel's cache is
modified; what they lack is assembled beside the workspace:

    ./build_phase_a_tablegens.sh          # once, shared with iOS
    ./build_phase_b_android_llvm.sh       # LLVM + clang + lld, static, WebAssembly backend
    ./build_phase_c1_android_cmark.sh
    ./build_phase_c2_android_swift.sh     # swift-frontend (an executable: Android may run one)

Then `android/playground_android_application/stage_toolchain.sh`
stages `swift-frontend`, `lld` (as wasm-ld) and every shared library they
load as `lib*.so` files the APK carries in its native library directory, where
the app executes them as processes (no in-process entry, unlike iOS: Android
allows a subprocess, which keeps the compiler's global state out of the app).
Compiling the Counter template takes ~2 s and linking ~6 s on a Pixel 3a.

What the Android host build needed (all in build_phase_c2_android_swift.sh):
- A sysroot swiftc can link against: the NDK's plus Swift's `swiftrt.o` where
  the driver looks (`android-sysroot/`, what the bundle's
  setup-android-sdk.sh would make). The bundle's `swift/clang` link points at
  a Linux NDK, so `android-swift-resources/` re-links the resources with this
  NDK's clang builtin headers (an `-isystem` instead breaks libc++'s wrapper
  headers).
- The compiler's own Swift sources compile with `android-shim/bin/swiftc`
  (the base 6.3.2 swiftc plus `-sdk`, `-resource-dir`, `-tools-directory`);
  it is CMAKE_Swift_COMPILER, since the SwiftCompilerSources invocations
  carry only `-target`. They include `swift/shims/*.h` through
  `<swiftc>/../lib`, so `android-shim/lib/swift` links to the resources.
- Android has no libuuid: `android-uuid/` is the six functions
  swift/lib/Basic uses.
- The with-hostlibs link wants `lib/swift/android/aarch64/swiftrt.o` in the
  build tree: copied from the bundle.
- `-L<resources>/android` for `-lswiftCore`; and libc++'s `std::__voidify`
  instantiations the Swift-written modules reference are never emitted for
  this host: `android-voidify/voidify.cpp` instantiates the five, compiled
  WITH exceptions (the references carry libc++'s `ne` ABI tag).
