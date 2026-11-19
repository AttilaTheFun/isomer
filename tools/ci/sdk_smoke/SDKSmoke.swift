import ArgumentParser
import Foundation

@main
struct SDKSmoke: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sdk_smoke",
        abstract: "Isomer's Swift SDKs linked and run by a consumer's build (tests/sdk_consumer).",
        discussion: """
            A cell is isomer (a released version, or a checkout), Isomer's Swift
            SDKs (a release's, or a candidate's URL) in one variant, and the NDK's
            API level. `cell` writes it into the fixture, as a consumer's upgrade
            changes those lines; `build` builds the fixture's JNI library for
            Android's three architectures, its APKs and its WASI command, and runs
            the command under WasmKit; `run-android` runs an APK on an emulator.
            An upgrade is `cell` and `build` for the previous release, then for
            the candidate, in one output base.

              sdk_smoke cell --fixture tests/sdk_consumer --isomer 0.57.1 \\
                  --sdk-base-url https://github.com/AttilaTheFun/isomer_hermetic_toolchains/releases/download/isomer-6.4.2.1 \\
                  --variant i18n --api 23
              sdk_smoke build --fixture tests/sdk_consumer
              sdk_smoke run-android --fixture tests/sdk_consumer --adb adb --serial emulator-5554 \\
                  --apk bazel-bin/smoke_apk_x86_64.apk
            """,
        subcommands: [Cell.self, Build.self, RunAndroid.self]
    )
}

enum Variant: String, ExpressibleByArgument, CaseIterable {
    case plain, i18n
    /// The archive's name for the platform (sdk/build.sh's ARCHIVE_NAME).
    func archive(_ platform: String, swiftVersion: String) -> String {
        "swift-\(swiftVersion)-RELEASE_\(platform)\(self == .i18n ? "-i18n" : "").artifactbundle.tar.gz"
    }
}

struct FixtureOption: ParsableArguments {
    @Option(help: "The consumer fixture's directory (tests/sdk_consumer).")
    var fixture: String = "tests/sdk_consumer"

    var path: String { absolute(fixture) }

