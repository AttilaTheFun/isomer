"""The builder's own signing values, from the environment, not the repo.

`@isomer_signing//:signing.bzl` defines TEAM_ID: the Apple team to sign the
examples' device builds (the Playground's too) with, from ISOMER_TEAM_ID, or a placeholder. Set it
for your builds in a `.bazelrc.user` beside this module's MODULE.bazel (it
is not checked in):

    common --repo_env=ISOMER_TEAM_ID=<your team id>

Simulator and Mac builds need nothing; an iPhone build needs your team's
development profile (Xcode's, found by `local_provisioning_profile`; the
Playground's a wildcard one, which
playground/tools/playground_toolchain/mint_profile makes).
"""

def _signing_impl(rctx):
    team = rctx.getenv("ISOMER_TEAM_ID", "YOUR_TEAM_ID") or "YOUR_TEAM_ID"
    rctx.file("BUILD.bazel", 'exports_files(["signing.bzl"])\n')
    rctx.file("signing.bzl", 'TEAM_ID = "%s"\n' % team)

_signing = repository_rule(implementation = _signing_impl)

def _extension_impl(_mctx):
    _signing(name = "isomer_signing")

signing = module_extension(implementation = _extension_impl)
