"""Hermetic APK assembly: kotlinc -> d8 -> aapt2 -> jar -> zipalign -> apksigner.

No Gradle, no ANDROID_HOME, no host Java: every tool comes from the pinned
repositories declared in extensions.bzl.
"""

load("@bazel_skylib//rules:copy_file.bzl", "copy_file")
load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_android//rules:rules.bzl", "android_binary")
load("@rules_cc//cc:defs.bzl", "cc_library")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("//swift_ffi/rules:kt_swift_library.bzl", "kt_swift_library")

def _android_apk_impl(ctx):
    apk = ctx.actions.declare_file(ctx.label.name + ".apk")

    java = ctx.file._java
    jdk_home = java.dirname.rsplit("/", 1)[0]  # .../Contents/Home

    script = """
set -euo pipefail
ROOT="$PWD"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

JAVA="{java}"
mkdir -p "$WORK/classes" "$WORK/dex" "$WORK/staging"

# 1. Kotlin -> JVM class files.
"$JAVA" -cp "{kotlin_compiler}" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \\
    -nowarn -jvm-target 1.8 \\
    -classpath "{android_jar}:{kotlin_stdlib}" \\
    -d "$WORK/classes" {kotlin_srcs}

# 2. Dex (kotlin-stdlib rides along).
find "$WORK/classes" -name '*.class' > "$WORK/classlist"
"$JAVA" -cp "{d8_jar}" com.android.tools.r8.D8 --release \\
    --lib "{android_jar}" --min-api 28 \\
    --output "$WORK/dex" @"$WORK/classlist" "{kotlin_stdlib}"

# 3. Resource-less APK shell from the manifest.
"{aapt2}" link -o "$WORK/base.apk" --manifest "{manifest}" -I "{android_jar}" \\
    --min-sdk-version 28 --target-sdk-version 34

# 4. Add dex + native libraries + assets.
cp "$WORK/dex/classes.dex" "$WORK/staging/"
{native_lib_copies}
{asset_copies}
(cd "$WORK/staging" && "$ROOT/{jar}" uf ../base.apk classes.dex lib {asset_dir})

# 5. Align + sign.
"{zipalign}" -f 4 "$WORK/base.apk" "$WORK/aligned.apk"
"$JAVA" -jar "{apksigner_jar}" sign \\
    --ks "{keystore}" --ks-pass pass:android \\
    --ks-key-alias androiddebugkey --key-pass pass:android \\
    --out "{out}" "$WORK/aligned.apk"
""".format(
        java = java.path,
        kotlin_compiler = ctx.file._kotlin_compiler_jar.path,
        kotlin_stdlib = ctx.file._kotlin_stdlib_jar.path,
        android_jar = ctx.file._android_jar.path,
        kotlin_srcs = " ".join([f.path for f in ctx.files.kotlin_srcs]),
        d8_jar = ctx.file._d8_jar.path,
        aapt2 = ctx.file._aapt2.path,
        manifest = ctx.file.manifest.path,
        jar = jdk_home + "/bin/jar",
        zipalign = ctx.file._zipalign.path,
        apksigner_jar = ctx.file._apksigner_jar.path,
        keystore = ctx.file._keystore.path,
        out = apk.path,
        native_lib_copies = "\n".join([
            'mkdir -p "$WORK/staging/lib/{abi}" && cp {files} "$WORK/staging/lib/{abi}/"'.format(
                abi = abi,
                files = " ".join([f.path for f in target.files.to_list()]),
            )
            for target, abi in ctx.attr.native_libs.items()
        ]),
        asset_copies = "\n".join([
            'mkdir -p "$WORK/staging/assets" && cp {src} "$WORK/staging/assets/{name}"'.format(
                src = asset.path,
                name = asset.basename,
            )
            for asset in ctx.files.assets
        ]),
        asset_dir = "assets" if ctx.files.assets else "",
    )

    native_lib_files = []
    for target in ctx.attr.native_libs.keys():
        native_lib_files += target.files.to_list()

    ctx.actions.run_shell(
        command = script,
        inputs = depset(
            ctx.files.kotlin_srcs + ctx.files.assets + [
                ctx.file.manifest,
                ctx.file._android_jar,
                ctx.file._keystore,
            ] + native_lib_files,
            transitive = [
                ctx.attr._jdk_files.files,
                ctx.attr._kotlin_files.files,
                ctx.attr._build_tools_files.files,
            ],
        ),
        outputs = [apk],
        mnemonic = "AndroidApk",
        progress_message = "Assembling %s" % apk.basename,
    )
    return [DefaultInfo(files = depset([apk]))]

