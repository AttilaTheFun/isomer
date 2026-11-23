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

def shared_signin_entitlements(name, src = None, bundle_id = None):
    """The entitlements an app is built with, plus the shared GitHub sign-in's
    keychain group when the builder sets it (INFOPLIST's
    GitHubSharedKeychainGroup, a team-prefixed group); `src` as it is
    otherwise. Returns the label to build with (None for none).

    The build's own entitlements are what CI's `sign apple` signs with
    (build_tools' ApplePlan: a profile's only for a bundle built with none,
    and then its wildcard keychain group is the bundle's own), so the shared
    group has to be in them for the app to read the shared sign-in.

    - With `src` (an iPhone's .entitlements): the group is added to its
      keychain-access-groups.
    - Without (a Mac app built with none): its own keychain group
      (TEAM.<bundle_id>, TEAM the shared group's), the shared one, and the
      app groups (UpdateKit's and the shared sign-in's lock group). A Mac
      app asking for these needs its Developer ID profile, which CI's
      signing finds.
    """
    group = INFOPLIST.get("GitHubSharedKeychainGroup", "")
    if not group:
        return src
    if src:
        # Last in keychain-access-groups' array: the first group is where the
        # app keeps what it saves without naming one, which stays its own.
        native.genrule(
            name = name,
            srcs = [src],
            outs = [name + ".entitlements"],
            cmd = "awk '/<key>keychain-access-groups<\\/key>/ { k = 1 } k && /<\\/array>/ { print \"\\t\\t<string>%s</string>\"; k = 0 } { print }' $< > $@" % _xml(group),
        )
        return ":" + name
    if not bundle_id:
        fail("shared_signin_entitlements needs src or bundle_id")
    team = group.split(".")[0]
    app_groups = []
    for g in [UPDATE_APP_GROUP, INFOPLIST.get("GitHubSharedLockGroup", "")]:
        if g and g not in app_groups:
            app_groups.append(g)
    write_file(
        name = name,
        out = name + ".entitlements",
        content = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
            '<plist version="1.0">',
            "<dict>",
            "\t<key>keychain-access-groups</key>",
            "\t<array>",
            "\t\t<string>%s.%s</string>" % (_xml(team), _xml(bundle_id)),
            "\t\t<string>%s</string>" % _xml(group),
            "\t</array>",
        ] + (["\t<key>com.apple.security.application-groups</key>", "\t<array>"] +
             ["\t\t<string>%s</string>" % _xml(g) for g in app_groups] + ["\t</array>"] if app_groups else []) + [
            "</dict>",
            "</plist>",
            "",
        ],
    )
    return ":" + name
