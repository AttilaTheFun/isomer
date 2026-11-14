// swift-tools-version:6.3
// SideloadCheck (../host's sources) on the WasmKit isomer pinned before the
// side-module branch (AttilaTheFun/WasmKit 5fbb9db), without the linker
// (NO_LINKER): the "before" of the 2048 drag benchmark, a self-contained
// reactor only. `BENCH=drag .build/release/SideloadCheck /dev/null <reactor>`.
import PackageDescription

let package = Package(
    name: "MixedHostsOriginalWasmKit",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/AttilaTheFun/WasmKit", revision: "5fbb9db8a130edf2971fc57b25186a62b689a693"),
    ],
    targets: [
        .executableTarget(
            name: "SideloadCheck",
            dependencies: [.product(name: "WasmKit", package: "WasmKit"), .product(name: "WasmKitWASI", package: "WasmKit")],
            swiftSettings: [.swiftLanguageMode(.v5), .define("NO_LINKER")]),
    ]
)
