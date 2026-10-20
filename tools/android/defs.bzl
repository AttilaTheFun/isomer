"""Hermetic APK assembly: kotlinc -> d8 -> aapt2 -> jar -> zipalign -> apksigner.

No Gradle, no ANDROID_HOME, no host Java: every tool comes from the pinned
repositories declared in extensions.bzl.
"""

load("@bazel_skylib//rules:copy_file.bzl", "copy_file")
load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_android//rules:rules.bzl", "android_binary")
load("@rules_cc//cc:defs.bzl", "cc_library")
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
    `assets.open("tab-pokedex.png")`), but the source PNGs live in a nested
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
    )
    cc_library(
        name = name + "_native",
        srcs = [":lib%s_bindings.so" % name],
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
        default_renderer = "jetpackCompose",
        url_scheme = None,
        services_kt = None,
        services_installer = None,
        services_deps = [],
        permissions = [],
        uses_cleartext_traffic = False,
        version_name = None,
        version_code = None,
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
    runtime kt_android_library's deps. `permissions` adds
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
    `extra_binary_deps` are further android_binary deps: a native library
    the app's Kotlin loads (//android/libraries/wasm_view:wamr_jni, for
    WasmView and WasiCommand). `extra_application` is manifest XML placed
    inside `<application>`: a second activity the app's Kotlin declares.
    App-authored host views (`kind` of a PlatformViewRepresentable) are
    composables the services installer puts in `AppHostViews.factories`.
    `icon` is the launcher icon: a square PNG at 192 × 192 (the launcher's
    largest density, xxxhdpi; Android scales it down for the others), put
    in the APK as `@mipmap/ic_launcher` and named by the application's
    `android:icon` and `android:roundIcon`. Without one, Android draws its
    default.

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
        extra_kotlin_srcs = [services_kt] if services_kt else [],
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
            "{EXTRA_APPLICATION}": extra_application,
        },
        template = Label("//tools/android:manifest.xml.tpl"),
    )

    kt_kwargs = {}
    if icon:
        kt_kwargs["resource_files"] = [":%s_icon" % name]
    if assets:
        kt_kwargs["assets"] = [assets]
        kt_kwargs["assets_dir"] = assets.removeprefix(":")
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
