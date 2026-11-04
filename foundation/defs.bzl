"""`one_configuration`: a library reached in one configuration however its
dependents were configured.

rules_swift_package_manager builds a SwiftPM package's targets at the
package's own minimum OS version for the Apple platform type in effect
(SwiftProtobuf's macOS 10.13), and it does so on every platform, wasm and
Android included: `--apple_platform_type` stays `macos` there, or is `ios`
when the wasm build is a resource of an iOS app (an app's web site inside
its iOS app; a package declaring iOS 17 beside an app at 18). A library such a package depends on, Isomer's
Foundation through `@isomer//:foundation`, would then be built twice, at the
package's minimum and at the rest of the build's, and both copies linked:
duplicate symbols. Reached through this rule it is built once, with the
minimum OS versions cleared (they mean nothing off Apple platforms, where
these libraries build), and without the Swift language features a consumer
may set for its whole build (`--features=swift.enable_v6`, upcoming ones,
warnings as errors, library evolution): Foundation and what it is built
from (swift-foundation, its bundled collections) are a module of their own,
which a consumer's REPO.bazel can't reach, and they build in the language
mode and with the warnings they are tested with. Other features pass
through as given.
"""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_swift//swift:providers.bzl", "SwiftInfo")

# Every option rules_swift_package_manager's minimum-OS transition sets
# (swiftpkg/internal/minimum_os_platforms.bzl there).
_OPTIONS = [
    "//command_line_option:ios_minimum_os",
    "//command_line_option:macos_minimum_os",
    "//command_line_option:minimum_os_version",
    "//command_line_option:tvos_minimum_os",
    "//command_line_option:watchos_minimum_os",
]

# Swift features that change the language or the module's form, which a
# consumer may set on the command line for its own code: dropped here.
_SWIFT_LANGUAGE_FEATURES = [
    "swift.enable_v6",
    "swift.treat_warnings_as_errors",
    "swift.enable_library_evolution",
    "swift.emit_swiftinterface",
]
_SWIFT_LANGUAGE_PREFIXES = ["swift.upcoming.", "swift.experimental."]

def _language_feature(feature):
    name = feature[1:] if feature.startswith("-") else feature
    if name in _SWIFT_LANGUAGE_FEATURES:
        return True
    for prefix in _SWIFT_LANGUAGE_PREFIXES:
        if name.startswith(prefix):
            return True
    return False

def _clear_minimum_os_impl(settings, _attr):
    cleared = {option: None for option in _OPTIONS}
    cleared["//command_line_option:features"] = [
        feature
        for feature in settings["//command_line_option:features"]
        if not _language_feature(feature)
    ]
    return cleared

_clear_minimum_os = transition(
    implementation = _clear_minimum_os_impl,
    inputs = ["//command_line_option:features"],
    outputs = _OPTIONS + ["//command_line_option:features"],
)

def _one_configuration_impl(ctx):
    actual = ctx.attr.actual[0]
    providers = [actual[DefaultInfo]]
    for provider in [SwiftInfo, CcInfo, OutputGroupInfo]:
        if provider in actual:
            providers.append(actual[provider])
    return providers

one_configuration = rule(
    implementation = _one_configuration_impl,
    attrs = {
        # Named `actual` so swift_ffi's analyzer aspect walks through it as it
        # does through an alias.
        "actual": attr.label(
            cfg = _clear_minimum_os,
            mandatory = True,
            providers = [[SwiftInfo], [CcInfo]],
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Forwards `actual`'s Swift and C providers, `actual` built with the minimum OS versions cleared.",
)