android_apk = rule(
    implementation = _android_apk_impl,
    attrs = {
        "kotlin_srcs": attr.label_list(allow_files = [".kt"], mandatory = True),
        "manifest": attr.label(allow_single_file = [".xml"], mandatory = True),
        "assets": attr.label_list(
            allow_files = True,
            doc = "Files placed under assets/ in the APK (flat basenames).",
        ),
        "native_libs": attr.label_keyed_string_dict(
            allow_files = True,
            doc = "Map of .so target -> ABI directory name (e.g. arm64-v8a).",
        ),
        "_java": attr.label(
            default = Label("@hermetic_jdk//:Contents/Home/bin/java"),
            allow_single_file = True,
        ),
        "_jdk_files": attr.label(default = Label("@hermetic_jdk//:all")),
        "_kotlin_compiler_jar": attr.label(
            default = Label("@kotlin_compiler//:lib/kotlin-compiler.jar"),
            allow_single_file = True,
        ),
        "_kotlin_stdlib_jar": attr.label(
            default = Label("@kotlin_compiler//:lib/kotlin-stdlib.jar"),
            allow_single_file = True,
        ),
        "_kotlin_files": attr.label(default = Label("@kotlin_compiler//:all")),
        "_aapt2": attr.label(
            default = Label("@android_build_tools//:aapt2"),
            allow_single_file = True,
        ),
        "_zipalign": attr.label(
            default = Label("@android_build_tools//:zipalign"),
            allow_single_file = True,
        ),
        "_d8_jar": attr.label(
            default = Label("@android_build_tools//:lib/d8.jar"),
            allow_single_file = True,
        ),
        "_apksigner_jar": attr.label(
            default = Label("@android_build_tools//:lib/apksigner.jar"),
            allow_single_file = True,
        ),
        "_build_tools_files": attr.label(default = Label("@android_build_tools//:all")),
        "_android_jar": attr.label(
            default = Label("@android_platform_jar//:android_jar"),
            allow_single_file = True,
        ),
        "_keystore": attr.label(
            default = Label("//tools/android:debug.keystore"),
            allow_single_file = True,
        ),
    },
    doc = "Assembles and signs an APK with hermetic tools.",
)

def _flat_assets_impl(ctx):
    """Flattens nested PNGs into a single directory keyed by basename.

    The app's AssetManager opens images by flat basename (e.g.
    `assets.open("iso-logo.png")`), but the source PNGs live in a nested
    `Assets.xcassets/<name>.imageset/` tree (shared with the Apple build). This
    produces a `<name>/` TreeArtifact of flat-named copies that rules_android's
    `android_binary`/`kt_android_library` packages directly into the APK's
    `assets/` (the directory's basename is the `assets_dir`).
    """
    out = ctx.actions.declare_directory(ctx.label.name)
    cmds = ['mkdir -p "%s"' % out.path]
    for f in ctx.files.srcs:
        cmds.append('cp "%s" "%s/%s"' % (f.path, out.path, f.basename))
    ctx.actions.run_shell(
        inputs = ctx.files.srcs,
        outputs = [out],
        command = " && ".join(cmds),
        mnemonic = "FlatAssets",
        progress_message = "Flattening assets into %s" % out.short_path,
    )
    return [DefaultInfo(files = depset([out]))]

flat_assets = rule(
    implementation = _flat_assets_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True, mandatory = True),
    },
    doc = "Flattens nested asset files into a single dir keyed by basename.",
)

