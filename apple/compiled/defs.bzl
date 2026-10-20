"""Features compiled into an Apple app against Isomer's frameworks.

    isomer_compiled_feature(
        name = "feature",
        deps = [":app"],   # the app's swift_library: `import SwiftUI` is Isomer's
    )

`deps` build in the feature's configuration (//apple/compiled:feature on,
its module mapping, the app's entry point renamed `iso_feature_main` so it
does not collide with the host app's `main`); the rule hands their linking
information (not their modules) to the host app, which drives the feature
through the iso_hot render ABI (apple/libraries/native_runtime) the way it
drives a wasm reactor. A feature's library depends on
`@isomer//:swift_ui` and `@isomer//apple/libraries/compiled_swift_ui:hot_bridge`.
"""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

_FEATURE = str(Label("//apple/compiled:feature"))
_MAPPING = str(Label("//apple/compiled:mapping"))
_MAPPING_FLAG = str(Label("@rules_swift//swift:module_mapping"))
_COPT = str(Label("@rules_swift//swift:copt"))

# The app's synthesized `main`, renamed: the host app has its own, and
# HotBridge calls the feature's by this name (iso_hot_start).
_ENTRY_POINT = ["-Xfrontend", "-entry-point-function-name", "-Xfrontend", "iso_feature_main"]

def _feature_transition_impl(settings, _attr):
    return {
        _FEATURE: True,
        _MAPPING_FLAG: _MAPPING,
        _COPT: settings[_COPT] + [c for c in _ENTRY_POINT if c not in settings[_COPT]],
    }

_feature_transition = transition(
    implementation = _feature_transition_impl,
    inputs = [_COPT],
    outputs = [_FEATURE, _MAPPING_FLAG, _COPT],
)

def _isomer_compiled_feature_impl(ctx):
    return [
        DefaultInfo(files = depset(transitive = [dep[DefaultInfo].files for dep in ctx.attr.deps])),
        cc_common.merge_cc_infos(cc_infos = [dep[CcInfo] for dep in ctx.attr.deps]),
    ]

isomer_compiled_feature = rule(
    implementation = _isomer_compiled_feature_impl,
    attrs = {
        "deps": attr.label_list(
            cfg = _feature_transition,
            providers = [CcInfo],
            doc = "The feature's libraries, built against Isomer's frameworks.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "A feature compiled against Isomer's frameworks, linked into an Apple host app (its C linking only).",
)
