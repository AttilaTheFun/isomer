"""What the Storybook's apps carry in their Info.plist from the builder's own
values (extension.bzl), so the repository names none: what they tell UpdateKit,
and the builder's other keys (ShakeKit's, the shared GitHub sign-in's).

    load("//tools/signing:defs.bzl", "stamped_infoplist")

    stamped_infoplist(name = "stamped_plist")   # an Info.plist fragment

With nothing set, the fragment is empty: UpdateKit does nothing (its README,
"The app group"), and neither does ShakeKit (no shared sign-in).
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

def shared_keychain_group():
    """The shared GitHub sign-in's keychain group (INFOPLIST's
    GitHubSharedKeychainGroup, team-prefixed), or "" for none."""
    return INFOPLIST.get("GitHubSharedKeychainGroup", "")

def app_groups():
    """The app groups the builder's apps share: UpdateKit's and the shared
    GitHub sign-in's lock group, each once (also what CI's placeholder
    profile allows, //tools/ci_device)."""
    groups = []
    for group in [UPDATE_APP_GROUP, INFOPLIST.get("GitHubSharedLockGroup", "")]:
        if group and group not in groups:
            groups.append(group)
    return groups

def app_entitlements(name, src = None, bundle_id = None):
    """The entitlements an app is built with, plus the builder's: the app
    groups (UpdateKit's, the shared GitHub sign-in's lock group) and the
    shared sign-in's keychain group (INFOPLIST's GitHubSharedKeychainGroup, a
    team-prefixed group), where the builder sets them; `src` as it is
    otherwise. Returns the label to build with (None for none).

    The build's own entitlements are what CI's `sign apple` signs with
    (build_tools' ApplePlan: a profile's only for a bundle built with none,
    and then its wildcard keychain group is the bundle's own), so the groups
    have to be in them; and they come from the builder, so a public
    repository names none.

    - With `src` (an iPhone's .entitlements, naming no app group): the app
      groups added, and the shared keychain group last in its
      keychain-access-groups (the first is where the app keeps what it saves
      without naming a group, which stays its own).
    - Without (a Mac app): the app groups and, with the shared keychain group,
      the app's own (TEAM.<bundle_id>, TEAM the shared group's) and the shared
      one. A Mac app asking for these needs its Developer ID profile, which
      CI's signing finds.
    """
    keychain = shared_keychain_group()
    groups = app_groups()
    if not keychain and not groups:
        return src
    if src:
        # awk: the keychain group before keychain-access-groups' </array>,
        # the app groups before the closing </dict>.
        native.genrule(
            name = name,
            srcs = [src],
            outs = [name + ".entitlements"],
            cmd = " ".join([
                "awk",
                "-v kg='%s'" % _xml(keychain),
                "-v ag='%s'" % ",".join([_xml(g) for g in groups]),
                "'" + " ".join([
                    "/<key>keychain-access-groups<\\/key>/ { k = 1 }",
                    "k && /<\\/array>/ { if (kg != \"\") print \"\\t\\t<string>\" kg \"</string>\"; k = 0 }",
                    "/^<\\/dict>/ && ag != \"\" {",
                    "print \"\\t<key>com.apple.security.application-groups</key>\"; print \"\\t<array>\";",
                    "n = split(ag, a, \",\"); for (i = 1; i <= n; i++) print \"\\t\\t<string>\" a[i] \"</string>\";",
                    "print \"\\t</array>\" }",
                    "{ print }",
                ]) + "'",
                "$< > $@",
            ]),
        )
        return ":" + name
    if not bundle_id:
        fail("app_entitlements needs src or bundle_id")
    entries = []
    if keychain:
        team = keychain.split(".")[0]
        entries += [
            "\t<key>keychain-access-groups</key>",
            "\t<array>",
            "\t\t<string>%s.%s</string>" % (_xml(team), _xml(bundle_id)),
            "\t\t<string>%s</string>" % _xml(keychain),
            "\t</array>",
        ]
    if groups:
        entries += ["\t<key>com.apple.security.application-groups</key>", "\t<array>"]
        entries += ["\t\t<string>%s</string>" % _xml(g) for g in groups]
        entries += ["\t</array>"]
    write_file(
        name = name,
        out = name + ".entitlements",
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
    )
    return ":" + name
