"""The iPhone's and the Mac's apps for isomer_application
(@isomer//tools/application:defs.bzl), built with rules_apple (isomer's
docs/platform_modules.md):

    load("@isomer//tools/application:defs.bzl", "WEB", "isomer_application")
    load("@isomer_apple//:defs.bzl", "IOS", "MACOS")

    isomer_application(name = "app", platforms = [IOS, MACOS, WEB], ...)

For each of IOS and MACOS in `platforms`, in each mode
(docs/modes.md, "The setting"):

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

Their arguments to isomer_application: `minimum_ios_version` and
`minimum_macos_version`, every mode's (the heads, IsomerRemoteHead and
IsomerWebViewHead, need iOS 17 and macOS 14; the defaults are what the
remote and web-view examples are built at); `families`; `app_icons` (an
asset catalog's app icon), `infoplists` (merged over the generated ones),
in every mode's app; `ios_provisioning_profile` for a device build (none:
the simulator's, `--ios_multi_cpus=sim_arm64`). The app's `resources` and
`fonts` go in every mode's app (in web-view and remote modes the head loads
a bundled image by name and lays text out in its own fonts). The Apple
shells allow plain ws:// to the local network only
(NSAllowsLocalNetworking): a remote session elsewhere is wss://.
"""

load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application")
load("@build_bazel_rules_apple//apple:macos.bzl", "macos_application")
load("@isomer//tools/application:defs.bzl", "by_mode")
# Named apart: the macros take the app's library as `swift_library`.
load("@rules_swift//swift:swift.bzl", swift_library_rule = "swift_library")

_MODES = ["compiled", "webview", "remote"]

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

def _declare(
        app,
        platforms,
        minimum_ios_version,
        minimum_macos_version,
        families,
        app_icons,
        infoplists,
        ios_provisioning_profile):
    _apple(
        name = app.name,
        swift_library = app.swift_library,
        bundle_id = app.bundle_id,
        display_name = app.display_name,
        version = app.version,
        build = app.build,
        platforms = platforms,
        minimum_ios_version = minimum_ios_version,
        minimum_macos_version = minimum_macos_version,
        families = families,
        app_icons = app_icons,
        infoplists = infoplists,
        resources = app.resources + app.fonts,
        ios_provisioning_profile = ios_provisioning_profile,
        remote_url = app.remote_url,
        site = app.site,
        tags = app.tags,
        manual = app.manual,
        visibility = app.visibility,
    )

_ATTRS = {
    "app_icons": [],
    "families": ["iphone", "ipad"],
    "infoplists": [],
    "ios_provisioning_profile": None,
    "minimum_ios_version": "18.0",
    "minimum_macos_version": "15.0",
}

# The iPhone (and iPad) and the Mac, for isomer_application's `platforms`.
IOS = struct(name = "ios", module = "isomer_apple", attrs = _ATTRS, declare = _declare)

MACOS = struct(name = "macos", module = "isomer_apple", attrs = _ATTRS, declare = _declare)

def isomer_application(**_kwargs):
    fail("isomer_application is isomer's since 0.59: load it from @isomer//tools/application:defs.bzl " +
         "and name the Apple platforms there, platforms = [IOS, MACOS, ...] (IOS and MACOS from " +
         "@isomer_apple//:defs.bzl; docs/platform_modules.md)")

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
        site,
        tags,
        manual,
        visibility):
    # The shells, one source for the iPhone and the Mac.
    expand_template(
        name = name + "_webview_shell_swift",
        out = "generated/%s/WebViewShell.swift" % name,
        substitutions = {"{SITE}": site.lstrip(":")},
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
        "webview": struct(deps = [":%s_webview_shell" % name], resources = [site], plists = []),
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
            actual = by_mode({mode: ":%s_%s_%s" % (name, platform, mode) for mode in _MODES}),
            tags = tags,
            visibility = visibility,
        )
