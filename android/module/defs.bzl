"""Hermetic APK assembly: kotlinc -> d8 -> aapt2 -> jar -> zipalign -> apksigner.

No Gradle, no ANDROID_HOME, no host Java: every tool comes from the pinned
repositories declared in extensions.bzl.
"""

load("@bazel_skylib//rules:copy_file.bzl", "copy_file")
load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_android//rules:rules.bzl", "android_binary")
load("@rules_cc//cc:defs.bzl", "cc_library")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("@isomer//tools/application:defs.bzl", "by_mode")
load("//swift_ffi:kt_swift_library.bzl", "kt_swift_library", "swift_platform_library")

def _android_apk_impl(ctx):
    apk = ctx.actions.declare_file(ctx.label.name + ".apk")

    java = ctx.file._java
    jdk_home = java.dirname.rsplit("/", 1)[0]  # the JDK's home (Contents/Home on a Mac)

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
            default = Label("@hermetic_jdk//:java_bin"),
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
            default = Label("@isomer//tools/android:debug.keystore"),
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

_SwiftResourcesInfo = provider(
    doc = "The `data` of a Swift library and of what it depends on: its bundle's resources.",
    fields = {"files": "depset of the files"},
)

def _bundled(f):
    # What rules_apple compiles rather than copies (an asset catalog, a
    # documentation catalog) isn't a resource here.
    return ".xcassets/" not in f.path and ".docc/" not in f.path

def _swift_resources_aspect_impl(target, ctx):
    direct = [f for f in getattr(ctx.rule.files, "data", []) if _bundled(f)]
    transitive = [dep[_SwiftResourcesInfo].files for dep in getattr(ctx.rule.attr, "deps", []) if _SwiftResourcesInfo in dep]
    return [_SwiftResourcesInfo(files = depset(direct, transitive = transitive))]

_swift_resources_aspect = aspect(
    implementation = _swift_resources_aspect_impl,
    attr_aspects = ["deps"],
    doc = "Gathers each library's `data` along `deps`, as rules_apple's resource aspect gathers an iOS app's.",
)

def _swift_resources_impl(ctx):
    # A label attribute with a Starlark transition reads as a list.
    library = ctx.attr.swift_library
    library = library[0] if type(library) == "list" else library
    return [DefaultInfo(files = library[_SwiftResourcesInfo].files)]

def _android_platform_transition_impl(_settings, _attr):
    # The app's Swift library read as it is built, for Android: on the
    # building machine's platform an Android-only library is incompatible,
    # and that made everything depending on the app's assets so (a test
    # that opens the APK). Which ABI doesn't matter: resources are the same
    # on each, except a library whose `data` is `select()`ed by CPU, which
    # gives arm64's here in an x86_64 build too.
    return {"//command_line_option:platforms": str(Label("@isomer//tools/platforms:android_arm64"))}

_android_platform_transition = transition(
    implementation = _android_platform_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

_swift_resources = rule(
    implementation = _swift_resources_impl,
    attrs = {"swift_library": attr.label(aspects = [_swift_resources_aspect], cfg = _android_platform_transition)},
    doc = """The bundle resources an app's Swift brings: the `data` of its
    `swift_library` and of every library it depends on (a strings library's
    `<language>.lproj/<Table>.strings`), as an iOS app's bundle gathers them,
    for `_app_assets` to lay out in bundle/ beside the app's own `resources`.""",
)

def _app_assets_impl(ctx):
    """One assets/ directory out of an app's own assets and its fonts.

    rules_android packages ONE assets directory per library (`assets_dir`),
    so `isomer_android_app(assets = ..., fonts = ...)` merges the two here:
    each of `assets` (a directory such as a `flat_assets` target's, copied
    whole, or a file, by its basename) at the root, each of `fonts` in
    `fonts/` by its basename, where the runtime looks for `Font.custom`'s
    typefaces (HostServices.bundledTypeface), and each of `resources` in
    `bundle/`, which the runtime unpacks as Bundle.main (AppDirectories.kt);
    `site` (an isomer_web_app's `<name>_site` directory) in `site/`, where an
    app in web-view mode serves it from (IsomerWebViewHost.kt).
    """
    out = ctx.actions.declare_directory(ctx.label.name)
    cmds = ['mkdir -p "%s/fonts"' % out.path]
    for f in ctx.files.site:
        cmds.append('mkdir -p "%s/site" && cp -RL "%s/." "%s/site/"' % (out.path, f.path, out.path))
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
        inputs = ctx.files.assets + ctx.files.fonts + ctx.files.resources + ctx.files.site,
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
        "site": attr.label_list(allow_files = True),
    },
    doc = "An app's assets/ directory: its assets at the root, its fonts in fonts/, its bundle resources in bundle/, a web app's site in site/.",
)