def _app_assets_impl(ctx):
    """One assets/ directory out of an app's own assets and its fonts.

    rules_android packages ONE assets directory per library (`assets_dir`),
    so `isomer_android_app(assets = ..., fonts = ...)` merges the two here:
    each of `assets` (a directory such as a `flat_assets` target's, copied
    whole, or a file, by its basename) at the root, each of `fonts` in
    `fonts/` by its basename, where the runtime looks for `Font.custom`'s
    typefaces (HostServices.bundledTypeface), and each of `resources` in
    `bundle/`, which the runtime unpacks as Bundle.main (AppDirectories.kt).
    """
    out = ctx.actions.declare_directory(ctx.label.name)
    cmds = ['mkdir -p "%s/fonts"' % out.path]
    for f in ctx.files.assets:
        if f.is_directory:
            cmds.append('cp -R "%s/." "%s/"' % (f.path, out.path))
        else:
            cmds.append('cp "%s" "%s/%s"' % (f.path, out.path, f.basename))
    for f in ctx.files.fonts:
        cmds.append('cp "%s" "%s/fonts/%s"' % (f.path, out.path, f.basename))
    for f in ctx.files.resources:
        # As rules_apple lays out an Apple bundle's resources: each by its
        # name, in its <language>.lproj folder when it is in one.
        folder = f.dirname.rpartition("/")[2]
        place = "bundle/%s/%s" % (folder, f.basename) if folder.endswith(".lproj") else "bundle/" + f.basename
        cmds.append('mkdir -p "$(dirname "%s/%s")" && cp "%s" "%s/%s"' % (out.path, place, f.path, out.path, place))
    ctx.actions.run_shell(
        inputs = ctx.files.assets + ctx.files.fonts + ctx.files.resources,
        outputs = [out],
        command = " && ".join(cmds),
        mnemonic = "AppAssets",
        progress_message = "Merging assets and fonts into %s" % out.short_path,
    )
    return [DefaultInfo(files = depset([out]))]

_app_assets = rule(
    implementation = _app_assets_impl,
    attrs = {
        "assets": attr.label_list(allow_files = True),
        "fonts": attr.label_list(allow_files = [".ttf", ".otf"]),
        "resources": attr.label_list(allow_files = True),
    },
    doc = "An app's assets/ directory: its assets at the root, its fonts in fonts/, its bundle resources in bundle/.",
)

def apk_install_run(name, apk, activity, extras = "", **kwargs):
    """`bazel run`-able target: installs the APK via adb and launches it.
    `extras` are appended to `am start` (e.g. "--es renderer jetpackCompose"
    selects the layered renderer binding; see docs/renderer_layers.md).

    If no device/emulator is connected, the hermetic emulator is booted
    automatically (windowed) and the script waits for it before installing.
    `bazel run` starts with CWD at <runfiles>/_main, so rlocationpaths
    resolve against the parent directory.
    """
    script_name = name + "_run.sh"
    write_file(
        name = name + "_script",
        out = script_name,
        content = [
            "#!/bin/bash",
            "set -euo pipefail",
            'RUNFILES_ROOT="$PWD/.."',
            'APK="$RUNFILES_ROOT/$1"',
            'ADB="$RUNFILES_ROOT/$2"',
            'EMULATOR_SH="$RUNFILES_ROOT/$3"',
            "",
            "has_device() {",
            '  "$ADB" devices | awk \'NR>1 && $2 == "device"\' | grep -q .',
            "}",
            "",
            '"$ADB" start-server >/dev/null 2>&1 || true',
            "if ! has_device; then",
            '  echo "No device connected; booting the hermetic emulator..."',
            '  EMULATOR_LOG="${TMPDIR:-/tmp}/isomer_emulator/emulator.log"',
            '  mkdir -p "$(dirname "$EMULATOR_LOG")"',
            # The emulator script consumes args $4..$6 (emulator binary,
            # system image marker, adb) and passes the rest to the emulator.
            '  "$EMULATOR_SH" "$4" "$5" "$6" >"$EMULATOR_LOG" 2>&1 &',
            '  echo "  (emulator log: $EMULATOR_LOG)"',
            '  "$ADB" wait-for-device',
            "  for _ in $(seq 1 120); do",
            # Wait for boot AND the package manager: installing immediately
            # after sys.boot_completed flips races a "Broken pipe" failure.
            '    if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d \'\\r\')" = "1" ] && "$ADB" shell cmd package path android >/dev/null 2>&1; then break; fi',
            "    sleep 2",
            "  done",
            "  if ! has_device; then",
            '    echo "error: emulator failed to boot; see $EMULATOR_LOG" >&2',
            "    exit 1",
            "  fi",
            '  echo "Emulator booted."',
            "fi",
            '"$ADB" install -r "$APK"',
            # -S force-stops a running instance first, so switching between
            # the renderer variants of the same APK takes effect.
            '"$ADB" shell am start -S -n "{}" {}'.format(activity, extras),
            'echo "Launched {}; streaming logcat (Ctrl-C to stop)"'.format(activity),
            'exec "$ADB" logcat -s Isomer:* IsomerBridge:* AndroidRuntime:* "*:F"',
        ],
        is_executable = True,
    )
    sh_binary(
        name = name,
        srcs = [script_name],
        args = [
            "$(rlocationpath %s)" % apk,
            "$(rlocationpath %s)" % Label("@android_platform_tools//:adb") + "",
            "$(rlocationpath %s)" % Label("//tools/android/emulator:run_emulator.sh") + "",
            "$(rlocationpath %s)" % Label("@android_emulator//:emulator/emulator") + "",
            "$(rlocationpath %s)" % Label("@android_system_image//:system.img") + "",
            "$(rlocationpath %s)" % Label("@android_platform_tools//:adb") + "",
        ],
        data = [
            apk,
            Label("//tools/android/emulator:run_emulator.sh"),
            Label("@android_emulator//:all"),
            Label("@android_emulator//:emulator/emulator"),
            Label("@android_platform_tools//:adb"),
            Label("@android_system_image//:all"),
            Label("@android_system_image//:system.img"),
        ],
        **kwargs
    )

