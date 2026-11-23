"""The builder's own signing values, from the environment, not the repo.

`@isomer_signing//:signing.bzl` defines TEAM_ID: the Apple team to sign the
examples' device builds with, from ISOMER_TEAM_ID, or a placeholder. Set it
for your builds in a `.bazelrc.user` beside this module's MODULE.bazel (it
is not checked in):

    common --repo_env=ISOMER_TEAM_ID=<your team id>

Simulator and Mac builds need nothing; an iPhone build needs your team's
development profile (Xcode's, found by `local_provisioning_profile`).

It also defines what the Storybook's apps tell UpdateKit (defs.bzl's
`update_infoplist`), which a public repository never names:
- UPDATE_APP_GROUP, from ISOMER_UPDATE_APP_GROUP: the app group the apps
  share with the distributor (UpdateKit's `UpdateKitAppGroup`), or "" for
  none, when UpdateKit does nothing;
- UPDATE_APPLICATIONS_BUNDLE_IDS, from ISOMER_UPDATE_APPLICATIONS_BUNDLE_IDS
  (comma-separated): on a Mac, the distributor's bundle ids to ask to
  install an update (`UpdateKitApplicationsBundleIDs`).
CI's distribution builds set both from the repository's secrets.
"""

def _signing_impl(rctx):
    team = rctx.getenv("ISOMER_TEAM_ID", "YOUR_TEAM_ID") or "YOUR_TEAM_ID"
    group = (rctx.getenv("ISOMER_UPDATE_APP_GROUP", "") or "").strip()
    ids = [i.strip() for i in (rctx.getenv("ISOMER_UPDATE_APPLICATIONS_BUNDLE_IDS", "") or "").split(",") if i.strip()]
    rctx.file("BUILD.bazel", 'exports_files(["signing.bzl"])\n')
    rctx.file("signing.bzl", "\n".join([
        'TEAM_ID = "%s"' % team,
        "UPDATE_APP_GROUP = %s" % repr(group),
        "UPDATE_APPLICATIONS_BUNDLE_IDS = %s" % repr(ids),
        "",
    ]))

_signing = repository_rule(implementation = _signing_impl)

def _extension_impl(_mctx):
    _signing(name = "isomer_signing")

signing = module_extension(implementation = _extension_impl)
