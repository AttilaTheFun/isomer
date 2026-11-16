// swift-tools-version: 5.9
// isomer's own SwiftPM graph, which rules_swift_package_manager consumes:
// isomer's package itself (the root Package.swift: SwiftUI, the frameworks
// and the rest of Isomer's Swift) and what it depends on. An application's
// graph lists isomer by revision instead, and the same repositories come
// from it.
import PackageDescription

let package = Package(
    name: "isomer_swift_packages",
    dependencies: [
        .package(path: "../.."),
    ]
)