# --- Isomer adoption-level macros (docs/adoption_levels.md) ----------

# Isomer's shared platform library (//android/libraries/swift_ui:isomer_platform):
# with --@isomer//tools/android:shared_platform an app's library links
# against it, and the app ships it, instead of holding its own copy of the
# Swift runtime, Foundation and Isomer (README, "One platform library for
# several apps").
_SHARED_PLATFORM = Label("//android/libraries/swift_ui:isomer_platform")

_SHARED_PLATFORM_LIBRARIES = select({
    Label("//tools/android:shared_platform_on"): [Label("//android/libraries/swift_ui:libisomer_platform.so")],
    "//conditions:default": [],
})

def isomer_android_library(name, swift_library, extra_kotlin_srcs = [], extra_deps = [], visibility = None):
    """Level 3 building block: the app's Swift + the Isomer Android
    runtime, packaged for embedding in an existing app.

    Generates the swift_ffi JNI .so + Kotlin bindings from `swift_library`
    (which must depend on //android/libraries/swift_ui and carry the app's
    SwiftUI code, alwayslink) and compiles them together with the runtime's
    Kotlin sources (dev.isomer.runtime: IsomerView / Isomer()
    composable / IsomerFragment / IsomerRuntime).

    The app's own manifest declares the permissions: a library's
    `<uses-permission/>` never reaches the binary in Bazel's merge.
    Foundation's URLSession needs android.permission.INTERNET; with
    ACCESS_NETWORK_STATE too, a request made offline fails as
    `notConnectedToInternet` rather than `cannotFindHost`.

    Declares:
      <name>        kt_android_library — dep this from your app's Kotlin.
      <name>_native cc_library carrying the .so — dep it from android_binary.
    """
    kt_swift_library(
        name = name + "_bindings",
        java_package = "dev.isomer.runtime",
        module_name = "SwiftUI",
        swift = swift_library,
        link_deps = [Label("//android/libraries/swift_ui:application_entry")],
        shared_platform = _SHARED_PLATFORM,
        shared_platform_when = Label("//tools/android:shared_platform_on"),
    )
    cc_library(
        name = name + "_native",
        srcs = [":lib%s_bindings.so" % name] + _SHARED_PLATFORM_LIBRARIES,
        tags = ["manual"],
        visibility = visibility,
    )
    kt_android_library(
        name = name,
        srcs = [Label("//android/libraries/swift_ui:runtime_kotlin")] + extra_kotlin_srcs,
        custom_package = "dev.isomer.runtime",
        manifest = Label("//android/libraries/swift_ui:RuntimeManifest.xml"),
        plugins = [Label("//android/libraries/swift_ui:compose_compiler_plugin")],
        tags = ["manual"],
        visibility = visibility,
        deps = [
            ":%s_bindings" % name,
            Label("@rules_android_maven//:androidx_activity_activity_compose"),
            Label("@rules_android_maven//:androidx_compose_foundation_foundation"),
            Label("@rules_android_maven//:androidx_compose_material3_material3"),
            Label("@rules_android_maven//:androidx_compose_runtime_runtime"),
            Label("@rules_android_maven//:androidx_compose_ui_ui"),
            Label("@rules_android_maven//:androidx_fragment_fragment"),
            Label("@rules_android_maven//:androidx_lifecycle_lifecycle_common"),
        ] + extra_deps,
    )

