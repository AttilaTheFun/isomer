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
        // Isomer's Swift (Foundation and the frameworks off Apple), this
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
        // UpdateKit: the Storybook's iPhone and Mac apps write the build they are (version and BuildVariant) for
        // Applications at each launch, and are told of newer ones.
        // (ApplicationUpdates in AttilaTheFun/applications until 0.10.45.)
        .package(url: "https://github.com/AttilaTheFun/update_kit.git", exact: "0.11.0"),
    ]
)