    /// The cell the fixture is set to: cell.bzl's values.
    func cell() throws -> (api: Int, i18n: Bool, rulesAndroid: String) {
        let text = try String(contentsOfFile: "\(path)/cell.bzl", encoding: .utf8)
        var api = 0
        var i18n = false
        var rulesAndroid = ""
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "MIN_SDK_VERSION" { api = Int(parts[1]) ?? 0 }
            if parts[0] == "I18N" { i18n = parts[1] == "True" }
            if parts[0] == "RULES_ANDROID" { rulesAndroid = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        guard api > 0 else { throw ToolFailure("\(path)/cell.bzl names no MIN_SDK_VERSION") }
        return (api, i18n, rulesAndroid)
    }
}

/// The lines a consumer changes when it upgrades, written for one cell.
struct Cell: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sets the fixture's isomer, Isomer's Swift SDKs and NDK API level, and resolves its Swift packages."
    )

    @OptionGroup var fixture: FixtureOption

    @Option(help: "isomer: a released version (from the project's registry, its tag in Package.swift), or a checkout's path.")
    var isomer: String

    @Option(help: "Where the SDKs' archives and their .sha256 files are: a release's download URL (…/releases/download/<tag>), or a file: URL.")
    var sdkBaseURL: String

    @Option(help: "The SDKs' variant.")
    var variant: Variant

    @Option(help: "The NDK's API level and the APK's minSdkVersion.")
    var api: Int

    @Option(help: "rules_android, held at the root: 0.6.0 (an older one, as an app may hold; the JNI library and the WASI command only) or 0.7.3 (isomer's; the APKs too, its tools' Maven pinned by isomer's lock file).")
    var rulesAndroid: String = "0.6.0"

    @Option(help: "The SDKs' Swift release.")
    var swiftVersion: String = "6.4.2"

    @Option(help: "swift, to resolve the fixture's Package.swift files.")
    var swift: String = "swift"

    func run() throws {
        let root = fixture.path
        let base = sdkBaseURL.hasSuffix("/") ? String(sdkBaseURL.dropLast()) : sdkBaseURL
        var sdkLines: [String] = []
        for (platform, tag) in [("android", "android_sdk"), ("wasm", "wasm_sdk")] {
            let archive = variant.archive(platform, swiftVersion: swiftVersion)
            let sha = try fetch("\(base)/\(archive).sha256").split(separator: " ").first.map(String.init) ?? ""
            guard sha.count == 64 else { throw ToolFailure("\(base)/\(archive).sha256 has no checksum") }
            sdkLines += ["_swift.\(tag)(", "    url = \"\(base)/\(archive)\",", "    sha256 = \"\(sha)\",", ")"]
        }

        // isomer: by version (the registry's module, the release's tag), or
        // a checkout (its MODULE.bazel's version, overridden by path).
        let isomerLines: [String]
        let packageLine: String
        if isomer.contains("/") {
            let checkout = absolute(isomer)
            let module = try String(contentsOfFile: "\(checkout)/MODULE.bazel", encoding: .utf8)
            guard let version = Self.moduleVersion(module) else { throw ToolFailure("\(checkout)/MODULE.bazel names no version") }
            isomerLines = [
                "bazel_dep(name = \"isomer\", version = \"\(version)\")",
                "local_path_override(", "    module_name = \"isomer\",", "    path = \"\(checkout)\",", ")",
            ]
            packageLine = ".package(path: \"\(checkout)\"),"
        } else {
            isomerLines = ["bazel_dep(name = \"isomer\", version = \"\(isomer)\")"]
            packageLine = ".package(url: \"https://github.com/AttilaTheFun/isomer.git\", revision: \"v\(isomer)\"),"
        }

        // rules_android held at the root; with isomer's own (0.7.x), its
        // tools' Maven pinned by isomer's lock file, as the examples do.
        var rulesAndroidLines = [
            "", "bazel_dep(name = \"rules_android\", version = \"\(rulesAndroid)\")",
            "single_version_override(", "    module_name = \"rules_android\",", "    version = \"\(rulesAndroid)\",", ")",
        ]
        if rulesAndroid.hasPrefix("0.7.") {
            rulesAndroidLines += [
                "", "bazel_dep(name = \"rules_jvm_external\", version = \"7.1\")",
                "_maven = use_extension(\"@rules_jvm_external//:extensions.bzl\", \"maven\")",
                "_maven.install(", "    name = \"rules_android_maven\",",
                "    aar_import_bzl_label = \"@rules_android//rules:rules.bzl\",",
                "    known_contributing_modules = [\"rules_android\"],",
                "    lock_file = \"@isomer//:rules_android_maven_install.json\",",
                "    repositories = [\"https://maven.google.com\", \"https://repo1.maven.org/maven2\"],",
                "    use_starlark_android_rules = True,", ")",
            ]
        }
        let header = "# Written by tools/ci/sdk_smoke cell (--isomer \(isomer) --variant \(variant.rawValue) --api \(api) --rules-android \(rulesAndroid))."
        let module = [header, "# What a consumer's upgrade changes: isomer, Isomer's Swift SDKs, the NDK's API level, rules_android."]
            + isomerLines + ["", "_swift = use_extension(\"@rules_swift//swift:extensions.bzl\", \"swift\")"] + sdkLines + [
                "",
                "_android = use_extension(\"@hermetic_android_toolchains//:extensions.bzl\", \"android\", dev_dependency = True)",
                "_android.ndk(", "    api_level = \(api),", "    version = \"r30\",", ")",
            ] + rulesAndroidLines
        try (module.joined(separator: "\n") + "\n").write(toFile: "\(root)/cell.MODULE.bazel", atomically: true, encoding: .utf8)
        let bzl = [
            "\"\"\"The cell's Android API level and SDK variant (\(header.dropFirst(2)))\"\"\"", "",
            "MIN_SDK_VERSION = \(api)", "I18N = \(variant == .i18n ? "True" : "False")", "RULES_ANDROID = \"\(rulesAndroid)\"",
        ]
        try (bzl.joined(separator: "\n") + "\n").write(toFile: "\(root)/cell.bzl", atomically: true, encoding: .utf8)
        let package = """
            // swift-tools-version: 5.9
            // The root's Swift packages: isomer as the cell names it (written by
            // tools/ci/sdk_smoke cell).
            import PackageDescription

            let package = Package(
                name: "sdk_consumer_swift_packages",
                platforms: [.macOS("15.0")],
                dependencies: [
                    \(packageLine)
                ]
            )

            """
        try package.write(toFile: "\(root)/third_party/swift_packages/Package.swift", atomically: true, encoding: .utf8)
        for directory in ["third_party/swift_packages", "dep/third_party/swift_packages"] {
            try runChecked([swift, "package", "resolve"], in: "\(root)/\(directory)")
        }
        print("cell: isomer \(isomer), the \(variant.rawValue) SDKs from \(base), Android API \(api)")
    }

    static func moduleVersion(_ module: String) -> String? {
        guard let start = module.range(of: "module(") else { return nil }
        let rest = module[start.upperBound...]
        guard let key = rest.range(of: "version = \"") else { return nil }
        let value = rest[key.upperBound...]
        return value.firstIndex(of: "\"").map { String(value[..<$0]) }
    }
}

