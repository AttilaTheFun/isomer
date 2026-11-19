// swift-tools-version: 5.9
// The root's Swift packages: isomer by its release's tag (README,
// "Consuming isomer"). tools/ci/sdk_smoke writes this for each cell (a
// candidate by path) and resolves it.
import PackageDescription

let package = Package(
    name: "sdk_consumer_swift_packages",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/AttilaTheFun/isomer.git", revision: "v0.57.1"),
    ]
)
