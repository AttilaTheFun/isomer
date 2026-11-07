"""An app's builds, Alpha, Beta, Production and AdHoc, by the //tools/variant:variant flag.

All of them have the app's one bundle id, name and link scheme; a build says
which it is in its Info.plist's `BuildVariant` ("Alpha", "Beta", "Production"
or "AdHoc"). Alpha is the default (every main and pull request build), Beta
is TestFlight's (for later), Production is a release branch's, built by CI's
release job (--config=prod), and AdHoc a pull request's branch's, built by
CI's adhoc job when it is run by hand (--config=adhoc). The private AttilaTheFun/applications' docs/VARIANTS.md says the whole of it; this
package (BUILD.bazel and this file) is its tools/variant, copied.

    load("//tools/variant:defs.bzl", "variant_infoplist")

    variant_infoplist(
        name = "variant_plist",
        display_name = "Visor",
        url_scheme = "visor",
    )

    ios_application(
        name = "visor_ios",
        bundle_id = "com.LoganShire.Visor",
        infoplists = ["Info.plist", ":variant_plist"],
        ...
    )
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

# The flag's values, as the Info.plist says them.
_NAMES = {
    "alpha": "Alpha",
    "beta": "Beta",
    "production": "Production",
    "adhoc": "AdHoc",
}

def _xml(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def _variant_infoplist_impl(ctx):
    variant = ctx.attr._variant[BuildSettingInfo].value
    name = _xml(ctx.attr.display_name)
    entries = [
        "\t<key>BuildVariant</key>\n\t<string>%s</string>" % _NAMES[variant],
        "\t<key>CFBundleDisplayName</key>\n\t<string>%s</string>" % name,
        "\t<key>CFBundleName</key>\n\t<string>%s</string>" % name,
    ]
    if ctx.attr.url_scheme:
        # Named for the app's bundle id, as rules_apple gives it.
        entries.append("\n".join([
            "\t<key>CFBundleURLTypes</key>",
            "\t<array>",
            "\t\t<dict>",
            "\t\t\t<key>CFBundleURLName</key>",
            "\t\t\t<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>",
            "\t\t\t<key>CFBundleURLSchemes</key>",
            "\t\t\t<array>",
            "\t\t\t\t<string>%s</string>" % _xml(ctx.attr.url_scheme),
            "\t\t\t</array>",
            "\t\t</dict>",
            "\t</array>",
        ]))
    plist = ctx.actions.declare_file(ctx.label.name + ".plist")
    ctx.actions.write(plist, "\n".join([
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        "<dict>",
    ] + entries + [
        "</dict>",
        "</plist>",
        "",
    ]))
    return [DefaultInfo(files = depset([plist]))]

variant_infoplist = rule(
    implementation = _variant_infoplist_impl,
    doc = """An Info.plist fragment of what this build of the app is.

BuildVariant: "Alpha", "Beta", "Production" or "AdHoc", by //tools/variant:variant.
CFBundleDisplayName and CFBundleName: `display_name`, the same for every
build. With `url_scheme`, CFBundleURLTypes: the app's link scheme, the same
for every build. The app's own Info.plist leaves these keys out; list the
fragment in its `infoplists`.
""",
    attrs = {
        "display_name": attr.string(mandatory = True, doc = "The app's name under its icon."),
        "url_scheme": attr.string(doc = "The app's link scheme, if it has one."),
        "_variant": attr.label(default = Label("//tools/variant:variant")),
    },
)