def isomer_wasm_android_library(name, swift_library, visibility = None):
    """The Android `WasmView` building block: embed a wasm feature BUNDLE (not
    the app's Swift compiled directly to Android) in a Compose host.

    `swift_library` is the app's alwayslink Swift lib; it must depend on BOTH
    //android/libraries/swift_ui (the native runtime + Compose interpreter) and
    //android/libraries/wasm_view:wasm_host_bridge (the WasmKit host bridge). Two
    JNI .so's + Kotlin facades are generated from its link closure — `SwiftUIBridge`
    (drives the Compose renderer's shared services: image loading, measurement)
    and `WasmHostBridge` (`wasmStart`/`wasmSend`/`wasmResize`, running the reactor
    under WasmKit) — and compiled together with the runtime Kotlin (the shared
    Compose interpreter) and the wasm_view Kotlin (`WasmView` @Composable +
    WasmBundleProvider).

    Declares:
      <name>        kt_android_library — dep this from your app's Kotlin.
      <name>_native cc_library carrying both .so's — dep it from android_binary.
    """
    kt_swift_library(
        name = name + "_bindings",
        java_package = "dev.isomer.runtime",
        module_name = "SwiftUI",
        swift = swift_library,
    )
    kt_swift_library(
        name = name + "_wasm_bindings",
        java_package = "dev.isomer.runtime",
        module_name = "WasmHost",
        swift = swift_library,
    )
    cc_library(
        name = name + "_native",
        srcs = [
            ":lib%s_bindings.so" % name,
            ":lib%s_wasm_bindings.so" % name,
        ],
        tags = ["manual"],
        visibility = visibility,
    )
    kt_android_library(
        name = name,
        srcs = [
            Label("//android/libraries/swift_ui:runtime_kotlin"),
            Label("//android/libraries/wasm_view:runtime_kotlin"),
        ],
        custom_package = "dev.isomer.runtime",
        manifest = Label("//android/libraries/swift_ui:RuntimeManifest.xml"),
        plugins = [Label("//android/libraries/swift_ui:compose_compiler_plugin")],
        tags = ["manual"],
        visibility = visibility,
        deps = [
            ":%s_bindings" % name,
            ":%s_wasm_bindings" % name,
            Label("@rules_android_maven//:androidx_activity_activity_compose"),
            Label("@rules_android_maven//:androidx_compose_foundation_foundation"),
            Label("@rules_android_maven//:androidx_compose_material3_material3"),
            Label("@rules_android_maven//:androidx_compose_runtime_runtime"),
            Label("@rules_android_maven//:androidx_compose_ui_ui"),
            Label("@rules_android_maven//:androidx_fragment_fragment"),
            Label("@rules_android_maven//:androidx_lifecycle_lifecycle_common"),
            Label("@rules_android_maven//:org_jetbrains_kotlinx_kotlinx_coroutines_core"),
            Label("@rules_android_maven//:org_jetbrains_kotlinx_kotlinx_coroutines_android"),
        ],
    )

