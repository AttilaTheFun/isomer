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

isomer declares the web's apps. Each other platform's are its module's
(docs/platform_modules.md), so an app resolves only the rules of the
platforms it builds: the iPhone's and the Mac's isomer_apple's (rules_apple),
Android's isomer_android's (rules_android, rules_kotlin). An app names its
platforms by the values those modules export:

    load("@isomer//tools/application:defs.bzl", "WEB", "isomer_application")
    load("@isomer_android//:defs.bzl", "ANDROID")
    load("@isomer_apple//:defs.bzl", "IOS", "MACOS")

    isomer_application(
        name = "app",
        platforms = [IOS, MACOS, ANDROID, WEB],
        ...
    )

A platform value is a struct: `name`, `module` (the module whose platforms
are declared together), `attrs` (the arguments it takes beyond the common
ones, with their defaults) and `declare(app, platforms, **attrs)`, called
once a module with the common arguments (`app`) and the names of that
module's platforms the app asked for.
"""

load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@rules_swift//swift:swift_binary.bzl", "swift_binary")
load("//tools/wasm:defs.bzl", "isomer_web_app")

_MODES = ["compiled", "webview", "remote"]

# The web: declared by isomer_application itself, whatever `platforms` says
# (the web-view apps bundle its site), so its value is a name alone.
WEB = struct(name = "web", module = "isomer", attrs = {}, declare = None)

# The other platforms' modules, to say where a platform named by a string is.
_MODULES = {
    "android": ("isomer_android", "ANDROID"),
    "ios": ("isomer_apple", "IOS"),
    "macos": ("isomer_apple", "MACOS"),
}

def by_mode(targets):
    """A select() over --@isomer//:mode: `targets` maps each mode to what
    the platform's own name is in it. For the platforms' modules."""
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
        platforms = [WEB],
        resources = [],
        fonts = [],
        web_index = None,
        web_assets = [],
        remote_url = "ws://127.0.0.1:8090/session",
        tags = [],
        visibility = None,
        **kwargs):
    """One Isomer app's targets on each of `platforms`, in each mode
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

    `platforms` are platform values: `WEB` (here), `ANDROID`
    (@isomer_android//:defs.bzl), `IOS` and `MACOS`
    (@isomer_apple//:defs.bzl); each module's defs.bzl lists the targets
    and arguments of its own. Whatever `platforms` says, this declares:

      <name>_web       isomer_web_app in every mode (a page is already
                       wasm): `bazel run` serves it; <name>_web_site the
                       site, which the web-view apps bundle
      <name>_server    the app headless, serving itself, for the remote
                       apps to draw (manual): build it with
                       --@isomer//headless and run it with
                       ISO_DRIVE_LISTEN=ws://0.0.0.0:8090
                       ISO_HEADLESS_PROTOCOL=serve (docs/remote_sessions.md)

    The per-mode targets are `manual`: a wildcard build makes the platforms'
    own names, in its mode. Every mode's can be built by name in one build
    (CI builds the three of an example so).

    Identity: `bundle_id` (Apple's), `package` (Android's; `bundle_id`
    without one, also the web page's app key), `display_name` (under the
    icon), `version` and `build`. `resources` and `fonts` go to every
    platform's app that carries them; `remote_url` is the remote apps'
    session (an app on the building machine, by default).

    Web: `web_index` the page (generated from index.html.tpl without one:
    the DOM renderer, the app's identity), `web_assets` its assets/, `fonts`
    its fonts/.

    `tags` go to every target the macro makes (`manual` on the platforms'
    names keeps a wildcard build from making the app), `visibility` to the
    platforms' names. Any other argument is a platform's (`android_icon`,
    `minimum_ios_version`, ...): one none of `platforms` takes fails.
    """
    package = package or bundle_id
    modules = {}
    for platform in platforms:
        if type(platform) == "string":
            if platform == "web":
                continue
            if platform in _MODULES:
                module, value = _MODULES[platform]
                fail(("isomer_application: platforms are values since 0.59: %s is %s from %s " +
                      "(add bazel_dep(name = \"%s\", version = <isomer's>), and " +
                      "load(\"@%s//:defs.bzl\", \"%s\"): docs/platform_modules.md)") %
                     (platform, value, module, module, module, value))
            fail("isomer_application: no platform %r" % platform)
        if platform.module == "isomer":
            continue
        if platform.module not in modules:
            modules[platform.module] = struct(declare = platform.declare, attrs = platform.attrs, names = [])
        modules[platform.module].names.append(platform.name)
    taken = {}
    for module in modules.values():
        taken.update(module.attrs)
    for key in kwargs:
        if key not in taken:
            fail("isomer_application: %s is an argument of none of its platforms (%s)" %
                 (key, ", ".join([p.name if type(p) != "string" else p for p in platforms])))
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

    app = struct(
        name = name,
        swift_library = swift_library,
        bundle_id = bundle_id,
        package = package,
        display_name = display_name,
        version = version,
        build = build,
        resources = resources,
        fonts = fonts,
        remote_url = remote_url,
        site = ":%s_web_site" % name,
        tags = tags,
        manual = manual,
        visibility = visibility,
    )
    for module in modules.values():
        module.declare(
            app = app,
            platforms = module.names,
            **{key: kwargs.get(key, default) for key, default in module.attrs.items()}
        )
