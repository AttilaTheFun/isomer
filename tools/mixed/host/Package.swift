// swift-tools-version:6.3
// The mixed-mode prototype's hosts (see ../README.md), on WasmKit with the
// side-module API and cheap host calls (pawlowskialex/WasmKit, branch
// isomer-side-modules, what MODULE.bazel pins):
//   SideloadCheck  a runtime module and side modules on WasmKit, by
//                  WasmDynamicLinker, driven over the iso_hot ABI
//   RuntimeCheck   the same through Isomer's own WasmKitRuntime
//                  (loadSideModule), its sources linked from shared/wasm_host
//   MixedCheck     the runtime interpreted plus wasm2c'd native copies of
//                  its hot functions (Sources/CHot, which ../split/round.sh
//                  generates), sharing memory and a mirrored table
import Foundation
import PackageDescription

let isomerPackage: [SwiftSetting] = [.unsafeFlags(["-package-name", "isomer"])]
let wasmKit: [Target.Dependency] = [
    .product(name: "WasmKit", package: "WasmKit"),
    .product(name: "WasmKitWASI", package: "WasmKit"),
]
let generated = FileManager.default.fileExists(
    atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Sources/CHot").path)

var targets: [Target] = [
    .executableTarget(name: "SideloadCheck", dependencies: wasmKit, swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "SwiftFFIWasmHost", swiftSettings: isomerPackage),
    .target(name: "IsomerWasmRuntime", dependencies: ["SwiftFFIWasmHost"], swiftSettings: isomerPackage),
    .target(
        name: "IsomerWasmKitRuntime",
        dependencies: ["IsomerWasmRuntime", "SwiftFFIWasmHost", .product(name: "WasmKitWASIThreads", package: "WasmKit")] + wasmKit,
        swiftSettings: isomerPackage + [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "RuntimeCheck", dependencies: ["IsomerWasmKitRuntime", "IsomerWasmRuntime"]),
]
if generated {
    targets += [
        // wasm2c's output over WasmKit's reserved memory: guard pages, no
        // bounds checks (a native access out of bounds faults: WasmKit's trap
        // handling doesn't cover native code yet), no signal handler of its own.
        .target(
            name: "CHot",
            exclude: ["wasm-rt-impl-tableops.inc"],
            cSettings: [
                .define("WASM_RT_USE_MMAP", to: "1"),
                .define("WASM_RT_MEMCHECK_GUARD_PAGES", to: "1"),
                .define("WASM_RT_SKIP_SIGNAL_RECOVERY", to: "1"),
                .define("WASM_RT_NONCONFORMING_UNCHECKED_STACK_EXHAUSTION", to: "1"),
                .define("WASM_RT_TRAP_HANDLER", to: "iso_mixed_trap_handler"),
                .unsafeFlags(["-O2", "-w"]),
            ]),
        .executableTarget(name: "MixedCheck", dependencies: ["CHot"] + wasmKit, swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
}

let package = Package(
    name: "MixedHosts",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/pawlowskialex/WasmKit", revision: "fdbdc1ceb0c3354c4a55ae364e0706a2cdea607e"),
    ],
    targets: targets
)
