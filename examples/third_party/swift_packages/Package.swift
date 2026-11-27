// swift-tools-version: 5.9
// The SwiftPM manifest rules_swift_package_manager consumes for every
// example. SwiftProtobuf provides protoc-gen-swift + the runtime and the
// grpc-swift-2 family the transport for the proto greeter. (AgentUI and
// OpenRouterKit were the Playground's, which moved to AttilaTheFun/playground
// in 0.47.)
import PackageDescription

let package = Package(
    name: "isomer_examples_swift_packages",
    platforms: [.macOS("15.0")],
    dependencies: [
        // Isomer's Swift (SwiftUI and the frameworks off Apple), this
        // repository's: an application elsewhere lists it by revision.
        .package(path: "../../.."),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
        // 2.4.3 is the first release with WASI support (grpc/grpc-swift-2#52).
        .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.4.3"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", exact: "2.4.1"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", exact: "2.10.0"),
        // SQLite: its C API and the Swift layer over it (the files probe and
        // the WASI check).
        .package(url: "https://github.com/AttilaTheFun/swift_sql.git", exact: "0.35.0"),
        // ShireworksKit: the Storybook's iPhone and Mac apps write the build
        // they are (version and BuildVariant) for Shireworks' Applications,
        // show its update sheet, report crashes, and file an issue with a
        // screenshot and the logs on a shake (Help › Report a Bug… on the
        // Mac), for someone signed in to the shared GitHub sign-in; only in
        // builds that carry its keys (CI's, //tools/signing). It replaced
        // UpdateKit and ShakeKit. At 0.1.0.
        .package(url: "https://github.com/AttilaTheFun/shireworks_kit.git", exact: "0.1.0"),
        // build_tools: CI's shared tools, built here and run by the release
        // jobs: `sign` (an APK, a Mac app, an
        // iPhone app, with the release environment's keys) and `proof-diff`
        // (the proof's comparison, proof-diff.json). CI's alone: no app or
        // library of Isomer's depends on it.
        .package(url: "https://github.com/AttilaTheFun/build_tools.git", exact: "0.7.0"),
    ]
)
