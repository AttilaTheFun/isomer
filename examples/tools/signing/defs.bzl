"""What the Storybook's apps tell UpdateKit, from the builder's own values
(extension.bzl), so the repository names none.

    load("//tools/signing:defs.bzl", "update_infoplist")

    update_infoplist(name = "update_plist")   # an Info.plist fragment

With no app group set, the fragment is empty, and UpdateKit does nothing (its
README, "The app group").
"""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@isomer_signing//:signing.bzl", "UPDATE_APPLICATIONS_BUNDLE_IDS", "UPDATE_APP_GROUP")

def _xml(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def update_infoplist(name, **kwargs):
    """An Info.plist fragment: UpdateKitAppGroup and, with any,
    UpdateKitApplicationsBundleIDs."""
    entries = []
    if UPDATE_APP_GROUP:
        entries += ["\t<key>UpdateKitAppGroup</key>", "\t<string>%s</string>" % _xml(UPDATE_APP_GROUP)]
        if UPDATE_APPLICATIONS_BUNDLE_IDS:
            entries += ["\t<key>UpdateKitApplicationsBundleIDs</key>", "\t<array>"]
            entries += ["\t\t<string>%s</string>" % _xml(i) for i in UPDATE_APPLICATIONS_BUNDLE_IDS]
            entries += ["\t</array>"]
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