def isomer_android_app(
        name,
        swift_library,
        package,
        label = "Isomer",
        assets = None,
        fonts = [],
        resources = [],
        default_renderer = "jetpackCompose",
        url_scheme = None,
        services_kt = None,
        services_installer = None,
        services_deps = [],
        permissions = [],
        uses_cleartext_traffic = False,
        version_name = None,
        version_code = None,
        min_sdk_version = 28,
        extra_binary_deps = [],
        extra_application = "",
        icon = None,
        visibility = None):
    """Level 4: the whole app is SwiftUI. Generates the MainActivity and
    AndroidManifest around the app's Swift `@main App`, assembles the APK,
    and declares run targets.

    The generated activity hosts the `default_renderer` (overridable at
    launch with `--es renderer <name>`), forwards lifecycle to scenePhase,
    delivers VIEW-intent URLs to `.onOpenURL` (opt in to a scheme with
    `url_scheme`), and routes system back into the runtime.

    App-owned services (`services_kt` + `services_installer`) may need more
    than the runtime's own dependency graph: `services_deps` appends to the
    runtime kt_android_library's deps. `services_kt` is the app's Kotlin
    compiled into that library (package dev.isomer.runtime's, beside the
    runtime and the generated bindings it calls): a file or a filegroup, or
    a list of them. Kotlin that doesn't use the runtime can be a
    kt_android_library of its own, in `services_deps`; one that does is
    compiled here, since the runtime library depending on a library that
    depends on it back would be a cycle. `permissions` adds
    `<uses-permission/>` entries beyond the defaults (full names, e.g.
    "android.permission.RECORD_AUDIO"). Every app has INTERNET and
    ACCESS_NETWORK_STATE, for Foundation's URLSession (and libwebrtc, whose
    NetworkMonitor aborts the process from a native thread without the
    latter — a bare SIGABRT in jvm.cc with no Java stack); naming them
    again is harmless. `uses_cleartext_traffic = True` opts the app into
    plain-HTTP and ws: peers (targetSdk 34 blocks cleartext by default; the
    runtime's WebSocket client keeps the same policy). `version_name` ("1.2")
    and `version_code` (an integer that only grows) are the manifest's
    android:versionName / android:versionCode, what the system's app info
    shows and what an update is ordered by; left out, the APK has neither.
    `min_sdk_version` is the manifest's minSdkVersion (28 by default; down
    to 23, Swift 6.4's Android SDK's minimum, with the NDK's api_level at it
    too: README's "Android below API 28").
    `extra_binary_deps` are further android_binary deps: a native library
    the app's Kotlin loads (//android/libraries/wasm_view:engine_native,
    WasmKit for WasmView). `extra_application` is manifest XML placed
    inside `<application>`: a second activity the app's Kotlin declares.
    App-authored host views (`kind` of a PlatformViewRepresentable) are
    composables the services installer puts in `AppHostViews.factories`.
    `icon` is the launcher icon: a square PNG at 192 × 192 (the launcher's
    largest density, xxxhdpi; Android scales it down for the others), put
    in the APK as `@mipmap/ic_launcher` and named by the application's
    `android:icon` and `android:roundIcon`. Without one, Android draws its
    default.

    `assets` is what the APK's assets/ holds (a `flat_assets` directory, or
    a list of them and of files); `fonts` are .ttf/.otf files for
    `Font.custom`, put in assets/fonts/ beside them (the two merged into one
    directory, `<name>_assets`, as rules_android takes one). The runtime
    finds a font by its PostScript name, full name or family name (as
    iOS's `Font.custom` does), or by its file's name (HostServices.kt's
    `bundledTypeface`).

    `resources` are the app's bundle resources, the same list an
    `ios_application`'s `resources` takes: each file by its name, in its
    `<language>.lproj` folder when it is in one (`fr.lproj/Localizable.strings`).
    They go in the APK's assets/bundle/, which the runtime unpacks and makes
    Bundle.main's folder, so `Bundle.main.url(forResource:withExtension:)`,
    `NSLocalizedString` and `localizedString(forKey:value:table:)` read them
    (the strings tables in the device's preferred language).

    Declares:
      <name>          install + launch (default_renderer)
      <name>_apk      the android_binary

    Both Android renderers ship in the one APK and are chosen at launch:
    `--es renderer jetpackCompose` (the Compose interpreter) or `openGL` (the
    self-drawing SwiftGPURenderer). See android/README.md +
    docs/renderer_layers.md.
    """
    isomer_android_library(
        name = name + "_runtime",
        swift_library = swift_library,
        # One label or a list of them.
        extra_kotlin_srcs = (services_kt if type(services_kt) == "list" else [services_kt]) if services_kt else [],
        extra_deps = services_deps,
    )

    expand_template(
        name = name + "_main_activity",
        out = "generated/%s/MainActivity.kt" % name,
        substitutions = {
            "{PACKAGE}": package,
            "{DEFAULT_RENDERER}": default_renderer,
            # The app's dependency-injection hook: a statement run before the
            # runtime starts (e.g. `MyServices.install()`). The framework is
            # app-agnostic — services and keys belong to the app.
            "{INSTALL_SERVICES}": services_installer or "",
        },
        template = Label("//tools/android:main_activity.kt.tpl"),
    )

    intent_filters = ""
    if url_scheme:
        intent_filters = (
            "\n            <intent-filter>" +
            '\n                <action android:name="android.intent.action.VIEW" />' +
            '\n                <category android:name="android.intent.category.DEFAULT" />' +
            '\n                <category android:name="android.intent.category.BROWSABLE" />' +
            '\n                <data android:scheme="%s" />' % url_scheme +
            "\n            </intent-filter>"
        )
    # The template declares the network's two (manifest.xml.tpl).
    extra_permissions = "".join([
        '\n    <uses-permission android:name="%s" />' % permission
        for permission in permissions
        if permission not in ["android.permission.INTERNET", "android.permission.ACCESS_NETWORK_STATE"]
    ])
    application_attrs = ""
    if uses_cleartext_traffic:
        application_attrs = '\n        android:usesCleartextTraffic="true"'
    if icon:
        # A resource directory of the app's own library: res/mipmap-xxxhdpi.
        copy_file(
            name = name + "_icon",
            src = icon,
            out = "generated/%s/res/mipmap-xxxhdpi/ic_launcher.png" % name,
        )
        application_attrs += '\n        android:icon="@mipmap/ic_launcher"'
        application_attrs += '\n        android:roundIcon="@mipmap/ic_launcher"'
    version_attrs = ""
    if version_code != None:
        version_attrs += '\n    android:versionCode="%d"' % version_code
    if version_name:
        version_attrs += '\n    android:versionName="%s"' % version_name
    expand_template(
        name = name + "_manifest",
        out = "generated/%s/AndroidManifest.xml" % name,
        substitutions = {
            "{PACKAGE}": package,
            "{LABEL}": label,
            "{EXTRA_INTENT_FILTERS}": intent_filters,
            "{EXTRA_PERMISSIONS}": extra_permissions,
            "{APPLICATION_ATTRS}": application_attrs,
            "{VERSION_ATTRS}": version_attrs,
            "{MIN_SDK}": str(min_sdk_version),
            "{EXTRA_APPLICATION}": extra_application,
        },
        template = Label("//tools/android:manifest.xml.tpl"),
    )

    kt_kwargs = {}
    if icon:
        kt_kwargs["resource_files"] = [":%s_icon" % name]
    asset_list = assets if type(assets) == "list" else ([assets] if assets else [])
    if fonts or resources or len(asset_list) > 1:
        # One directory for rules_android: the assets, fonts/ and bundle/ merged.
        _app_assets(
            name = name + "_assets",
            assets = asset_list,
            fonts = fonts,
            resources = resources,
            tags = ["manual"],
        )
        kt_kwargs["assets"] = [":%s_assets" % name]
        kt_kwargs["assets_dir"] = name + "_assets"
    elif asset_list:
        # A single directory (a `flat_assets` target) goes in as it is.
        kt_kwargs["assets"] = asset_list
        kt_kwargs["assets_dir"] = asset_list[0].removeprefix(":")
    kt_android_library(
        name = name + "_app_lib",
        srcs = [":%s_main_activity" % name],
        custom_package = package,
        manifest = ":%s_manifest" % name,
        plugins = [Label("//android/libraries/swift_ui:compose_compiler_plugin")],
        tags = ["manual"],
        deps = [
            ":%s_runtime" % name,
            Label("@rules_android_maven//:androidx_activity_activity_compose"),
            Label("@rules_android_maven//:androidx_compose_runtime_runtime"),
        ],
        **kt_kwargs
    )

    android_binary(
        name = name + "_apk",
        manifest = ":%s_manifest" % name,
        visibility = visibility,
        deps = [
            ":%s_app_lib" % name,
            ":%s_runtime_native" % name,
            # Macrobenchmark's DROP_SHADER_CACHE broadcast target.
            Label("@rules_android_maven//:androidx_profileinstaller_profileinstaller"),
        ] + extra_binary_deps,
    )

    apk_install_run(
        name = name,
        activity = "%s/.MainActivity" % package,
        apk = ":%s_apk.apk" % name,
        visibility = visibility,
    )

