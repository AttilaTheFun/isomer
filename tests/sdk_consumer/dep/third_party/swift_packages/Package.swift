// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "sdk_consumer_dep_swift_packages",
    dependencies: [
        .package(url: "https://github.com/apple/swift-algorithms.git", exact: "1.2.1"),
    ]
)
