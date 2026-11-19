// swift-tools-version:5.9
// The prebuilt SwiftMap distribution for non-Bazel consumers: a binary
// Swift package wrapping the XCFramework.
//
// Populate the .xcframework next to this manifest first:
//   (cd examples && bazel build //swift_map/xcframework:SwiftMap)
//   ditto -x -k examples/bazel-bin/swift_map/xcframework/SwiftMap.xcframework.zip swift_map/distribution/
// (For a hosted release, switch the binaryTarget to url: + checksum: from
// `swift package compute-checksum SwiftMap.xcframework.zip`.)

import PackageDescription

let package = Package(
    name: "SwiftMap",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "SwiftMap", targets: ["SwiftMap"])
    ],
    targets: [
        .binaryTarget(name: "SwiftMap", path: "SwiftMap.xcframework")
    ]
)
