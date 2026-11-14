"""isomer_application: one Isomer app, every platform's targets, in the mode
`--@isomer//:mode` names (docs/modes.md).

An Isomer app is a Swift library holding a SwiftUI `@main App`. How its
Swift runs is a build's choice, not the app's code:

  compiled  natively, in each platform's app (the default)
  webview   as wasm, in a web view the app keeps out of sight, drawn by
            the app's head over the session protocol
  remote    elsewhere (built headless, serving itself), the app only a head

The macro declares each platform's app once a mode, and, under the
platform's own name, the one `--@isomer//:mode` picks; the web is wasm in
every mode.
"""

load("@bazel_skylib//rules:copy_file.bzl", "copy_file")
load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application")
load("@build_bazel_rules_apple//apple:macos.bzl", "macos_application")
load("@rules_android//rules:rules.bzl", "android_binary")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")
# Named apart: the macros take the app's library as `swift_library`.
load("@rules_swift//swift:swift.bzl", swift_library_rule = "swift_library")
load("@rules_swift//swift:swift_binary.bzl", "swift_binary")
load("//tools/android:defs.bzl", "apk_install_run", "isomer_android_app")
load("//tools/wasm:defs.bzl", "isomer_web_app")

_MODES = ["compiled", "webview", "remote"]

_PLATFORMS = ["ios", "macos", "android", "web"]

def _by_mode(targets):
    """A select() over --@isomer//:mode: `targets` maps each mode to what
    the platform's own name is in it."""
    return select({
        Label("//:mode_" + mode): targets[mode]
        for mode in _MODES
    })

def _plist(name, entries, tags):
    """An Info.plist of `entries` (each a key's XML and its value's), merged
    by rules_apple with the app's own `infoplists`."""
    write_file(
        name = name,
        out = name + ".plist",
        content = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
            '<plist version="1.0">',
            "<dict>",
        ] + entries + [
            "</dict>",
            "</plist>",
            "",
        ],
        tags = tags,
    )

def _identifier(name):
    """`name` as a Swift module name: letters, digits and underscores."""
    return "".join([c if c.isalnum() else "_" for c in name.elems()])

