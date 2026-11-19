"""isomer_application with the iPhone's and the Mac's apps: isomer's
(@isomer//tools/application:defs.bzl, Android's and the web's), and Apple's
beside them, built with rules_apple (isomer's docs/platform_modules.md).

    load("@isomer_apple//:defs.bzl", "isomer_application")

takes isomer's isomer_application's arguments, and Apple's (below), and
declares the targets isomer's does and <name>_ios and <name>_macos in each
mode (docs/modes.md, "The setting").
"""

load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application")
load("@build_bazel_rules_apple//apple:macos.bzl", "macos_application")
load("@isomer//tools/application:defs.bzl", _isomer_application = "isomer_application")
# Named apart: the macros take the app's library as `swift_library`.
load("@rules_swift//swift:swift.bzl", swift_library_rule = "swift_library")

_MODES = ["compiled", "webview", "remote"]

_APPLE_PLATFORMS = ["ios", "macos"]

_PLATFORMS = _APPLE_PLATFORMS + ["android", "web"]

def _by_mode(targets):
    """A select() over --@isomer//:mode: `targets` maps each mode to what
    the platform's own name is in it."""
    return select({
        Label("@isomer//:mode_" + mode): targets[mode]
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
        remote_url = "ws://127.0.0.1:8090/session",
        tags = [],
        visibility = None,
        **kwargs):
    """One Isomer app's targets on every platform, in each mode
    (docs/modes.md, "The setting").

    Everything isomer's isomer_application declares (Android's, the web's,
    `<name>_server`; its arguments, `package`, `android_icon`,
    `android_assets`, `min_sdk_version`, `web_index`, `web_assets` and
    `android_remote_url`, are passed on to it), and, for each of `ios` and
    `macos` in `platforms` (all four by default):

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

    The per-mode targets are `manual`, as isomer's are.

    Identity: `bundle_id`, `display_name` (under the icon), `version`
    (CFBundleShortVersionString) and `build` (CFBundleVersion), isomer's
    too. `minimum_ios_version` and `minimum_macos_version` are every
    mode's (the heads, IsomerRemoteHead and IsomerWebViewHead, need iOS 17
    and macOS 14; the defaults are what the remote and web-view examples are
    built at).

    `app_icons` (an asset catalog's app icon), `infoplists` (merged over
    the generated ones), `resources` and `fonts` go in every mode's app (in
    web-view and remote modes the head loads a bundled image by name and lays
    text out in its own fonts; `resources` and `fonts` go to isomer's
    too), `ios_provisioning_profile` for a device build (none: the
    simulator's, `--ios_multi_cpus=sim_arm64`). The Apple shells allow plain
    ws:// to the local network only (NSAllowsLocalNetworking): a remote
    session elsewhere is wss://.
    """
    for platform in platforms:
        if platform not in _PLATFORMS:
            fail("isomer_application: platforms are %s, not %s" % (_PLATFORMS, platform))
    _isomer_application(
        name = name,
        swift_library = swift_library,
        bundle_id = bundle_id,
        display_name = display_name,
        version = version,
        build = build,
        platforms = [platform for platform in platforms if platform not in _APPLE_PLATFORMS],
        resources = resources,
        fonts = fonts,
        remote_url = remote_url,
        tags = tags,
        visibility = visibility,
        **kwargs
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
            manual = tags + ([] if "manual" in tags else ["manual"]),
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
        template = Label("//:webview_app.swift.tpl"),
    )
    swift_library_rule(
        name = name + "_webview_shell",
        srcs = [":%s_webview_shell_swift" % name],
        module_name = _identifier(name) + "_WebViewShell",
        tags = manual,
        deps = [Label("@isomer//apple/libraries/webview_head")],
    )
    expand_template(
        name = name + "_remote_shell_swift",
        out = "generated/%s/RemoteShell.swift" % name,
        substitutions = {"{REMOTE_URL}": remote_url},
        tags = manual,
        template = Label("//:remote_app.swift.tpl"),
    )
    swift_library_rule(
        name = name + "_remote_shell",
        srcs = [":%s_remote_shell_swift" % name],
        module_name = _identifier(name) + "_RemoteShell",
        tags = manual,
        deps = [Label("@isomer//apple/libraries/remote_head")],
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