/// The fixture built for every architecture, and its WASI command run.
struct Build: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Builds the fixture's JNI libraries (aarch64, x86_64), its APKs (with rules_android 0.7) and its WASI command, and runs the command."
    )

    @OptionGroup var fixture: FixtureOption

    @Option(help: "bazel (or bazelisk).")
    var bazel: String = "bazel"

    @Option(name: .customLong("startup-arg"), help: "A Bazel startup option (--output_base=…). Repeatable.")
    var startupArgs: [String] = []

    @Option(name: .customLong("bazel-arg"), help: "A Bazel build option. Repeatable.")
    var bazelArgs: [String] = []

    // armv7 isn't among the defaults: rules_swift's Android toolchain names
    // it by the NDK's triple, arm-unknown-linux-android, where the SDK's
    // modules are armv7-unknown-linux-android ("could not find module
    // 'Swift'"; TODO.md). The SDK's own build links and checks armv7.
    @Option(name: .customLong("arch"), help: "An Android architecture to link the JNI library for (aarch64, x86_64; armv7 once rules_swift builds it). Repeatable.")
    var arches: [String] = ["aarch64", "x86_64"]

    @Flag(help: "Leave out the APKs (the JNI libraries alone).")
    var noApks = false

    @Flag(help: "Leave out the WASI command.")
    var noWasm = false

    @Option(help: "A directory to copy the APKs into (smoke_<arch>.apk), for an emulator elsewhere.")
    var out: String?

    /// A target's output, by cquery, as a path outside Bazel's tree.
    func output(of target: String, _ arguments: [String], suffix: String) throws -> String {
        let execroot = try bazelCommand("info", ["execution_root"], capture: true).trimmingCharacters(in: .whitespacesAndNewlines)
        let files = try bazelCommand("cquery", ["--output=files", target] + arguments, capture: true)
        guard let relative = files.split(separator: "\n").first(where: { $0.hasSuffix(suffix) }) else {
            throw ToolFailure("no \(suffix) among \(target)'s outputs: \(files)")
        }
        return "\(execroot)/\(relative)"
    }

    @discardableResult
    func bazelCommand(_ command: String, _ arguments: [String], capture: Bool = false) throws -> String {
        try runChecked([bazel] + startupArgs + [command] + bazelArgs + arguments, in: fixture.path, capture: capture)
    }

    func run() throws {
        let cell = try fixture.cell()
        try bazelCommand("build", arches.map { "//:smoke_android_\($0)_so" })
        print("PASS the JNI library links for \(arches.joined(separator: ", ")) at Android API \(cell.api)")
        if !noApks && !cell.rulesAndroid.hasPrefix("0.7.") {
            print("(no APKs with rules_android \(cell.rulesAndroid): its tools' Maven is unpinned; a cell with --rules-android 0.7.3 builds them)")
        } else if !noApks {
            for (arch, abi) in [("aarch64", "arm64-v8a"), ("x86_64", "x86_64")] {
                let flags = ["--android_platforms=@rules_android//:\(abi)"]
                try bazelCommand("build", ["//:smoke_apk_\(arch)"] + flags)
                if let out {
                    let apk = try output(of: "//:smoke_apk_\(arch)", flags, suffix: "/smoke_apk_\(arch).apk")
                    try FileManager.default.createDirectory(atPath: absolute(out), withIntermediateDirectories: true)
                    let destination = "\(absolute(out))/smoke_\(arch).apk"
                    try? FileManager.default.removeItem(atPath: destination)
                    try FileManager.default.copyItem(atPath: apk, toPath: destination)
                    print("\(destination): \(apk)")
                }
            }
            print("PASS the APKs (arm64-v8a, x86_64), minSdkVersion \(cell.api)")
        }
        if !noWasm {
            let platform = "--platforms=@isomer//swift_ffi/rules:wasm32-wasip1"
            try bazelCommand("build", ["//smoke:smoke_command", platform])
            let module = try output(of: "//smoke:smoke_command", [platform], suffix: ".wasm")
            // A /tmp of its own (FileManager's check reads it), as the web gives one.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-smoke-wasi-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmp) }
            let output = try runChecked([bazel] + startupArgs + ["run"] + bazelArgs + ["@isomer//tools/wasm/wasi_run", "--", "--map-dir=/tmp::\(tmp)", module],
                                        in: fixture.path, capture: true)
            try check(lines: output.split(separator: "\n").map(String.init), i18n: cell.i18n, where: "the WASI command under WasmKit")
        }
    }
}