def isomer_android_webview_app(
        name,
        site,
        package,
        label = "Isomer",
        assets = None,
        fonts = [],
        icon = None,
        version_name = None,
        version_code = None,
        min_sdk_version = 28,
        tags = [],
        visibility = None):
    """An Android app in web-view mode (docs/modes.md): `site` (an
    isomer_web_app's `<name>_site`: its Swift as wasm, webview.html serving
    its session) in the APK's assets/site/, run in a WebView the app keeps
    out of sight, and drawn by the Compose renderer over the session protocol
    (dev.isomer.runtime.IsomerWebViewApp; IsomerWebViewHost.kt). Kotlin and
    Compose only: no Swift and no native library of Isomer's.

    Declares `<name>` (`bazel run`: install and launch), `<name>_apk` (the
    APK; `<name>_apk.apk`), and the generated activity (webview_activity.kt.tpl,
    which passes every ISO_ extra of its intent to the app as its launch
    environment).

    `assets` (a `flat_assets` directory, or files) are the head's images by
    name and `fonts` its `Font.custom` typefaces, as isomer_android_app's;
    the page measures text with the site's own fonts/. `icon` a 192 × 192
    PNG. The system WebView needs WebAssembly (Chrome 57 or later: any
    updated WebView; Android 6.0's own is too old).
    """
    expand_template(
        name = name + "_activity",
        out = "generated/%s/MainActivity.kt" % name,
        substitutions = {"{PACKAGE}": package},
        tags = tags,
        template = Label("@isomer//tools/android:webview_activity.kt.tpl"),
    )
    application_attrs = ""
    kt_kwargs = {}
    if icon:
        copy_file(
            name = name + "_icon",
            src = icon,
            out = "generated/%s/res/mipmap-xxxhdpi/ic_launcher.png" % name,
            tags = tags,
        )
        application_attrs += '\n        android:icon="@mipmap/ic_launcher"'
        application_attrs += '\n        android:roundIcon="@mipmap/ic_launcher"'
        kt_kwargs["resource_files"] = [":%s_icon" % name]
    version_attrs = ""
    if version_code != None:
        version_attrs += '\n    android:versionCode="%d"' % version_code
    if version_name != None:
        version_attrs += '\n    android:versionName="%s"' % version_name
    expand_template(
        name = name + "_manifest",
        out = "generated/%s/AndroidManifest.xml" % name,
        substitutions = {
            "{PACKAGE}": package,
            "{LABEL}": label,
            "{EXTRA_INTENT_FILTERS}": "",
            "{EXTRA_PERMISSIONS}": "",
            "{APPLICATION_ATTRS}": application_attrs,
            "{VERSION_ATTRS}": version_attrs,
            "{MIN_SDK}": str(min_sdk_version),
            "{EXTRA_APPLICATION}": "",
        },
        tags = tags,
        template = Label("@isomer//tools/android:manifest.xml.tpl"),
    )

    # One assets/ directory: the site in site/, the head's images at the
    # root and its fonts in fonts/.
    asset_list = assets if type(assets) == "list" else ([assets] if assets else [])
    _app_assets(
        name = name + "_assets",
        assets = asset_list,
        fonts = fonts,
        site = [site],
        tags = tags,
    )
    androidx = Label("@isomer//android/maven:androidx")
    kt_android_library(
        name = name + "_lib",
        srcs = [
            ":%s_activity" % name,
            # The Compose renderer as Kotlin alone (IsomerRemote and the tree
            # it draws), and the web view the app runs in.
            Label("@isomer//android/libraries/swift_ui:interpreter_kotlin"),
            Label("@isomer//android/libraries/swift_ui:webview_head_kotlin"),
        ],
        assets = [":%s_assets" % name],
        assets_dir = name + "_assets",
        custom_package = package,
        manifest = ":%s_manifest" % name,
        plugins = [Label("//swift_ui:compose_compiler_plugin")],
        tags = tags,
        deps = [androidx],
        **kt_kwargs
    )
    android_binary(
        name = name + "_apk",
        manifest = ":%s_manifest" % name,
        # The reactor stored, not deflated: read as it is from the APK.
        nocompress_extensions = [".wasm"],
        tags = tags,
        visibility = visibility,
        deps = [
            ":%s_lib" % name,
            androidx,
        ],
    )
    apk_install_run(
        name = name,
        activity = "%s/.MainActivity" % package,
        apk = ":%s_apk.apk" % name,
        tags = tags,
        visibility = visibility,
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
        testonly = kwargs.get("testonly", False),
        content = [
            "#!/bin/bash",
            "set -euo pipefail",
            # adb shell copies stdin to a device without adb's shell protocol
            # (Android 6.0, API 23) until it closes: a terminal's never does.
            "exec < /dev/null",
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
            "$(rlocationpath %s)" % Label("@isomer//tools/android/emulator:run_emulator.sh") + "",
            "$(rlocationpath %s)" % Label("@android_emulator//:emulator/emulator") + "",
            "$(rlocationpath %s)" % Label("@android_system_image//:system.img") + "",
            "$(rlocationpath %s)" % Label("@android_platform_tools//:adb") + "",
        ],
        data = [
            apk,
            Label("@isomer//tools/android/emulator:run_emulator.sh"),
            Label("@android_emulator//:all"),
            Label("@android_emulator//:emulator/emulator"),
            Label("@android_platform_tools//:adb"),
            Label("@android_system_image//:all"),
            Label("@android_system_image//:system.img"),
        ],
        **kwargs
    )

# --- Isomer adoption-level macros (docs/adoption_levels.md) ----------

# Isomer's shared platform library (@isomer_android//swift_ui:isomer_platform):
# with --@isomer//tools/android:shared_platform an app's library links
# against it, and the app ships it, instead of holding its own copy of the
# Swift runtime, Foundation and Isomer (README, "One platform library for
# several apps").
_SHARED_PLATFORM = Label("//swift_ui:isomer_platform")

_SHARED_PLATFORM_ON = Label("@isomer//tools/android:shared_platform_on")

_SHARED_PLATFORM_SO = [Label("//swift_ui:libisomer_platform.so")]

def _shared_platform_libraries(shared_platform):
    """What an app ships of the platform: libisomer_platform.so with
    `shared_platform = True`, nothing with False, and as the flag says with
    None."""
    if shared_platform == None:
        return select({
            _SHARED_PLATFORM_ON: _SHARED_PLATFORM_SO,
            "//conditions:default": [],
        })
    return _SHARED_PLATFORM_SO if shared_platform else []

