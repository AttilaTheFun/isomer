// swift-tools-version: 5.9
// isomer's own SwiftPM graph, which rules_swift_package_manager consumes:
// swift-foundation, whose FoundationEssentials (and, when an app asks,
// FoundationInternationalization) Isomer's Foundation is built over on the
// platforms without Apple's. At swift-6.4.2-RELEASE's commit (the tag is
// not a version SwiftPM reads: tools/released_pins.sh checks the tag), with
// the patches MODULE.bazel lists.
import PackageDescription

let package = Package(
    name: "isomer_swift_packages",
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-foundation.git", revision: "e4049b2d77e2d5d70c4cfcc99fd5eca32e1bcb06"), // tag: swift-6.4.2-RELEASE
    ]
)