def isomer_application(
        name,
        swift_library,
        bundle_id,
        display_name,
        package = None,
        version = "1.0",
        build = 1,
        platforms = _PLATFORMS,
        minimum_ios_version = "18.0",
        minimum_macos_version = "15.0",
        families = ["iphone", "ipad"],
        app_icons = [],
        infoplists = [],
        resources = [],
        fonts = [],
        ios_provisioning_profile = None,
        android_icon = None,
        android_assets = None,
        min_sdk_version = 28,
        web_index = None,
        web_assets = [],
        remote_url = "ws://127.0.0.1:8090/session",
        android_remote_url = None,
        tags = [],
        visibility = None):
    """One Isomer app's targets on every platform, in each mode
    (docs/modes.md, "The setting").

    `swift_library` is the app: its SwiftUI `@main App`, `alwayslink`
    (the only reference to its `main` comes from an archive linked after
    it), compiled with `copts = ["-parse-as-library"]`, and depending on
    `@isomer//:swift_ui` (and `@isomer//:isomer`, `@isomer//:foundation` as
    it needs them) rather than a platform's own labels, so the one library
    builds for every platform: Apple's SwiftUI on Apple's, Isomer's
    elsewhere. Tag it `manual` (only the platforms' transitions give it a
    meaning). One isomer_application to a package: the web app's reactor
    is the package's `app_bridge` (isomer_web_app).

    Declares, for each platform in `platforms`:

      <name>_ios       the iPhone and iPad app, in the build's mode:
        <name>_ios_compiled  the library compiled in (ios_application)
        <name>_ios_webview   the web app's site bundled, run in a web view
                             and drawn by Isomer's tree renderer
                             (IsomerWebViewAppView), from a generated shell
                             (webview_app.swift.tpl): none of the app's
                             Swift compiled in
        <name>_ios_remote    a generated shell drawing the app's session
                             (IsomerRemoteView; remote_app.swift.tpl): the
                             session's URL is the Info.plist's
                             IsomerSessionURL (`remote_url`), or the launch
                             argument `-url <url>`
      <name>_macos     the Mac's, the same three (macos_application)
      <name>_android   `bazel run`: install and launch, in the build's mode;
      <name>_android_apk  the APK:
        <name>_android_compiled[_apk]  isomer_android_app
        <name>_android_remote[_apk]    a generated Kotlin shell over
                                       IsomerRemote (remote_activity.kt.tpl;
                                       the session's URL the intent's `url`
                                       extra, else `android_remote_url`):
                                       no Swift, no native library
        (web-view mode: Android's WebView isn't a session transport yet;
        the target is incompatible, skipped by a wildcard build and refused
        by name, constraint
        //tools/application:android_web_view_transport_not_built_yet)
      <name>_web       isomer_web_app in every mode (a page is already
                       wasm): `bazel run` serves it; <name>_web_site the
                       site, which the web-view apps bundle
      <name>_server    the app headless, serving itself, for the remote
                       apps to draw (always declared, manual): build it
                       with --@isomer//headless and run it with
                       ISO_DRIVE_LISTEN=ws://0.0.0.0:8090
                       ISO_HEADLESS_PROTOCOL=serve (docs/remote_sessions.md)

    The per-mode targets are `manual`: a wildcard build makes the platforms'
    own names, in its mode. Every mode's can be built by name in one build
    (CI builds the three of an example so).

    Identity: `bundle_id` (Apple), `package` (Android; `bundle_id` without
    one, also the web page's app key), `display_name` (under the icon),
    `version` (CFBundleShortVersionString, versionName) and `build`
    (CFBundleVersion, versionCode). `minimum_ios_version` and
    `minimum_macos_version` are every mode's (the heads, IsomerRemoteHead
    and IsomerWebViewHead, need iOS 17 and macOS 14; the defaults are what
    the remote and web-view examples are built at), `min_sdk_version`
    Android's.

    Apple: `app_icons` (an asset catalog's app icon), `infoplists` (merged
    over the generated ones), `resources` and `fonts` go in every mode's app
    (in web-view and remote modes the head loads a bundled image by name and
    lays text out in its own fonts), `ios_provisioning_profile` for a device
    build (none: the simulator's, `--ios_multi_cpus=sim_arm64`).

    Android: `android_icon` (a 192 × 192 PNG, as isomer_android_app's
    `icon`), `android_assets` (the compiled app's `assets`); `fonts` and
    `resources` go to the compiled app (the remote shell carries none yet).

    Web: `web_index` the page (generated from index.html.tpl without one:
    the DOM renderer, the app's identity), `web_assets` its assets/, `fonts`
    its fonts/.

    `remote_url` is the remote apps' session (an app on the building
    machine, by default); `android_remote_url` Android's, by default
    `remote_url` with its loopback host as an emulator reaches it
    (10.0.2.2). The Apple shells allow plain ws:// to the local network
    only (NSAllowsLocalNetworking): a session elsewhere is wss://.

    `tags` go to every target the macro makes (`manual` on the platforms'
    names keeps a wildcard build from making the app), `visibility` to the
    platforms' names.
    """
    package = package or bundle_id
    for platform in platforms:
        if platform not in _PLATFORMS:
            fail("isomer_application: platforms are %s, not %s" % (_PLATFORMS, platform))
    manual = tags + ([] if "manual" in tags else ["manual"])

    # The web app: wasm in every mode, and the site the web-view apps bundle.
    if "web" in platforms or "ios" in platforms or "macos" in platforms:
        index = web_index
        if not index:
            expand_template(
                name = name + "_web_index",
                out = "generated/%s/index.html" % name,
                substitutions = {
                    "{TITLE}": display_name,
                    "{BUNDLE_ID}": package,
                },
                tags = manual,
                template = Label("//tools/application:index.html.tpl"),
            )
            index = ":%s_web_index" % name
        isomer_web_app(
            name = name + "_web",
            assets = web_assets,
            fonts = fonts,
            index = index,
            swift_library = swift_library,
            visibility = visibility,
        )

    # The app headless, serving itself: what a remote app draws.
    swift_binary(
        name = name + "_server",
        tags = manual,
        deps = [swift_library],
    )

    if "ios" in platforms or "macos" in platforms:
        _apple(
            name = name,
            swift_library = swift_library,
            bundle_id = bundle_id,
            display_name = display_name,
            version = version,
            build = build,
            platforms = platforms,
            minimum_ios_version = minimum_ios_version,
            minimum_macos_version = minimum_macos_version,
            families = families,
            app_icons = app_icons,
            infoplists = infoplists,
            resources = resources + fonts,
            ios_provisioning_profile = ios_provisioning_profile,
            remote_url = remote_url,
            tags = tags,
            manual = manual,
            visibility = visibility,
        )

    if "android" in platforms:
        _android(
            name = name,
            swift_library = swift_library,
            package = package,
            display_name = display_name,
            version = version,
            build = build,
            icon = android_icon,
            assets = android_assets,
            fonts = fonts,
            resources = resources,
            min_sdk_version = min_sdk_version,
            remote_url = android_remote_url or remote_url.replace("127.0.0.1", "10.0.2.2").replace("localhost", "10.0.2.2"),
            tags = tags,
            manual = manual,
            visibility = visibility,
        )

