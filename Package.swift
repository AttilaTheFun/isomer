// swift-tools-version:6.0
// Isomer's Swift libraries as a Swift package, beside its Bazel module: an
// application lists isomer in its own Package.swift, and
// rules_swift_package_manager resolves Isomer's Swift (and swift-foundation,
// swift-collections and the rest) in the application's one graph. The Bazel
// module keeps what isn't Swift libraries: the application macros, the
// platform hosts and runtimes, swift_ffi's generators, the toolchains.
//
// Pinned by revision, the release's tag or a commit
// (`.package(url: "https://github.com/AttilaTheFun/isomer.git", revision: "v0.43.1")`):
// swift-foundation has no semantic versions and takes its own dependencies by
// branch, which SwiftPM allows only beneath a revision pin.
//
// The Apple-named modules are Isomer's off Apple only: on Apple platforms an
// application uses Apple's, so its targets depend on these with
// `.when(platforms: [.android, .wasi])` (Foundation) or the platforms that
// lack Apple's frameworks (CoreGraphics, Combine).
import PackageDescription

let package = Package(
    name: "isomer",
    // swift-foundation's: its targets build only where Apple's frameworks
    // are not, but rules_swift_package_manager holds a package to its
    // dependencies' minimums on every platform.
    platforms: [.macOS("26"), .iOS("26"), .tvOS("26"), .watchOS("26"), .visionOS("26")],
    products: [
        .library(name: "Foundation", targets: ["Foundation"]),
        .library(name: "FoundationNetworking", targets: ["FoundationNetworking"]),
        .library(name: "IsomerFoundation", targets: ["IsomerFoundation"]),
        .library(name: "CoreGraphics", targets: ["CoreGraphics"]),
        .library(name: "Combine", targets: ["Combine"]),
    ],
    dependencies: [
        // swift-6.4.2-RELEASE's commit: the swift-foundation the Swift SDKs'
        // Foundation is built from.
        .package(url: "https://github.com/swiftlang/swift-foundation.git", revision: "e4049b2d77e2d5d70c4cfcc99fd5eca32e1bcb06"),
    ],
    targets: [
        .target(
            name: "CoreGraphics",
            path: "core_graphics",
            exclude: ["BUILD.bazel", "tests"],
            swiftSettings: [
                // The toolchain's corelibs Foundation declares CGFloat and the
                // geometry types there (AGENTS.md).
                .define("ISOMER_CORELIBS_FOUNDATION", .when(platforms: [.linux, .windows])),
            ]
        ),
        .target(
            name: "Combine",
            path: "frameworks/combine",
            exclude: ["BUILD.bazel", "tests"]
        ),
        .target(
            name: "IsomerFoundation",
            dependencies: [.product(name: "FoundationEssentials", package: "swift-foundation")],
            path: "foundation/isomer_foundation",
            exclude: ["BUILD.bazel"],
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "IsomerDispatchTime",
            path: "foundation/dispatch_time",
            exclude: ["BUILD.bazel"]
        ),
        .target(
            name: "CWasiThreadIdentity",
            path: "foundation/wasi_thread_identity",
            exclude: ["BUILD.bazel"],
            publicHeadersPath: "."
        ),
        .target(
            name: "Foundation",
            dependencies: [
                "Combine",
                "CoreGraphics",
                "IsomerFoundation",
                .product(name: "FoundationEssentials", package: "swift-foundation"),
                .target(name: "IsomerDispatchTime", condition: .when(platforms: [.android, .wasi])),
                .target(name: "CWasiThreadIdentity", condition: .when(platforms: [.wasi])),
            ],
            path: "foundation",
            exclude: ["BUILD.bazel", "defs.bzl", "dispatch_time", "isomer_foundation", "networking", "tests", "wasi_thread_identity"],
            swiftSettings: [
                // Built in swift-foundation's package, as the Bazel target is:
                // its string API searches with Essentials' `package` helpers.
                .unsafeFlags(["-package-name", "swift-foundation"]),
            ]
        ),
        .target(
            name: "FoundationNetworking",
            dependencies: ["Foundation"],
            path: "foundation/networking",
            exclude: ["BUILD.bazel"]
        ),
    ],
    // Swift 5 language mode, as isomer's Bazel targets build (those that
    // opt into 6 say so: IsomerFoundation).
    swiftLanguageModes: [.v5]
)
