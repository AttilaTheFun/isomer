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
            the candidate, in one output base. Run it with
            `bazel run --symlink_prefix=/ //tools/ci/sdk_smoke -- …`: a cell with isomer
            a checkout refuses one with Bazel's convenience symlinks at its root.

              sdk_smoke cell --fixture tests/sdk_consumer --isomer 0.57.1 \\
                  --sdk-base-url https://github.com/AttilaTheFun/isomer_hermetic_toolchains/releases/download/isomer-6.4.2.2 \\
                  --variant i18n --api 23
              sdk_smoke build --fixture tests/sdk_consumer --out /tmp/apks
              sdk_smoke run-android --fixture tests/sdk_consumer --adb adb --serial emulator-5554 \\
                  --apk /tmp/apks/smoke_x86_64.apk
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
        for line in text.split(whereSeparator: { $0.isNewline }) {
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
        let androidModule: Bool
        if isomer.contains("/") {
            let checkout = absolute(isomer)
            // Bazel's convenience symlinks at the checkout's root (bazel-bin,
            // bazel-<directory>, …) are inside the Isomer target of its
            // Package.swift, whose path is "." with its other directories
            // excluded: SwiftPM takes the examples' .lproj under them for
            // resources and `swift package describe` fails ("manifest property
            // 'defaultLocalization' not set"). Run this with
            // `bazel run --symlink_prefix=/`, which makes none. And none in the
            // fixture, a directory of that checkout (tests/): rules_swift_package_manager
            // copies the local package whole into the fixture's output base,
            // and a link into that output base can't be copied there (`build`
            // passes --symlink_prefix=/ too).
            for directory in [checkout, fixture.path] {
                let links = try FileManager.default.contentsOfDirectory(atPath: directory).filter { name in
                    name.hasPrefix("bazel-")
                        && (try? FileManager.default.destinationOfSymbolicLink(atPath: "\(directory)/\(name)")) != nil
                }
                guard links.isEmpty else {
                    throw ToolFailure("""
                        \(directory) has Bazel's convenience symlinks (\(links.sorted().joined(separator: ", "))), which \
                        isomer's package can't have in it: remove them, and run this with \
                        `bazel run --symlink_prefix=/ //tools/ci/sdk_smoke -- …`
                        """)
                }
            }
            let module = try String(contentsOfFile: "\(checkout)/MODULE.bazel", encoding: .utf8)
            guard let version = Self.moduleVersion(module) else { throw ToolFailure("\(checkout)/MODULE.bazel names no version") }
            var lines = [
                "bazel_dep(name = \"isomer\", version = \"\(version)\")",
                "local_path_override(", "    module_name = \"isomer\",", "    path = \"\(checkout)\",", ")",
            ]
            // Android's rules are the isomer_android module's since 0.59
            // (android/module of the checkout).
            androidModule = FileManager.default.fileExists(atPath: "\(checkout)/android/module/MODULE.bazel")
            if androidModule {
                lines += [
                    "bazel_dep(name = \"isomer_android\", version = \"\(version)\")",
                    "local_path_override(", "    module_name = \"isomer_android\",",
                    "    path = \"\(checkout)/android/module\",", ")",
                ]
            }
            // isomer's package by path is a local package that is a Bazel
            // module too, which rules_swift_package_manager 1.26.0 copies with
            // its BUILD files (rules_swift_package_manager#2638, upstream's v2):
            // the checkout's patch, applied as isomer's own root applies it.
            // A root's override can name only its own files: a copy, beside
            // the cell's other files.
            let localPackagePatch = "tools/patches/rules_swift_package_manager_local_bazel_package.patch"
            if FileManager.default.fileExists(atPath: "\(checkout)/\(localPackagePatch)") {
                let copy = "\(root)/cell_rules_swift_package_manager.patch"
                try? FileManager.default.removeItem(atPath: copy)
                try FileManager.default.copyItem(atPath: "\(checkout)/\(localPackagePatch)", toPath: copy)
                lines += [
                    "single_version_override(", "    module_name = \"rules_swift_package_manager\",",
                    "    patch_strip = 1,", "    patches = [\"//:cell_rules_swift_package_manager.patch\"],", ")",
                ]
            }
            isomerLines = lines
            packageLine = ".package(path: \"\(checkout)\"),"
        } else {
            androidModule = Self.hasAndroidModule(release: isomer)
            isomerLines = ["bazel_dep(name = \"isomer\", version = \"\(isomer)\")"]
                + (androidModule ? ["bazel_dep(name = \"isomer_android\", version = \"\(isomer)\")"] : [])
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
            // The two Maven repositories the APKs' tools take that their
            // modules leave unpinned (coursier asks Maven Central at each
            // fetch), pinned by isomer's lock files where isomer has them (a
            // checkout here; the releases after 0.57.1 have them too).
            if isomer.contains("/") {
                rulesAndroidLines += [
                    "_maven.install(", "    name = \"android_ide_common_30_1_3\",",
                    "    aar_import_bzl_label = \"@rules_android//rules:rules.bzl\",",
                    "    known_contributing_modules = [\"rules_android\"],",
                    "    lock_file = \"@isomer//:android_ide_common_30_1_3_install.json\",",
                    "    repositories = [\"https://maven.google.com\", \"https://repo1.maven.org/maven2\"],",
                    "    use_starlark_android_rules = True,", ")",
                    "_maven.install(", "    name = \"bazel_worker_maven\",",
                    "    known_contributing_modules = [\"bazel_worker_java\"],",
                    "    lock_file = \"@isomer//:bazel_worker_maven_install.json\",", ")",
                ]
            }
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
            // kt_swift_library, from where the cell's isomer has it.
            androidModule
                ? "load(\"@isomer_android//swift_ffi:kt_swift_library.bzl\", _kt_swift_library = \"kt_swift_library\")"
                : "load(\"@isomer//swift_ffi/rules:kt_swift_library.bzl\", _kt_swift_library = \"kt_swift_library\")",
            "",
            "MIN_SDK_VERSION = \(api)", "I18N = \(variant == .i18n ? "True" : "False")", "RULES_ANDROID = \"\(rulesAndroid)\"",
            "kt_swift_library = _kt_swift_library",
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

    /// Whether a release of isomer has Android's rules in the isomer_android
    /// module (0.59 on) rather than in isomer.
    static func hasAndroidModule(release: String) -> Bool {
        let parts = release.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return parts[0] > 0 || parts[1] >= 59
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

    // Maven Central has answered 404 for an artifact it has (CI's runs,
    // 2026-11-19), which Bazel takes for permanent: a build that fails is run
    // again, as a person would, before the cell fails. A real failure fails
    // twice, the second time from Bazel's cache in seconds.
    @Option(help: "How many times a build is tried before it fails the cell.")
    var attempts: Int = 2

    /// A target's output, by cquery, as a path outside Bazel's tree.
    func output(of target: String, _ arguments: [String], suffix: String) throws -> String {
        let execroot = try bazelCommand("info", ["execution_root"], capture: true).trimmingCharacters(in: .whitespacesAndNewlines)
        let files = try bazelCommand("cquery", ["--output=files", target] + arguments, capture: true)
        guard let relative = files.split(whereSeparator: { $0.isNewline }).first(where: { $0.hasSuffix(suffix) }) else {
            throw ToolFailure("no \(suffix) among \(target)'s outputs: \(files)")
        }
        return "\(execroot)/\(relative)"
    }

    @discardableResult
    func bazelCommand(_ command: String, _ arguments: [String], capture: Bool = false) throws -> String {
        // No convenience symlinks in the fixture: isomer's package, a local
        // package of the fixture's graph, is copied whole (tests/ with it)
        // into the output base, and a link into that output base can't be.
        let line = [bazel] + startupArgs + [command, "--symlink_prefix=/"] + bazelArgs + arguments
        guard command == "build" else { return try runChecked(line, in: fixture.path, capture: capture) }
        for attempt in 1..<max(attempts, 1) {
            let result = try runStatus(line, in: fixture.path, capture: capture)
            if result.status == 0 { return result.output }
            print("(the build failed with exit code \(result.status); trying again, \(attempt + 1) of \(attempts): a download may have failed)")
        }
        return try runChecked(line, in: fixture.path, capture: capture)
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
            let output = try runChecked([bazel] + startupArgs + ["run", "--symlink_prefix=/"] + bazelArgs + ["@isomer//tools/wasm/wasi_run", "--", "--map-dir=/tmp::\(tmp)", module],
                                        in: fixture.path, capture: true)
            try check(lines: output.split(whereSeparator: { $0.isNewline }).map(String.init), i18n: cell.i18n, where: "the WASI command under WasmKit")
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

    @Option(help: "How long to wait for the checks after the launch, in seconds.")
    var timeout: Int = 180

    /// adb, never waited on past `deadline` seconds (an install's are a
    /// cold emulator's; anything else answers in seconds).
    @discardableResult
    func adbRun(_ arguments: [String], capture: Bool = false, deadline: TimeInterval = 60) throws -> String {
        try runChecked([adb, "-s", serial] + arguments, capture: capture, timeout: deadline)
    }

    func run() throws {
        do {
            try launchAndCheck()
        } catch {
            // A failure, a crash or a hang ends here with its evidence, in the
            // job's log and the proof's: the crash buffer, the app's log, and
            // what the activity manager says of it.
            print("run-android failed: \(error)")
            for (title, arguments) in [
                ("logcat -b crash", ["logcat", "-b", "crash", "-d"]),
                ("logcat -b main", ["logcat", "-b", "main", "-d"]),
                ("dumpsys activity", ["shell", "dumpsys", "activity"]),
            ] {
                print("--- \(title) ---")
                let result = try? runStatus([adb, "-s", serial] + arguments, capture: true, timeout: 60)
                print(result.map { $0.status == 0 ? $0.output : "(exit \($0.status))\n\($0.output)" } ?? "(adb could not run)")
            }
            fflush(stdout)
            throw error
        }
    }

    func launchAndCheck() throws {
        let cell = try fixture.cell()
        let apkPath = apk.hasPrefix("/") ? apk : "\(fixture.path)/\(apk)"
        try adbRun(["install", "-r", "-t", apkPath], deadline: 300)
        try adbRun(["logcat", "-c"])
        // Not `am start -W`: it waits for the activity to be drawn, and the
        // smoke activity finishes in onCreate, never drawn, so -W waits on
        // for as long as anyone lets it (CI's release run hung there an hour).
        try adbRun(["shell", "am", "start", "-n", "dev.isomer.sdksmoke/.SmokeActivity"])
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        var lines: [String] = []
        while Date() < deadline {
            let log = try adbRun(["logcat", "-d", "-s", "SDKSMOKE:I"], capture: true)
            // "I/SDKSMOKE( 1234): ok …" or the threadtime format's "… I SDKSMOKE: ok …".
            // A line at a time by any newline: Android 6's adb, with no shell
            // protocol, ends its lines "\r\n", which Swift holds as one
            // Character, not "\n", so splitting at "\n" left the whole log one
            // line, and its result unseen (the release run's API-23 cells).
            lines = log.split(whereSeparator: { $0.isNewline }).compactMap { line in
                guard let range = line.range(of: "SDKSMOKE") else { return nil }
                let rest = line[range.upperBound...].drop { $0 != ":" }.dropFirst()
                return rest.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            if lines.contains(where: { $0.hasPrefix("SDKSMOKE ") }) { break }
            Thread.sleep(forTimeInterval: 2)
        }
        guard lines.contains(where: { $0.hasPrefix("SDKSMOKE ") }) else {
            for line in lines { print("  | \(line)") }
            throw ToolFailure("the app logged \(lines.isEmpty ? "no checks" : "no result") in \(timeout) s (crashed, or hung?)")
        }
        let version = try adbRun(["shell", "getprop", "ro.build.version.sdk"], capture: true).trimmingCharacters(in: .whitespacesAndNewlines)
        try check(lines: lines, i18n: cell.i18n, where: "the APK on \(serial) (API \(version))")
    }
}
