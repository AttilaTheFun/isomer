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
these libraries build).
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

def _clear_minimum_os_impl(_settings, _attr):
    return {option: None for option in _OPTIONS}

_clear_minimum_os = transition(
    implementation = _clear_minimum_os_impl,
    inputs = [],
    outputs = _OPTIONS,
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