def _shared_platform_args(shared_platform):
    """kt_swift_library's `shared_platform` and `shared_platform_when`: the
    platform always (True), never (False), or as the flag says (None)."""
    if shared_platform == None:
        return {"shared_platform": _SHARED_PLATFORM, "shared_platform_when": _SHARED_PLATFORM_ON}
    return {"shared_platform": _SHARED_PLATFORM if shared_platform else None, "shared_platform_when": None}

# The C++ runtime the app's libraries need (an app's `libcxx`, or
# --@isomer//swift_ffi/rules:libcxx): with `shared` the NDK's
# libc++_shared.so, which an APK ships beside them and an AAR leaves to its
# host unless --@isomer//tools/android:aar_libcxx_shared (README, "One C++
# runtime with other libraries"); nothing with `static`.
_CXX_RUNTIME = {
    None: [Label("@isomer//swift_ffi/rules:cxx_runtime")],
    "shared": [Label("@isomer//swift_ffi/rules:cxx_runtime_shared")],
    "static": [],
}

_AAR_CXX_RUNTIME = select({
    Label("@isomer//tools/android:aar_libcxx_shared_on"): [Label("@isomer//swift_ffi/rules:libc++_shared.so")],
    "//conditions:default": [],
})

def _without(deps, own):
    """`deps` less the labels in `own`: an app that lists one of the
    macro's own (Isomer's AndroidX flag, say) would otherwise make Bazel
    refuse a duplicated label."""
    if type(deps) != "list":
        return deps  # a select(): taken as it is
    return [dep for dep in deps if native.package_relative_label(dep) not in own]