/// The checks' report, judged: every line ok, PASS last, and the -i18n
/// SDK's formatting among them where the cell is -i18n.
func check(lines: [String], i18n: Bool, where place: String) throws {
    for line in lines { print("  | \(line)") }
    let report = lines.filter { $0.hasPrefix("ok ") || $0.hasPrefix("FAIL ") || $0.hasPrefix("SDKSMOKE ") }
    guard report.last == "SDKSMOKE PASS" else { throw ToolFailure("\(place): the checks did not pass") }
    let formatted = report.contains { $0.hasPrefix("ok FoundationInternationalization") }
    guard formatted == i18n else {
        throw ToolFailure("\(place): FoundationInternationalization \(formatted ? "is there with the plain SDK" : "is missing with the -i18n SDK")")
    }
    print("PASS \(place): \(report.count - 1) checks")
}

/// An APK of the fixture's run on a device or emulator, its log read back.
struct RunAndroid: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run-android",
        abstract: "Installs and launches the fixture's APK on an emulator and reads its checks from the log."
    )

    @OptionGroup var fixture: FixtureOption

    @Option(help: "adb.")
    var adb: String = "adb"

    @Option(help: "The device's serial (emulator-5554).")
    var serial: String

    @Option(help: "The APK (bazel-bin/smoke_apk_<arch>.apk).")
    var apk: String

    @Option(help: "How long to wait for the checks, in seconds.")
    var timeout: Int = 120

    @discardableResult
    func adbRun(_ arguments: [String], capture: Bool = false) throws -> String {
        try runChecked([adb, "-s", serial] + arguments, capture: capture)
    }

    func run() throws {
        let cell = try fixture.cell()
        let apkPath = apk.hasPrefix("/") ? apk : "\(fixture.path)/\(apk)"
        try adbRun(["install", "-r", "-t", apkPath])
        try adbRun(["logcat", "-c"])
        try adbRun(["shell", "am", "start", "-W", "-n", "dev.isomer.sdksmoke/.SmokeActivity"])
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        var lines: [String] = []
        while Date() < deadline {
            let log = try adbRun(["logcat", "-d", "-s", "SDKSMOKE:I"], capture: true)
            // "I/SDKSMOKE( 1234): ok …" or the threadtime format's "… I SDKSMOKE: ok …".
            lines = log.split(separator: "\n").compactMap { line in
                guard let range = line.range(of: "SDKSMOKE") else { return nil }
                let rest = line[range.upperBound...].drop { $0 != ":" }.dropFirst()
                return rest.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            if lines.contains(where: { $0.hasPrefix("SDKSMOKE ") }) { break }
            Thread.sleep(forTimeInterval: 2)
        }
        if lines.isEmpty {
            print(try adbRun(["logcat", "-d", "-t", "200"], capture: true))
            throw ToolFailure("the app logged no checks in \(timeout) s (crashed at load?)")
        }
        let version = try adbRun(["shell", "getprop", "ro.build.version.sdk"], capture: true).trimmingCharacters(in: .whitespacesAndNewlines)
        try check(lines: lines, i18n: cell.i18n, where: "the APK on \(serial) (API \(version))")
    }
}
