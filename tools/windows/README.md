# Windows built on Linux

Swift and C/C++ for Windows on Arm (and x64), built on Linux: CI's container
builds the Windows apps beside every other platform's, and tests them under
arm64 Wine (tools/ci/windows_test.sh). No Windows machine is needed to build;
one is needed once, to make Microsoft's half of the toolchain (below).

`--config=windows_on_linux --platforms=@isomer//tools/platforms:windows_arm64`
(the examples' .bazelrc) turns the toolchains on. They come from
`swift_windows_sdk_repository` (defs.bzl), which pairs the host's Swift (the
same release) with two archives, named in MODULE.bazel by SHA-256 behind a
placeholder URL (`https://windows-sdks.invalid/sha256/<hex>`) that each
builder resolves: CI's tools/ci/container_build.sh to Shireworks' files, as
it resolves the Apple SDK archive's.

## The Windows Swift SDK

`make_swift_sdk.sh <swift.org's Windows installer> <out.tar.gz>`, on Linux
with 7-Zip and msitools (`apt install 7zip msitools`): the installer's
Windows.platform (the SDK, XCTest and Testing) and the Swift runtime's DLLs
(arm64 and x64 from 6.3's single runtime MSI; arm64 alone from 6.4's arm64
installer, whose runtime is an MSI per architecture), which an app ships
beside its .exe. Apache-licensed, as Swift is. Its release must be the host
toolchain's (swift-6.4.2-RELEASE's `windows10-arm64.exe` for 6.4.2; its
installer's payloads span several attached cabinets, all read).

## Microsoft's half

The Windows SDK's and MSVC's headers and import libraries. Microsoft's
license lets them be used, not redistributed: the archive is made by its
builder and kept on their own server, never published.

1. On a Windows machine with the Visual Studio Build Tools (Shireworks'
   `windows --config=swift-6.3.2` lease has them):
   `powershell -File make_msvc_sysroot.ps1` writes `C:\winsysroot.tar.gz`
   (clang's /winsysroot layout).
2. On Linux, with Swift: `make_msvc_sysroot.sh <winsysroot.tar.gz>
   <the Swift SDK archive> <out.tar.gz>` adds the links a case-sensitive file
   system needs (case_links.swift: Windows' headers include each other, and
   Swift's module maps name them, in casings other than the files'), and a
   VERSIONS file naming MSVC's and the SDK's versions.
3. Added to Shireworks' files (by its maintainers), and its SHA-256 into
   MODULE.bazel.

(xwin, which downloads Microsoft's packages directly, gave a Universal CRT
without the headers Swift's module maps need, `corecrt_math.h` among them.)

## How it builds

- Swift: the host's `swiftc`, `-target <cpu>-unknown-windows-msvc`, `-sdk`
  the Windows SDK, `-resource-dir` the SDK's Windows modules beside the
  host's clang headers and shims (the host's own resource directory holds
  Linux's modules, which clash), and `-visualc-tools-root`,
  `-windows-sdk-root` and `-windows-sdk-version` naming Microsoft's half.
- C and C++: the host's `clang-cl`, linked by its `lld-link`, archived by its
  `llvm-ar` as `llvm-lib`, through rules_cc's Windows toolchain
  configuration (as for MSVC), INCLUDE and LIB naming Microsoft's half.
- An app's DLLs: `@swift_windows_sdk//:runtime_aarch64` (and `_x86_64`).

## Running it on Linux

arm64 Wine 10 or later runs the arm64 build: Wine 9 can't unwind arm64
Linux libraries built with pointer authentication and hangs at its first
start. A headful app (`--@isomer//drive:headful`) needs Wine Staging 11.16
or later: its driver's SwiftNIO wakes its event loop through AF_UNIX
sockets, which Wine 10 lacks (WSAEAFNOSUPPORT; examples'
//tests/wine_nio:nio_probe checks a Wine). CI runs it in Shireworks' wine
image, Wine Staging 11.21 (tools/ci/platform_tests.sh). Direct3D 11 goes through Wine onto Mesa's software
OpenGL under Xvfb. Wine's DirectWrite and fonts are its own, so what it
draws checks that an app runs, never what Windows draws: the proof's Windows
pictures come from Windows.