# MARK: - An Isomer app as an Android library (AAR)

def _isomer_aar_impl(ctx):
    # The app's own classes and Isomer's: every runtime jar of the library
    # but what the host app supplies (AndroidX, Compose and Kotlin, from
    # Maven or rules_kotlin), which it would otherwise get twice.
    def supplied_by_host(jar):
        repo = jar.owner.workspace_name if jar.owner else ""
        return "maven" in repo or "kotlin" in repo or repo.startswith("rules_android")
    jars = [
        jar
        for jar in ctx.attr.lib[JavaInfo].transitive_runtime_jars.to_list()
        if not supplied_by_host(jar)
    ]
    out = ctx.actions.declare_file(ctx.label.name + ".aar")
    args = ctx.actions.args()
    args.add(ctx.executable._zipper)
    args.add(out)
    args.add(ctx.file.manifest)
    args.add(ctx.file.proguard)
    args.add(ctx.attr.abi)
    args.add("--jars")
    args.add_all(jars)
    args.add("--libs")
    args.add_all(ctx.files.native_libs)
    ctx.actions.run(
        executable = ctx.executable._assemble,
        arguments = [args],
        inputs = jars + ctx.files.native_libs + [ctx.file.manifest, ctx.file.proguard],
        tools = [ctx.executable._zipper],
        outputs = [out],
        mnemonic = "IsomerAar",
        progress_message = "Assembling %{label}'s AAR",
    )
    return [DefaultInfo(files = depset([out]))]

