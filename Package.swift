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
import CompilerPluginSupport
import PackageDescription

// The platforms without Apple's frameworks, where Isomer's of the same names
// stand in.
let offApple: [Platform] = [.android, .wasi, .linux, .windows]

let package = Package(
    name: "isomer",
    // Where Isomer's own modules build on Apple platforms (an app compiled
    // against Isomer's frameworks: iOS 16). Foundation and the frameworks
    // build only off Apple, where swift-foundation's 26 means nothing.
    platforms: [.macOS("13"), .iOS("16")],
    products: [
        .library(name: "Foundation", targets: ["Foundation"]),
        .library(name: "FoundationNetworking", targets: ["FoundationNetworking"]),
        .library(name: "IsomerFoundation", targets: ["IsomerFoundation"]),
        .library(name: "CoreGraphics", targets: ["CoreGraphics"]),
        .library(name: "Combine", targets: ["Combine"]),
        .library(name: "IsomerSwiftUI", targets: ["IsomerSwiftUI"]),
        .library(name: "CoreTransferable", targets: ["CoreTransferable"]),
        .library(name: "UniformTypeIdentifiers", targets: ["UniformTypeIdentifiers"]),
        .library(name: "ImageIO", targets: ["ImageIO"]),
        .library(name: "SwiftUI", targets: ["SwiftUI"]),
        .library(name: "PhotosUI", targets: ["PhotosUI"]),
    ],
    dependencies: [
        // swift-6.4.2-RELEASE's commit: the swift-foundation the Swift SDKs'
        // Foundation is built from.
        .package(url: "https://github.com/swiftlang/swift-foundation.git", revision: "e4049b2d77e2d5d70c4cfcc99fd5eca32e1bcb06"), // tag: swift-6.4.2-RELEASE
        // SwiftUI's macros (@State, @Entry): swift-syntax as swift-foundation
        // takes it, by its branch (SwiftPM reconciles no other requirement on
        // it); the commit is Package.resolved's.
        .package(url: "https://github.com/swiftlang/swift-syntax", branch: "release/6.4.x"), // as swift-foundation
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
            path: "foundation/dispatch_time"
        ),
        .target(
            name: "CWasiThreadIdentity",
            path: "foundation/wasi_thread_identity",
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
            exclude: ["BUILD.bazel", "defs.bzl", "dispatch_time", "internationalization", "isomer_foundation", "networking", "tests", "wasi_thread_identity"],
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
        // The modules SwiftUI stands on, off Apple: what Isomer's SwiftUI
        // reads of its host and runtime (IsomerSwiftUI: the tree's wire format,
        // TreeGenerated.swift being flatc's, checked in), CoreTransferable,
        // UniformTypeIdentifiers and ImageIO under Apple's names.
        // IsomerSwiftUI's FlatBuffers comes from isomer's Bazel module
        // (MODULE.bazel's configure_package) until the wire format is
        // protobuf.
        .target(
            name: "IsomerSwiftUI",
            dependencies: [.target(name: "Foundation", condition: .when(platforms: [.android, .wasi]))],
            path: "shared/isomer_swift_ui",
            exclude: ["BUILD.bazel"]
        ),
        .target(
            name: "CoreTransferable",
            dependencies: [.target(name: "Foundation", condition: .when(platforms: [.android, .wasi]))],
            path: "frameworks/core_transferable",
            exclude: ["BUILD.bazel"]
        ),
        .target(
            name: "UniformTypeIdentifiers",
            dependencies: [.target(name: "Foundation", condition: .when(platforms: [.android, .wasi]))],
            path: "frameworks/uniform_type_identifiers",
            exclude: ["BUILD.bazel"]
        ),
        .target(
            name: "ImageIO",
            dependencies: [.target(name: "Foundation", condition: .when(platforms: [.android, .wasi]))],
            path: "shared/image_io",
            exclude: ["BUILD.bazel"]
        ),
        // SwiftUI's macros, expanded as Apple's plugin expands them
        // (swift_ui_macros/).
        .macro(
            name: "SwiftUIMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ],
            path: "swift_ui_macros",
            sources: ["library", "plugin"]
        ),
        // Isomer's SwiftUI: the core and the component renderers, the same
        // on every platform off Apple. The hosts and the GPU renderer that
        // plug into it are isomer's Bazel module's (each platform's
        // libraries/swift_ui).
        .target(
            name: "SwiftUI",
            dependencies: [
                "IsomerSwiftUI",
                "SwiftUIMacros",
                // Apple's frameworks of these names on a Mac (the headless
                // and terminal hosts): Isomer's elsewhere.
                .target(name: "CoreTransferable", condition: .when(platforms: offApple)),
                .target(name: "UniformTypeIdentifiers", condition: .when(platforms: offApple)),
                .target(name: "Foundation", condition: .when(platforms: [.android, .wasi])),
                .target(name: "ImageIO", condition: .when(platforms: [.android, .wasi])),
                .target(name: "CoreGraphics", condition: .when(platforms: [.linux, .windows])),
                .target(name: "Combine", condition: .when(platforms: [.linux, .windows])),
            ],
            path: "shared",
            exclude: ["swift_ui_core/BUILD.bazel"],
            sources: [
                "swift_ui_core",
                "renderers/PathRaster.swift",
                "renderers/Renderers.swift",
                "renderers/TreeDecoder.swift",
                "renderers/TreeEncoder.swift",
                // Linux's and Windows' Foundation (the toolchain's) has no
                // FileWrapper, which FileDocument hands over: Isomer's
                // Foundation's, compiled into SwiftUI there (the file says when).
                "swift_ui_corelibs",
            ],
            swiftSettings: [
                .enableExperimentalFeature("Extern"),
                .define("ISOMER_SWIFTUI"),
            ]
        ),
        .target(
            name: "PhotosUI",
            dependencies: [
                "SwiftUI",
                .target(name: "CoreTransferable", condition: .when(platforms: offApple)),
                .target(name: "UniformTypeIdentifiers", condition: .when(platforms: offApple)),
            ],
            path: "frameworks/photos_ui",
            exclude: ["BUILD.bazel"]
        ),
    ],
    // Swift 5 language mode, as isomer's Bazel targets build (those that
    // opt into 6 say so: IsomerFoundation).
    swiftLanguageModes: [.v5]
)