def isomer_android_library(name, swift_library, extra_kotlin_srcs = [], extra_deps = [], libcxx = None, shared_platform = None, testonly = False, visibility = None):
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

    `libcxx` is the C++ runtime the app's library links: `"shared"` (the
    NDK's libc++_shared.so, which `<name>_native` carries), `"static"`, or
    None for `--@isomer//swift_ffi/rules:libcxx` (static by default).

    `shared_platform = True` links the app's library against Isomer's shared
    platform library and ships it (`<name>_native` carries
    libisomer_platform.so) whatever `--@isomer//tools/android:shared_platform`
    says: an app that takes a prebuilt library linked against the platform
    (`isomer_android_shared_library`) needs it. False never does; None (the
    default) follows the flag.

    Declares:
      <name>        kt_android_library — dep this from your app's Kotlin.
      <name>_native cc_library carrying the .so — dep it from android_binary.
    """
    kt_swift_library(
        name = name + "_bindings",
        java_package = "dev.isomer.runtime",
        module_name = "SwiftUI",
        swift = swift_library,
        link_deps = [Label("@isomer//android/libraries/swift_ui:application_entry")],
        libcxx = libcxx,
        testonly = testonly,
        **_shared_platform_args(shared_platform)
    )
    cc_library(
        name = name + "_native",
        srcs = [":lib%s_bindings.so" % name] + _shared_platform_libraries(shared_platform),
        deps = _CXX_RUNTIME[libcxx],
        tags = ["manual"],
        testonly = testonly,
        visibility = visibility,
    )
    androidx = Label("@isomer//android/maven:androidx")
    kt_android_library(
        name = name,
        srcs = [Label("@isomer//android/libraries/swift_ui:runtime_kotlin")] + extra_kotlin_srcs,
        custom_package = "dev.isomer.runtime",
        manifest = Label("@isomer//android/libraries/swift_ui:RuntimeManifest.xml"),
        plugins = [Label("//swift_ui:compose_compiler_plugin")],
        tags = ["manual"],
        testonly = testonly,
        visibility = visibility,
        deps = [
            ":%s_bindings" % name,
            # Isomer's AndroidX, or the app's own (//android/maven).
            androidx,
        ] + _without(extra_deps, [androidx]),
    )

def isomer_android_shared_library(name, deps, linkopts = [], testonly = False, visibility = None):
    """A Swift library built as a shared library of its own over Isomer's
    shared platform (`:lib<name>.so`): `deps` (alwayslink `swift_library`
    targets, built against Isomer's modules as an app's Swift is) linked
    against libisomer_platform.so, their symbols exported, none of the
    platform's linked in. What a library's author builds to ship it
    prebuilt beside apps that use the platform (docs/prebuilt_swift_libraries.md,
    "The shared platform"): the .so, with each module's .swiftinterface.

    An app takes it with `shared_platform = True` (`isomer_android_app`),
    the module through a `swift_import` (`swiftinterface`, and a `cc_import`
    of the .so among its deps) in its Swift's deps, and the .so in
    `extra_binary_deps` (a `cc_library(srcs = ["lib<name>.so"])`). The
    library and the app's platform must come from the same Isomer and the
    same Swift: it binds to the platform's symbols by name when it loads.
    """
    swift_platform_library(
        name = name,
        deps = deps,
        shared_platform = _SHARED_PLATFORM,
        linkopts = linkopts,
        testonly = testonly,
        visibility = visibility,
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
        deps = _CXX_RUNTIME[None],
        tags = ["manual"],
        visibility = visibility,
    )
    kt_android_library(
        name = name,
        srcs = [
            Label("@isomer//android/libraries/swift_ui:runtime_kotlin"),
            Label("@isomer//android/libraries/wasm_view:runtime_kotlin"),
        ],
        custom_package = "dev.isomer.runtime",
        manifest = Label("@isomer//android/libraries/swift_ui:RuntimeManifest.xml"),
        plugins = [Label("//swift_ui:compose_compiler_plugin")],
        tags = ["manual"],
        visibility = visibility,
        deps = [
            ":%s_bindings" % name,
            ":%s_wasm_bindings" % name,
            # Isomer's AndroidX, or the app's own (//android/maven).
            Label("@isomer//android/maven:androidx"),
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
        queries_packages = [],
        queries_intents = [],
        uses_cleartext_traffic = False,
        version_name = None,
        version_code = None,
        min_sdk_version = 28,
        extra_binary_deps = [],
        extra_application = "",
        icon = None,
        debug_key = None,
        minify = False,
        libcxx = None,
        shared_platform = None,
        tags = [],
        testonly = False,
        target_compatible_with = None,
        exec_compatible_with = None,
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
    the app's Kotlin loads (@isomer_android//wasm_view:engine_native,
    WasmKit for WasmView). `extra_application` is manifest XML placed
    inside `<application>`: a second activity the app's Kotlin declares.
    `queries_packages` are the other apps' packages the app looks up
    through PackageManager (their installed versions): Android 11 and later
    shows an app only those its manifest's `<queries>` names.
    `queries_intents` names apps by an intent they answer instead, for an
    app that can't list them: each a dict of `action`, and optionally
    `category` and `scheme` (`{"action": "android.intent.action.MAIN",
    "category": "android.intent.category.LAUNCHER"}`, every app with a
    launcher entry).
    App-authored host views (`kind` of a PlatformViewRepresentable) are
    composables the services installer puts in `AppHostViews.factories`.
    `icon` is the launcher icon: a square PNG at 192 × 192 (the launcher's
    largest density, xxxhdpi; Android scales it down for the others), put
    in the APK as `@mipmap/ic_launcher` and named by the application's
    `android:icon` and `android:roundIcon`. Without one, Android draws its
    default.

    `libcxx = "shared"` links the app's Swift against the NDK's
    `libc++_shared.so` and ships it in the APK's lib/<abi>/, for an app
    whose Swift shares C++ objects with another shared library (README,
    "One C++ runtime with other libraries"); `"static"` keeps libc++ inside
    the app's library; None (the default) follows
    `--@isomer//swift_ffi/rules:libcxx`, static unless it says otherwise.

    `shared_platform = True` links the app's Swift against Isomer's shared
    platform library, libisomer_platform.so, and ships it, whatever
    `--@isomer//tools/android:shared_platform` says (False: never; None, the
    default: as the flag says). An app that takes a prebuilt Swift library
    linked against the platform (`isomer_android_shared_library`, in
    `extra_binary_deps`) sets it: docs/prebuilt_swift_libraries.md.

    `debug_key` is the keystore a debug build is signed with (android_binary's
    `debug_key`; rules_android's own debug key without one).

    `minify = True` shrinks the APK's dex with R8 (android_binary's
    `proguard_specs`): only what the app's Kotlin, the runtime and the
    libraries' own consumer rules reach is dexed, the runtime and the
    bindings (which JNI finds by name) kept whole and nothing renamed, so
    stack traces read as written. Without it every class of Compose and
    AndroidX is dexed, about 22 MB (README, "Android release size"): on a
    small emulator dex2oat can run out of space compiling it, and ART then
    interprets the app. A build with it takes R8's time (tens of seconds);
    an app that ships its own rules gives them in `proguard_specs`. `tags`,
    `target_compatible_with` and `exec_compatible_with` go to the APK and
    the run target (`tags = ["manual"]` keeps a wildcard build from building
    the app; the targets beneath them are manual already), `testonly` to
    every target the macro makes.

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
    # What the targets users build and run take; the rest are manual.
    outer = {"tags": tags, "testonly": testonly}
    if target_compatible_with != None:
        outer["target_compatible_with"] = target_compatible_with
    if exec_compatible_with != None:
        outer["exec_compatible_with"] = exec_compatible_with

    isomer_android_library(
        name = name + "_runtime",
        swift_library = swift_library,
        # One label or a list of them.
        extra_kotlin_srcs = (services_kt if type(services_kt) == "list" else [services_kt]) if services_kt else [],
        extra_deps = services_deps,
        libcxx = libcxx,
        shared_platform = shared_platform,
        testonly = testonly,
    )

    expand_template(
        name = name + "_main_activity",
        out = "generated/%s/MainActivity.kt" % name,
        testonly = testonly,
        substitutions = {
            "{PACKAGE}": package,
            "{DEFAULT_RENDERER}": default_renderer,
            # The app's dependency-injection hook: a statement run before the
            # runtime starts (e.g. `MyServices.install()`). The framework is
            # app-agnostic — services and keys belong to the app.
            "{INSTALL_SERVICES}": services_installer or "",
        },
        template = Label("@isomer//tools/android:main_activity.kt.tpl"),
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
    # The other apps the app looks up (PackageManager: their installed
    # versions, whether they're there): Android 11 and later shows an app
    # only the packages its manifest's <queries> names, a child of
    # <manifest>, where the permissions are.
    if queries_packages or queries_intents:
        entries = ['\n        <package android:name="%s" />' % package_name for package_name in queries_packages]
        for intent in queries_intents:
            # An intent the apps it looks for answer (MAIN in LAUNCHER: any
            # app with a launcher entry), where it can't name them.
            lines = ['\n        <intent>', '\n            <action android:name="%s" />' % intent["action"]]
            if intent.get("category"):
                lines.append('\n            <category android:name="%s" />' % intent["category"])
            if intent.get("scheme"):
                lines.append('\n            <data android:scheme="%s" />' % intent["scheme"])
            entries.append("".join(lines) + "\n        </intent>")
        extra_permissions += "\n\n    <queries>" + "".join(entries) + "\n    </queries>"
    application_attrs = ""
    if uses_cleartext_traffic:
        application_attrs = '\n        android:usesCleartextTraffic="true"'
    if icon:
        # A resource directory of the app's own library: res/mipmap-xxxhdpi.
        copy_file(
            name = name + "_icon",
            src = icon,
            out = "generated/%s/res/mipmap-xxxhdpi/ic_launcher.png" % name,
            testonly = testonly,
        )
        application_attrs += '\n        android:icon="@mipmap/ic_launcher"'
        application_attrs += '\n        android:roundIcon="@mipmap/ic_launcher"'
    version_attrs = ""
    if version_code != None:
        version_attrs += '\n    android:versionCode="%d"' % version_code
    if version_name:
        version_attrs += '\n    android:versionName="%s"' % version_name
    substitutions = {
        "{PACKAGE}": package,
        "{LABEL}": label,
        "{EXTRA_INTENT_FILTERS}": intent_filters,
        "{EXTRA_PERMISSIONS}": extra_permissions,
        "{APPLICATION_ATTRS}": application_attrs,
        "{VERSION_ATTRS}": version_attrs,
        "{MIN_SDK}": str(min_sdk_version),
        "{EXTRA_APPLICATION}": extra_application,
    }
    # A headful build (--@isomer//drive:headful, never a release) dials out
    # to a test's hub over plain ws:// on the device's loopback (adb reverse),
    # which the runtime's WebSocket client refuses unless the app allows
    # cleartext: such a build does.
    headful = dict(substitutions)
    if not uses_cleartext_traffic:
        headful["{APPLICATION_ATTRS}"] = '\n        android:usesCleartextTraffic="true"' + application_attrs
    expand_template(
        name = name + "_manifest",
        out = "generated/%s/AndroidManifest.xml" % name,
        testonly = testonly,
        substitutions = select({
            Label("@isomer//drive:headful_on"): headful,
            "//conditions:default": substitutions,
        }),
        template = Label("@isomer//tools/android:manifest.xml.tpl"),
    )

    kt_kwargs = {}
    if icon:
        kt_kwargs["resource_files"] = [":%s_icon" % name]
    asset_list = assets if type(assets) == "list" else ([assets] if assets else [])
    # The app's Swift libraries' own resources (their `data`), as an iOS
    # app's bundle gathers them: whether there are any is known only when
    # the libraries are analysed, so the assets are always merged.
    _swift_resources(
        name = name + "_swift_resources",
        swift_library = swift_library,
        tags = ["manual"],
        testonly = testonly,
    )
    # One directory for rules_android: the assets, fonts/ and bundle/ merged.
    _app_assets(
        name = name + "_assets",
        assets = asset_list,
        fonts = fonts,
        resources = resources + [":%s_swift_resources" % name],
        tags = ["manual"],
        testonly = testonly,
    )
    kt_kwargs["assets"] = [":%s_assets" % name]
    kt_kwargs["assets_dir"] = name + "_assets"
    kt_android_library(
        name = name + "_app_lib",
        srcs = [":%s_main_activity" % name],
        custom_package = package,
        manifest = ":%s_manifest" % name,
        plugins = [Label("//swift_ui:compose_compiler_plugin")],
        tags = ["manual"],
        testonly = testonly,
        deps = [
            ":%s_runtime" % name,
            # Isomer's AndroidX, or the app's own (//android/maven).
            Label("@isomer//android/maven:androidx"),
        ],
        **kt_kwargs
    )

    androidx = Label("@isomer//android/maven:androidx")
    binary_kwargs = {}
    if minify:
        write_file(
            name = name + "_keep",
            out = "generated/%s/keep.pro" % name,
            content = [
                "# isomer_android_app(minify = True): JNI looks Isomer's and the",
                "# bindings' classes up by name; the libraries' own rules come",
                "# with their AARs. Shrunk only: nothing renamed.",
                "-keep class dev.isomer.** { *; }",
                "-keep class swiftffi.** { *; }",
                "-keep class %s.** { *; }" % package,
                "-dontobfuscate",
                "",
            ],
            tags = ["manual"],
            testonly = testonly,
        )
        binary_kwargs["proguard_specs"] = [":%s_keep" % name]
    android_binary(
        name = name + "_apk",
        manifest = ":%s_manifest" % name,
        debug_key = debug_key,
        visibility = visibility,
        deps = [
            ":%s_app_lib" % name,
            ":%s_runtime_native" % name,
            # Isomer's AndroidX, or the app's own (//android/maven):
            # ProfileInstaller among it, Macrobenchmark's DROP_SHADER_CACHE
            # broadcast target.
            androidx,
        ] + _without(extra_binary_deps, [androidx]),
        **dict(outer, **binary_kwargs)
    )

    apk_install_run(
        name = name,
        activity = "%s/.MainActivity" % package,
        apk = ":%s_apk.apk" % name,
        visibility = visibility,
        **outer
    )

# MARK: - An Isomer app as an Android library (AAR)

def _supplied_by_name(jar):
    """The default test for a jar the host supplies: one of a Maven
    repository's (AndroidX, Compose) or rules_kotlin's or rules_android's
    (Kotlin's standard library), by its repository's name."""
    repo = jar.owner.workspace_name if jar.owner else ""
    return "maven" in repo or "kotlin" in repo or repo.startswith("rules_android")

# The platform each ABI's libraries are built for (tools/platforms).
_ABI_PLATFORMS = {
    "arm64-v8a": Label("@isomer//tools/platforms:android_arm64"),
    "x86_64": Label("@isomer//tools/platforms:android_x86_64"),
}

def _native_libs_transition_impl(_settings, attr):
    # A cc target in `extra_native_libs` is built for the AAR's ABI, as
    # android_binary builds its cc deps for its own; a .so file is as it is.
    return {"//command_line_option:platforms": str(_ABI_PLATFORMS[attr.abi])}

_native_libs_transition = transition(
    implementation = _native_libs_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _shared_libraries(target):
    """The shared libraries a target in `extra_native_libs` gives: its own
    .so files (a file, a `cc_binary(linkshared = True)`), and the prebuilt
    ones its CcInfo links (a `cc_library` over .so files: a library with
    no static archive beside it). A cc_library compiled from source is
    linked into a library, not packed whole: android_binary would link it
    into the app's, which an AAR has none of."""
    libs = [f for f in target[DefaultInfo].files.to_list() if f.extension == "so"]
    if CcInfo in target:
        for linker_input in target[CcInfo].linking_context.linker_inputs.to_list():
            for library in linker_input.libraries:
                if library.static_library or library.pic_static_library:
                    continue
                lib = library.resolved_symlink_dynamic_library or library.dynamic_library
                if lib:
                    libs.append(lib)
    return libs

def _isomer_aar_impl(ctx):
    # The app's own classes and Isomer's: every runtime jar of the library
    # but what the host app supplies, which it would otherwise get twice.
    # That is every runtime jar of `provided_deps` (theirs and their
    # dependencies'), and, unless `provided_by_name` is off, the jars of
    # Maven's, rules_kotlin's and rules_android's repositories (AndroidX,
    # Compose and Kotlin). A neverlink library (an android_library or
    # java_library with `neverlink = True`, compiled against and never
    # shipped) is left out by JavaInfo itself: it adds no runtime jars.
    provided = depset(transitive = [
        dep[JavaInfo].transitive_runtime_jars
        for dep in ctx.attr.provided_deps
    ]).to_list()
    provided_set = {jar: True for jar in provided}
    jars = [
        jar
        for jar in ctx.attr.lib[JavaInfo].transitive_runtime_jars.to_list()
        if jar not in provided_set and not (ctx.attr.provided_by_name and _supplied_by_name(jar))
    ]

    # The libraries in jni/<abi>/, each by its file's name, once: the app's
    # and the platform's, then the further ones (`extra_native_libs`).
    libs = []
    names = {}
    for lib in ctx.files.native_libs + [lib for target in ctx.attr.extra_native_libs for lib in _shared_libraries(target)]:
        if lib.basename in names:
            if names[lib.basename] != lib.path:
                fail("two libraries named %s in %s's jni/%s: %s and %s" % (lib.basename, ctx.label.name, ctx.attr.abi, names[lib.basename], lib.path))
            continue
        names[lib.basename] = lib.path
        libs.append(lib)

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
    args.add_all(libs)
    if ctx.file.assets:
        # The merged directory (_app_assets) whole, not its files: the
        # script copies it into the AAR's assets/.
        args.add("--assets")
        args.add_all([ctx.file.assets], expand_directories = False)
    ctx.actions.run(
        executable = ctx.executable._assemble,
        arguments = [args],
        inputs = jars + libs + ctx.files.assets + [ctx.file.manifest, ctx.file.proguard],
        tools = [ctx.executable._zipper],
        outputs = [out],
        mnemonic = "IsomerAar",
        progress_message = "Assembling %{label}'s AAR",
    )
    return [DefaultInfo(files = depset([out]))]

_isomer_aar = rule(
    implementation = _isomer_aar_impl,
    attrs = {
        "abi": attr.string(default = "arm64-v8a", values = _ABI_PLATFORMS.keys()),
        "assets": attr.label(allow_single_file = True, doc = "The assets/ directory (an _app_assets target's)."),
        "extra_native_libs": attr.label_list(
            # Any target: a cc_library over prebuilt libraries gives no .so
            # among its files (_shared_libraries finds them in its CcInfo).
            allow_files = True,
            cfg = _native_libs_transition,
            doc = "Further shared libraries for jni/<abi>/: .so files, or targets giving them.",
        ),
        "lib": attr.label(providers = [JavaInfo], mandatory = True),
        "manifest": attr.label(allow_single_file = True, mandatory = True),
        "native_libs": attr.label_list(allow_files = [".so"]),
        "proguard": attr.label(allow_single_file = True, mandatory = True),
        "provided_by_name": attr.bool(
            default = True,
            doc = "Leave out the jars of repositories named for Maven, rules_kotlin or rules_android.",
        ),
        "provided_deps": attr.label_list(
            providers = [JavaInfo],
            doc = "Libraries the host supplies: their runtime jars, transitively, are left out of classes.jar.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
        "_assemble": attr.label(default = Label("@isomer//tools/android:assemble_aar"), executable = True, cfg = "exec"),
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
        provided_deps = [],
        provided_by_name = True,
        assets = None,
        fonts = [],
        resources = [],
        extra_native_libs = [],
        libcxx = None,
        shared_platform = None,
        tags = [],
        testonly = False,
        target_compatible_with = None,
        exec_compatible_with = None,
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
      jni/arm64-v8a/   the app's Swift (`lib<name>_runtime_bindings.so`),
                       and `extra_native_libs`
      assets/          `assets`, `fonts` and `resources`, when given
      AndroidManifest.xml, proguard.txt (the consumer keeps), R.txt (empty)

    `process` runs the activity in a process of its own (":isomer", or a
    full name); no Application subclass is needed. The services arguments
    are `isomer_android_app`'s.

    What the host supplies stays out of classes.jar. By default that is
    every jar of a repository named for Maven, rules_kotlin or
    rules_android (`provided_by_name`): AndroidX, Compose and Kotlin, from
    Isomer's Maven set or the app's own (docs/android_maven.md). A host
    whose own libraries reach the app another way (its SDK in
    `services_deps`, a Maven repository named otherwise) lists them in
    `provided_deps`: their runtime jars and their dependencies' are left
    out. A neverlink library (`neverlink = True`) is never packed: Bazel
    gives it no runtime jars. `provided_by_name = False` turns the names
    off, leaving out `provided_deps` alone.

    `assets`, `fonts` and `resources` are `isomer_android_app`'s, laid out
    as its APK has them (`<name>_assets`): `assets` at the root of the
    AAR's assets/, `fonts` in assets/fonts/ (`Font.custom`), `resources` in
    assets/bundle/ (Bundle.main). The host's build merges them into its
    APK's assets/, beside its own: a host embedding two Isomer apps gets
    one assets/fonts/ and one assets/bundle/ for both.

    `extra_native_libs` are further shared libraries for jni/<abi>/, as
    `isomer_android_app`'s `extra_binary_deps` puts them in its APK: .so
    files, `cc_binary(linkshared = True)` targets, or `cc_library` targets
    over prebuilt .so files, built for the AAR's ABI.

    `libcxx` is the C++ runtime the app's Swift links, as
    `isomer_android_app`'s: `"shared"` the NDK's libc++_shared.so (for a host
    whose own native libraries share C++ objects with the app's, built with
    `c++_shared`: README, "One C++ runtime with other libraries"),
    `"static"`, or None for `--@isomer//swift_ffi/rules:libcxx` (static by
    default). With `shared` the host's APK ships libc++_shared.so, as the
    host's own libraries need it too; the AAR carries a copy only with
    `--@isomer//tools/android:aar_libcxx_shared`.

    `shared_platform` is `isomer_android_app`'s: True puts libisomer_platform.so
    in jni/<abi>/ and links the app's library against it, for a prebuilt
    library linked against the platform in `extra_native_libs`.

    `tags`, `target_compatible_with` and `exec_compatible_with` go to the
    AAR (`tags = ["manual"]` keeps a wildcard build from building it; the
    targets beneath it are manual already), `testonly` to every target the
    macro makes, as `isomer_android_app`'s do.
    """
    outer = {"tags": tags, "testonly": testonly}
    if target_compatible_with != None:
        outer["target_compatible_with"] = target_compatible_with
    if exec_compatible_with != None:
        outer["exec_compatible_with"] = exec_compatible_with

    isomer_android_library(
        name = name + "_runtime",
        swift_library = swift_library,
        extra_kotlin_srcs = (services_kt if type(services_kt) == "list" else [services_kt]) if services_kt else [],
        extra_deps = services_deps,
        libcxx = libcxx,
        shared_platform = shared_platform,
        testonly = testonly,
    )
    expand_template(
        name = name + "_main_activity",
        out = "generated/%s/MainActivity.kt" % name,
        substitutions = {
            "{PACKAGE}": package,
            "{DEFAULT_RENDERER}": "jetpackCompose",
            "{INSTALL_SERVICES}": services_installer or "",
        },
        tags = ["manual"],
        template = Label("@isomer//tools/android:main_activity.kt.tpl"),
        testonly = testonly,
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
        tags = ["manual"],
        template = Label("@isomer//tools/android:aar_manifest.xml.tpl"),
        testonly = testonly,
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
        tags = ["manual"],
        testonly = testonly,
    )
    asset_list = assets if type(assets) == "list" else ([assets] if assets else [])
    # The APK's assets/ directory, as isomer_android_app merges it, the app's
    # Swift libraries' resources included.
    _swift_resources(
        name = name + "_swift_resources",
        swift_library = swift_library,
        tags = ["manual"],
        testonly = testonly,
    )
    _app_assets(
        name = name + "_assets",
        assets = asset_list,
        fonts = fonts,
        resources = resources + [":%s_swift_resources" % name],
        tags = ["manual"],
        testonly = testonly,
    )
    aar_assets = ":%s_assets" % name
    kt_android_library(
        name = name + "_lib",
        srcs = [":%s_main_activity" % name],
        custom_package = package,
        manifest = ":%s_manifest" % name,
        plugins = [Label("//swift_ui:compose_compiler_plugin")],
        tags = ["manual"],
        testonly = testonly,
        deps = [
            ":%s_runtime" % name,
            # Isomer's AndroidX, or the app's own (//android/maven).
            Label("@isomer//android/maven:androidx"),
        ],
    )
    _isomer_aar(
        name = name,
        assets = aar_assets,
        extra_native_libs = extra_native_libs,
        lib = ":%s_lib" % name,
        manifest = ":%s_manifest" % name,
        native_libs = [":lib%s_runtime_bindings.so" % name] + _shared_platform_libraries(shared_platform) + _AAR_CXX_RUNTIME,
        proguard = ":%s_proguard" % name,
        provided_by_name = provided_by_name,
        provided_deps = provided_deps,
        visibility = visibility,
        **outer
    )

# --- isomer_application's Android half -----------------------------------------

def _declare(
        app,
        platforms,
        android_icon,
        android_assets,
        min_sdk_version,
        android_remote_url):
    _android(
        name = app.name,
        swift_library = app.swift_library,
        package = app.package,
        display_name = app.display_name,
        version = app.version,
        build = app.build,
        icon = android_icon,
        assets = android_assets,
        fonts = app.fonts,
        resources = app.resources,
        min_sdk_version = min_sdk_version,
        remote_url = android_remote_url or app.remote_url.replace("127.0.0.1", "10.0.2.2").replace("localhost", "10.0.2.2"),
        site = app.site,
        tags = app.tags,
        manual = app.manual,
        visibility = app.visibility,
    )

# Android, for isomer_application's `platforms` (@isomer//tools/application:
# defs.bzl). Declares, in each mode:
#
#   <name>_android   `bazel run`: install and launch, in the build's mode;
#   <name>_android_apk  the APK:
#     <name>_android_compiled[_apk]  isomer_android_app
#     <name>_android_remote[_apk]    a generated Kotlin shell over
#                                    IsomerRemote (remote_activity.kt.tpl;
#                                    the session's URL the intent's `url`
#                                    extra, else `android_remote_url`): no
#                                    Swift, no native library
#     <name>_android_webview[_apk]   the web app's site in the APK's
#                                    assets, run in a WebView and drawn by
#                                    the Compose renderer
#                                    (isomer_android_webview_app,
#                                    IsomerWebViewApp): no Swift, no native
#                                    library
#
# Its arguments: `android_icon` (a 192 × 192 PNG, as isomer_android_app's
# `icon`), `android_assets` (the compiled and web-view apps' `assets`),
# `min_sdk_version`, and `android_remote_url` (by default the app's
# `remote_url` with its loopback host as an emulator reaches it, 10.0.2.2).
# `fonts` go to the compiled and web-view apps, `resources` to the compiled
# app (the remote shell carries none yet).
ANDROID = struct(
    name = "android",
    module = "isomer_android",
    attrs = {
        "android_assets": None,
        "android_icon": None,
        "android_remote_url": None,
        "min_sdk_version": 28,
    },
    declare = _declare,
)

def _android(
        name,
        swift_library,
        package,
        display_name,
        version,
        build,
        icon,
        assets,
        fonts,
        resources,
        min_sdk_version,
        remote_url,
        site,
        tags,
        manual,
        visibility):
    # compiled: the app's Swift in the APK, under the Compose renderer.
    isomer_android_app(
        name = name + "_android_compiled",
        assets = assets,
        fonts = fonts,
        icon = icon,
        label = display_name,
        min_sdk_version = min_sdk_version,
        package = package,
        resources = resources,
        swift_library = swift_library,
        tags = manual,
        version_code = build,
        version_name = version,
    )

    # remote: Kotlin and Compose only, drawing the app's session.
    remote = name + "_android_remote"
    expand_template(
        name = remote + "_activity",
        out = "generated/%s/MainActivity.kt" % remote,
        substitutions = {
            "{PACKAGE}": package,
            "{REMOTE_URL}": remote_url,
        },
        tags = manual,
        template = Label("@isomer//tools/application:remote_activity.kt.tpl"),
    )

    # isomer_android_app's manifest, the session's plain ws: allowed.
    application_attrs = '\n        android:usesCleartextTraffic="true"'
    kt_kwargs = {}
    if icon:
        copy_file(
            name = remote + "_icon",
            src = icon,
            out = "generated/%s/res/mipmap-xxxhdpi/ic_launcher.png" % remote,
            tags = manual,
        )
        application_attrs += '\n        android:icon="@mipmap/ic_launcher"'
        application_attrs += '\n        android:roundIcon="@mipmap/ic_launcher"'
        kt_kwargs["resource_files"] = [":%s_icon" % remote]
    expand_template(
        name = remote + "_manifest",
        out = "generated/%s/AndroidManifest.xml" % remote,
        substitutions = {
            "{PACKAGE}": package,
            "{LABEL}": display_name,
            "{EXTRA_INTENT_FILTERS}": "",
            "{EXTRA_PERMISSIONS}": "",
            "{APPLICATION_ATTRS}": application_attrs,
            "{VERSION_ATTRS}": '\n    android:versionCode="%d"\n    android:versionName="%s"' % (build, version),
            "{MIN_SDK}": str(min_sdk_version),
            "{EXTRA_APPLICATION}": "",
        },
        tags = manual,
        template = Label("@isomer//tools/android:manifest.xml.tpl"),
    )
    androidx = Label("@isomer//android/maven:androidx")
    kt_android_library(
        name = remote + "_lib",
        srcs = [
            ":%s_activity" % remote,
            # The Compose renderer, as Kotlin alone: IsomerRemote and the
            # tree it draws.
            Label("@isomer//android/libraries/swift_ui:interpreter_kotlin"),
        ],
        custom_package = package,
        manifest = ":%s_manifest" % remote,
        plugins = [Label("//swift_ui:compose_compiler_plugin")],
        tags = manual,
        deps = [androidx],
        **kt_kwargs
    )
    android_binary(
        name = remote + "_apk",
        manifest = ":%s_manifest" % remote,
        tags = manual,
        deps = [
            ":%s_lib" % remote,
            androidx,
        ],
    )
    apk_install_run(
        name = remote,
        activity = "%s/.MainActivity" % package,
        apk = ":%s_apk.apk" % remote,
        tags = manual,
    )

    # webview: the web app's site in the APK, Kotlin and Compose only.
    isomer_android_webview_app(
        name = name + "_android_webview",
        assets = assets,
        fonts = fonts,
        icon = icon,
        label = display_name,
        min_sdk_version = min_sdk_version,
        package = package,
        site = site,
        tags = manual,
        version_code = build,
        version_name = version,
    )

    native.alias(
        name = name + "_android",
        actual = by_mode({
            "compiled": ":%s_android_compiled" % name,
            "webview": ":%s_android_webview" % name,
            "remote": ":" + remote,
        }),
        tags = tags,
        visibility = visibility,
    )
    native.alias(
        name = name + "_android_apk",
        actual = by_mode({
            "compiled": ":%s_android_compiled_apk" % name,
            "webview": ":%s_android_webview_apk" % name,
            "remote": ":%s_apk" % remote,
        }),
        tags = tags,
        visibility = visibility,
    )
