"""What the Storybook's apps carry in their Info.plist from the builder's own
values (extension.bzl), so the repository names none: what they tell UpdateKit,
and the builder's other keys (ShakeKit's, the shared GitHub sign-in's).

    load("//tools/signing:defs.bzl", "stamped_infoplist")

    stamped_infoplist(name = "stamped_plist")   # an Info.plist fragment

With nothing set, the fragment is empty: UpdateKit does nothing (its README,
"The app group"), and ShakeKit signs in on its own (no shared sign-in).
"""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@isomer_signing//:signing.bzl", "INFOPLIST", "UPDATE_APPLICATIONS_BUNDLE_IDS", "UPDATE_APP_GROUP")

def _xml(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def stamped_infoplist(name, **kwargs):
    """An Info.plist fragment: UpdateKitAppGroup and, with any,
    UpdateKitApplicationsBundleIDs; then INFOPLIST's keys, each a string or an
    array of strings."""
    entries = []
    if UPDATE_APP_GROUP:
        entries += ["\t<key>UpdateKitAppGroup</key>", "\t<string>%s</string>" % _xml(UPDATE_APP_GROUP)]
        if UPDATE_APPLICATIONS_BUNDLE_IDS:
            entries += ["\t<key>UpdateKitApplicationsBundleIDs</key>", "\t<array>"]
            entries += ["\t\t<string>%s</string>" % _xml(i) for i in UPDATE_APPLICATIONS_BUNDLE_IDS]
            entries += ["\t</array>"]
    for key in sorted(INFOPLIST):
        value = INFOPLIST[key]
        entries.append("\t<key>%s</key>" % _xml(key))
        if type(value) == "list":
            entries += ["\t<array>"] + ["\t\t<string>%s</string>" % _xml(i) for i in value] + ["\t</array>"]
        else:
            entries.append("\t<string>%s</string>" % _xml(value))
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
        **kwargs
    )
