#!/bin/bash
# Builds the toolchain's prebuilt macro plugins (ObservationMacros,
# SwiftMacros) as WebAssembly, for the
# browser compiler (swift-frontend.wasm runs no processes and loads no
# libraries: the page instantiates a plugin module beside it and passes it the
# compiler's requests, README "Macros"). Each plugin is a WASI command: its
# `main` registers swift-syntax's message handler, and the host calls
# `swift_wasm_macro_v1_pump` once per request written to its stdin.
#
#   ./build_macro_plugins.sh        → $ISO_WORKSPACE/build/wasi-macro-plugins/MacroPlugins.wasm
#
# One module serves both (macro_plugins/MacroPluginsMain.swift): a macro is
# found by its type's module and name, and swift-syntax is then in it once.
#
# Sources: the swift worktree's lib/Macros (the macros the iOS and Android
# Playgrounds load as libraries) over the swift-syntax worktree, both at
# swift-6.3.2-RELEASE; the swift.org 6.3.2 toolchain and the SwiftWasm SDK
# that compiles user code (env.sh).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"
WORK="$ISO_WORKSPACE/build/wasi-macro-plugins"
PKG="$WORK/package"
rm -rf "$PKG"; mkdir -p "$PKG/Sources/ObservationMacros" "$PKG/Sources/SwiftMacros" "$PKG/Sources/MacroPlugins" "$WORK/sdks"

cp "$ISO_WORKSPACE"/swift/lib/Macros/Sources/ObservationMacros/*.swift "$PKG/Sources/ObservationMacros/"
cp "$ISO_WORKSPACE"/swift/lib/Macros/Sources/SwiftMacros/*.swift "$PKG/Sources/SwiftMacros/"
cp "$HERE/macro_plugins/MacroPluginsMain.swift" "$PKG/Sources/MacroPlugins/"

cat > "$PKG/Package.swift" <<SWIFT
// swift-tools-version:5.9
import PackageDescription

let syntax: [Target.Dependency] = [
    .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
    .product(name: "SwiftDiagnostics", package: "swift-syntax"),
    .product(name: "SwiftSyntax", package: "swift-syntax"),
    .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
    .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
]

let package = Package(
    name: "MacroPlugins",
    dependencies: [.package(path: "$ISO_WORKSPACE/swift-syntax")],
    targets: [
        .target(name: "ObservationMacros", dependencies: syntax),
        .target(name: "SwiftMacros", dependencies: syntax),
        .executableTarget(name: "MacroPlugins", dependencies: ["ObservationMacros", "SwiftMacros"] + syntax),
    ]
)
SWIFT

# The SDK bundle that compiles user code, where SwiftPM looks for SDKs.
BUNDLE="$(dirname "$(dirname "$ISO_WASM_SDK")")"
ln -sfn "$BUNDLE" "$WORK/sdks/$(basename "$BUNDLE")"
"$ISO_BASE_TC/swift" build --package-path "$PKG" -c release \
    --swift-sdks-path "$WORK/sdks" --swift-sdk swift-6.3.2-RELEASE_wasm \
    --product MacroPlugins
rm -f "$WORK"/*.wasm
cp "$PKG/.build/wasm32-unknown-wasip1/release/MacroPlugins.wasm" "$WORK/MacroPlugins.wasm"
ls -la "$WORK"/*.wasm
