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

This is Android's and the web's (isomer's own rules alone). The iPhone's
and the Mac's apps are the isomer_apple module's (apple/module here, since
0.58: rules_apple and what it brings, which an app on Android and the web
alone never resolves): an app with them loads isomer_application from
`@isomer_apple//:defs.bzl`, which declares the same targets as this one and
the Apple ones beside them (docs/platform_modules.md).
"""

load("@bazel_skylib//rules:copy_file.bzl", "copy_file")
load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@rules_android//rules:rules.bzl", "android_binary")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")
load("@rules_swift//swift:swift_binary.bzl", "swift_binary")
load("//tools/android:defs.bzl", "apk_install_run", "isomer_android_app", "isomer_android_webview_app")
load("//tools/wasm:defs.bzl", "isomer_web_app")

_MODES = ["compiled", "webview", "remote"]

_PLATFORMS = ["android", "web"]

# isomer_apple's: named here only to say where they are.
_APPLE_PLATFORMS = ["ios", "macos"]

def _by_mode(targets):
    """A select() over --@isomer//:mode: `targets` maps each mode to what
    the platform's own name is in it."""
    return select({
        Label("//:mode_" + mode): targets[mode]
        for mode in _MODES
    })

def isomer_application(
        name,
        swift_library,
        bundle_id,
        display_name,
        package = None,
        version = "1.0",
        build = 1,
        platforms = _PLATFORMS,
        resources = [],
        fonts = [],
        android_icon = None,
        android_assets = None,
        min_sdk_version = 28,
        web_index = None,
        web_assets = [],
        remote_url = "ws://127.0.0.1:8090/session",
        android_remote_url = None,
        tags = [],
        visibility = None):
    """One Isomer app's targets on Android and the web, in each mode
    (docs/modes.md, "The setting"). The iPhone's and the Mac's are
    isomer_apple's isomer_application, which takes these arguments and
    Apple's and calls this one (docs/platform_modules.md).

    `swift_library` is the app: its SwiftUI `@main App`, `alwayslink`
    (the only reference to its `main` comes from an archive linked after
    it), compiled with `copts = ["-parse-as-library"]`, and depending on
    `@isomer//:swift_ui` (and `@isomer//:isomer`, `@isomer//:foundation` as
    it needs them) rather than a platform's own labels, so the one library
    builds for every platform: Apple's SwiftUI on Apple's, Isomer's
    elsewhere. Tag it `manual` (only the platforms' transitions give it a
    meaning). One isomer_application to a package: the web app's reactor
    is the package's `app_bridge` (isomer_web_app).

    Declares, for each platform in `platforms` (`android`, `web`):

      <name>_android   `bazel run`: install and launch, in the build's mode;
      <name>_android_apk  the APK:
        <name>_android_compiled[_apk]  isomer_android_app
        <name>_android_remote[_apk]    a generated Kotlin shell over
                                       IsomerRemote (remote_activity.kt.tpl;
                                       the session's URL the intent's `url`
                                       extra, else `android_remote_url`):
                                       no Swift, no native library
        <name>_android_webview[_apk]   the web app's site in the APK's
                                       assets, run in a WebView and drawn
                                       by the Compose renderer
                                       (isomer_android_webview_app,
                                       IsomerWebViewApp): no Swift, no
                                       native library
      <name>_web       isomer_web_app in every mode (a page is already
                       wasm): `bazel run` serves it; <name>_web_site the
                       site, which the web-view apps bundle (declared
                       whatever `platforms` says: the iPhone's and the
                       Mac's web-view apps bundle it too)
      <name>_server    the app headless, serving itself, for the remote
                       apps to draw (always declared, manual): build it
                       with --@isomer//headless and run it with
                       ISO_DRIVE_LISTEN=ws://0.0.0.0:8090
                       ISO_HEADLESS_PROTOCOL=serve (docs/remote_sessions.md)

    The per-mode targets are `manual`: a wildcard build makes the platforms'
    own names, in its mode. Every mode's can be built by name in one build
    (CI builds the three of an example so).

    Identity: `bundle_id` (Apple's, with isomer_apple), `package` (Android;
    `bundle_id` without one, also the web page's app key), `display_name`
    (under the icon), `version` (versionName) and `build` (versionCode).
    `min_sdk_version` is Android's.

    Android: `android_icon` (a 192 × 192 PNG, as isomer_android_app's
    `icon`), `android_assets` (the compiled and web-view apps' `assets`);
    `fonts` go to the compiled and web-view apps, `resources` to the
    compiled app (the remote shell carries none yet).

    Web: `web_index` the page (generated from index.html.tpl without one:
    the DOM renderer, the app's identity), `web_assets` its assets/, `fonts`
    its fonts/.

    `remote_url` is the remote apps' session (an app on the building
    machine, by default); `android_remote_url` Android's, by default
    `remote_url` with its loopback host as an emulator reaches it
    (10.0.2.2).

    `tags` go to every target the macro makes (`manual` on the platforms'
    names keeps a wildcard build from making the app), `visibility` to the
    platforms' names.
    """
    package = package or bundle_id
    for platform in platforms:
        if platform in _APPLE_PLATFORMS:
            fail(("isomer_application: the iPhone's and the Mac's apps (%s) are the isomer_apple " +
                  "module's since 0.58: add bazel_dep(name = \"isomer_apple\", version = <isomer's>) and " +
                  "load isomer_application from @isomer_apple//:defs.bzl (docs/platform_modules.md)") % platform)
        if platform not in _PLATFORMS:
            fail("isomer_application: platforms are %s, not %s" % (_PLATFORMS + _APPLE_PLATFORMS, platform))
    manual = tags + ([] if "manual" in tags else ["manual"])

    # The web app: wasm in every mode, and the site the web-view apps bundle.
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

    # webview: the web app's site in the APK, Kotlin and Compose only.
    isomer_android_webview_app(
        name = name + "_android_webview",
        assets = assets,
        fonts = fonts,
        icon = icon,
        label = display_name,
        min_sdk_version = min_sdk_version,
        package = package,
        site = ":%s_web_site" % name,
        tags = manual,
        version_code = build,
        version_name = version,
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
            "webview": ":%s_android_webview_apk" % name,
            "remote": ":%s_apk" % remote,
        }),
        tags = tags,
        visibility = visibility,
    )