def _apple(
        name,
        swift_library,
        bundle_id,
        display_name,
        version,
        build,
        platforms,
        minimum_ios_version,
        minimum_macos_version,
        families,
        app_icons,
        infoplists,
        resources,
        ios_provisioning_profile,
        remote_url,
        tags,
        manual,
        visibility):
    # The shells, one source for the iPhone and the Mac.
    expand_template(
        name = name + "_webview_shell_swift",
        out = "generated/%s/WebViewShell.swift" % name,
        substitutions = {"{SITE}": name + "_web_site"},
        tags = manual,
        template = Label("//tools/application:webview_app.swift.tpl"),
    )
    swift_library_rule(
        name = name + "_webview_shell",
        srcs = [":%s_webview_shell_swift" % name],
        module_name = _identifier(name) + "_WebViewShell",
        tags = manual,
        deps = [Label("//apple/libraries/webview_head")],
    )
    expand_template(
        name = name + "_remote_shell_swift",
        out = "generated/%s/RemoteShell.swift" % name,
        substitutions = {"{REMOTE_URL}": remote_url},
        tags = manual,
        template = Label("//tools/application:remote_app.swift.tpl"),
    )
    swift_library_rule(
        name = name + "_remote_shell",
        srcs = [":%s_remote_shell_swift" % name],
        module_name = _identifier(name) + "_RemoteShell",
        tags = manual,
        deps = [Label("//apple/libraries/remote_head")],
    )

    # What every mode's Info.plist has; the remote shells' session and the
    # plain ws:// a session on the local network takes.
    versions = [
        "<key>CFBundlePackageType</key><string>APPL</string>",
        "<key>CFBundleShortVersionString</key><string>%s</string>" % version,
        "<key>CFBundleVersion</key><string>%s</string>" % build,
    ]
    _plist(name + "_ios_plist", versions + ["<key>UILaunchScreen</key><dict/>"], manual)
    _plist(name + "_macos_plist", versions, manual)
    _plist(name + "_remote_plist", [
        "<key>IsomerSessionURL</key><string>%s</string>" % remote_url,
        "<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>",
        "<key>NSLocalNetworkUsageDescription</key><string>%s runs on a computer on your network.</string>" % display_name,
    ], manual)

    # Each mode's app: its code, the site a web-view app runs, the session a
    # remote app draws.
    modes = {
        "compiled": struct(deps = [swift_library], resources = [], plists = []),
        "webview": struct(deps = [":%s_webview_shell" % name], resources = [":%s_web_site" % name], plists = []),
        "remote": struct(deps = [":%s_remote_shell" % name], resources = [], plists = [":%s_remote_plist" % name]),
    }
    for platform in ["ios", "macos"]:
        if platform not in platforms:
            continue
        for mode, parts in modes.items():
            common = dict(
                name = "%s_%s_%s" % (name, platform, mode),
                app_icons = app_icons,
                bundle_id = bundle_id,
                bundle_name = display_name,
                infoplists = [":%s_%s_plist" % (name, platform)] + parts.plists + infoplists,
                resources = parts.resources + resources,
                tags = manual,
                deps = parts.deps,
            )
            if platform == "ios":
                ios_application(
                    families = families,
                    minimum_os_version = minimum_ios_version,
                    provisioning_profile = ios_provisioning_profile,
                    **common
                )
            else:
                macos_application(
                    minimum_os_version = minimum_macos_version,
                    **common
                )
        native.alias(
            name = "%s_%s" % (name, platform),
            actual = _by_mode({mode: ":%s_%s_%s" % (name, platform, mode) for mode in _MODES}),
            tags = tags,
            visibility = visibility,
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
        template = Label("//tools/application:remote_activity.kt.tpl"),
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
        template = Label("//tools/android:manifest.xml.tpl"),
    )
    androidx = Label("//android/maven:androidx")
    kt_android_library(
        name = remote + "_lib",
        srcs = [
            ":%s_activity" % remote,
            # The Compose renderer, as Kotlin alone: IsomerRemote and the
            # tree it draws.
            Label("//android/libraries/swift_ui:interpreter_kotlin"),
        ],
        custom_package = package,
        manifest = ":%s_manifest" % remote,
        plugins = [Label("//android/libraries/swift_ui:compose_compiler_plugin")],
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

    # webview: no transport yet (tools/application/BUILD.bazel).
    native.filegroup(
        name = name + "_android_webview",
        tags = manual,
        target_compatible_with = [Label("//tools/application:android_web_view_transport_not_built_yet")],
    )

    native.alias(
        name = name + "_android",
        actual = _by_mode({
            "compiled": ":%s_android_compiled" % name,
            "webview": ":%s_android_webview" % name,
            "remote": ":" + remote,
        }),
        tags = tags,
        visibility = visibility,
    )
    native.alias(
        name = name + "_android_apk",
        actual = _by_mode({
            "compiled": ":%s_android_compiled_apk" % name,
            "webview": ":%s_android_webview" % name,
            "remote": ":%s_apk" % remote,
        }),
        tags = tags,
        visibility = visibility,
    )
