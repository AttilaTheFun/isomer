// swift-tools-version: 5.9
// isomer's own SwiftPM graph, which rules_swift_package_manager consumes:
// isomer's package itself (the root Package.swift: Foundation, CoreGraphics,
// Combine and the rest of Isomer's Swift), and through it swift-foundation,
// with the patches MODULE.bazel lists. An application's graph lists isomer
// by revision instead, and the same repositories come from it.
import PackageDescription

let package = Package(
    name: "isomer_swift_packages",
    dependencies: [
        .package(path: "../.."),
    ]
)