_isomer_aar = rule(
    implementation = _isomer_aar_impl,
    attrs = {
        "abi": attr.string(default = "arm64-v8a"),
        "lib": attr.label(providers = [JavaInfo], mandatory = True),
        "manifest": attr.label(allow_single_file = True, mandatory = True),
        "native_libs": attr.label_list(allow_files = [".so"]),
        "proguard": attr.label(allow_single_file = True, mandatory = True),
        "_assemble": attr.label(default = Label("//tools/android:assemble_aar"), executable = True, cfg = "exec"),
        "_zipper": attr.label(default = Label("@bazel_tools//tools/zip:zipper"), executable = True, cfg = "exec"),
    },
)

def isomer_android_aar(
        name,
        swift_library,
        package,
        process = None,
        min_sdk_version = 28,
        services_kt = None,
        services_installer = None,
        services_deps = [],
        visibility = None):
    """An Isomer app as an Android library (`<name>.aar`), for a host app to
    embed: the same app `isomer_android_app` makes an APK of, its entry
    `MainActivity` declared in the library's manifest (not exported, no
    launcher entry), started by the host with an explicit intent. Isomer's
    own embedding entries come with it (`IsomerFragment`, the `Isomer()`
    composable, `IsomerView`, dev.isomer.runtime).

    The AAR holds:
      classes.jar      the app's, Isomer's and the generated bindings'
                       classes (dev.isomer.**, swiftffi.**, the app's
                       package), no R classes; AndroidX, Compose and Kotlin
                       are the host's dependencies, not bundled (README
                       says which Compose the runtime is built against)
      jni/arm64-v8a/   the app's Swift (`lib<name>_runtime_bindings.so`)
      AndroidManifest.xml, proguard.txt (the consumer keeps), R.txt (empty)

    `process` runs the activity in a process of its own (":isomer", or a
    full name); no Application subclass is needed. The services arguments
    are `isomer_android_app`'s.
    """
    isomer_android_library(
        name = name + "_runtime",
        swift_library = swift_library,
        extra_kotlin_srcs = (services_kt if type(services_kt) == "list" else [services_kt]) if services_kt else [],
        extra_deps = services_deps,
    )
    expand_template(
        name = name + "_main_activity",
        out = "generated/%s/MainActivity.kt" % name,
        substitutions = {
            "{PACKAGE}": package,
            "{DEFAULT_RENDERER}": "jetpackCompose",
            "{INSTALL_SERVICES}": services_installer or "",
        },
        template = Label("//tools/android:main_activity.kt.tpl"),
    )
    expand_template(
        name = name + "_manifest",
        out = "generated/%s/AndroidManifest.xml" % name,
        substitutions = {
            "{PACKAGE}": package,
            "{MIN_SDK}": str(min_sdk_version),
            "{PROCESS_ATTR}": ('\n            android:process="%s"' % process) if process else "",
            "{PROCESS_NOTE}": (" It runs in its own process, %s." % process) if process else "",
        },
        template = Label("//tools/android:aar_manifest.xml.tpl"),
    )
    write_file(
        name = name + "_proguard",
        out = "generated/%s/proguard.txt" % name,
        content = [
            "# The consumer rules of an Isomer app (isomer_android_aar): JNI",
            "# looks Isomer's and the bindings' classes up by name.",
            "-keep class dev.isomer.** { *; }",
            "-keep class swiftffi.** { *; }",
            "-keep class %s.** { *; }" % package,
            "",
        ],
    )
    kt_android_library(
        name = name + "_lib",
        srcs = [":%s_main_activity" % name],
        custom_package = package,
        manifest = ":%s_manifest" % name,
        plugins = [Label("//android/libraries/swift_ui:compose_compiler_plugin")],
        tags = ["manual"],
        deps = [
            ":%s_runtime" % name,
            Label("@rules_android_maven//:androidx_activity_activity_compose"),
            Label("@rules_android_maven//:androidx_compose_runtime_runtime"),
        ],
    )
    _isomer_aar(
        name = name,
        lib = ":%s_lib" % name,
        manifest = ":%s_manifest" % name,
        native_libs = [":lib%s_runtime_bindings.so" % name] + _SHARED_PLATFORM_LIBRARIES,
        proguard = ":%s_proguard" % name,
        visibility = visibility,
    )
