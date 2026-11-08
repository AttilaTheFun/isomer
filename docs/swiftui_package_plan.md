# SwiftUI in isomer's Swift package (0.44)

0.43 made Isomer's Foundation, CoreGraphics and Combine a Swift package
(Package.swift at the root), built by rules_swift_package_manager in the
application's one SwiftPM graph. 0.44 moves the rest of Isomer's Swift
there: SwiftUI, the Isomer module, swift_ffi's runtime and macros, and what
they stand on. Bazel keeps what isn't a Swift library: the application
macros and packaging, swift_ffi's generators (Kotlin, TypeScript, JNI), the
Kotlin and JavaScript runtimes, the toolchains, rules_applecross.

## The aim

SwiftUI is built the same way on every platform: one target, the same
sources and dependencies. What differs is plugged in: the renderer (React,
Compose, SwiftGPU over each backend, the Apple tree view, none) and the
host (the web's bridge, Android's, the Linux and Windows windows, the
terminal, headless). Today each platform compiles its own `SwiftUI`: the
core and renderers with its host's files, a define picking the host's run
loop in `App.main` (`ISOMER_LINUX_HOST`, `ISOMER_HEADLESS_HOST`, ...), and
its own GPU backend, map engine and image decoder among the deps.

## What each platform's SwiftUI is built from today

| | core + renderers | host files | GPU backend | other deps |
|---|---|---|---|---|
| wasm | all renderers | WasmHost, WebBridge | swift_gpu/wasm | ImageIO (shared), isomer_network_host, swift_ffi, map engine flag |
| Android | all renderers | AndroidHost, AndroidBridge, application_main.c | swift_gpu/android | the same as wasm |
| Linux | all renderers | LinuxHost (+ the C renderer) | swift_gpu/linux | ImageIO (Linux), FileWrapper.swift, map engine flag |
| Windows | all renderers | WindowsHost (+ renderer.cpp) | swift_gpu/windows | ImageIO (Windows), FileWrapper.swift, map engine flag |
| headless | no GPU | HeadlessHost | none | FileWrapper.swift (Linux) |
| CLI | no GPU | TerminalApp, TerminalRenderer | none | |

Every one also has IsomerSwiftUI, FlatBuffers, CoreTransferable,
UniformTypeIdentifiers and Foundation. Sixteen targets compile the core's
sources in all: besides those six, the Playground's slim reactor SwiftUI
(wasm/libraries/hot_swift_ui, no macro plugins: the on-device compilers run
none) and its GPU twin, the Linux and Windows wasm hosts' SwiftUI
(linux|windows/libraries/swift_ui_wasm), Apple's IsomerCore and
IsomerGPUTreeView (the core under other module names beside Apple's
SwiftUI), the compiled-against-Isomer SwiftUI
(apple/libraries/compiled_swift_ui, `ISOMER_COMPILED_FEATURE`, iOS 16), two
Metal tap-counter examples and the snapshot tests. Each becomes the one
target with a host and renderer plugged in, or says why it can't (the slim
reactor's no-plugin build is the likeliest to stay its own).

## Steps

1. **Minimum OS versions off Apple** (done, #112). rules_swift_package_manager
   applied a package's Apple minimums, and its dependencies', while building
   for wasm, Android and Linux, so the package had to say iOS and macOS 26
   (swift-foundation's). A patch (also proposed upstream) skips that off
   Apple; the package declares Isomer's own minimums, iOS 16 and macOS 13.
2. **swift-syntax from the SwiftPM graph** (done, #112): swift-foundation's
   release/6.4.x, not the Bazel module. Then swift_ffi's macros and
   SwiftUI's are macro targets of the package (with step 6, the libraries
   that use them). A library that depends on a macro target passes its
   plugin to its dependents, as `@isomer//swift_ffi/swift_ffi` does today, so
   applications that write `@ExportedInterface` (Visor's, Reviews',
   the Playground's) need nothing new.
3. **Hosts out of SwiftUI** (done, #117-#120). Each host becomes a module of its own
   (IsomerWebHost, IsomerAndroidHost, IsomerLinuxHost, IsomerWindowsHost,
   IsomerTerminalHost, IsomerHeadlessHost), reaching the runtime's `package`
   plumbing as a module of the same package. `App.main` installs the app and
   hands over to the process's host through one C symbol the linked host
   defines (`iso_host_run`; the web's and Android's return, being driven from
   outside); a binary links exactly one host, the core's tests a test host.
   swift_ffi names generated bindings after their module (`SwiftUIBridge`
   today), so the Kotlin and JavaScript runtimes follow the bridges' new
   module names.
4. **Renderers out of SwiftUI** (the GPU renderer: done, #121; the component
   renderers stay in SwiftUI, the same on every platform). SwiftGPURenderer becomes a module over
   SwiftUI and SwiftGPU's interface, its backend the host's to link; the
   component renderers (React, Compose: their Swift side) and the tree
   renderers likewise, so SwiftUI has no GPU dependency and the headless and
   CLI builds stop needing `srcs_no_gpu`.
5. **The rest of the deps** (done but FlatBuffers, which comes from the Bazel
   module until protobuf replaces it in 0.45). FlatBuffers' Swift runtime from SwiftPM
   (google/flatbuffers' Package.swift, by version; its WASI and Android
   `import Foundation` answered by Isomer's Foundation, as the other packages
   are, instead of the registry patch; flatc stays a Bazel tool). ImageIO one
   module, its platform decoders plugged like renderers. FileWrapper in the
   Linux and Windows SwiftUI as a source of the one target under
   `#if` corelibs. The map engine through the plug the flag is today.
6. **SwiftUI, the Isomer module, PhotosUI, IsomerSwiftUI, swift_ffi's
   runtime and macros into Package.swift** (SwiftUI, PhotosUI, IsomerSwiftUI
   and the macros: done; the Isomer module, swift_ffi and Isomer's Metal,
   which the web's MetalView needs, next). Isomer's labels
   (`@isomer//:swift_ui`, `:isomer`, `//swift_ffi/swift_ffi`) become wrappers
   over `@swiftpkg_isomer`, as Foundation's are. The compiled-against-Isomer
   feature builds the same target for iOS 16 in its own configuration.
7. **Consumers.** Nothing changes for them beyond 0.43's Package.swift entry
   unless they named isomer's internal targets.
