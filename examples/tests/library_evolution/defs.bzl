"""A library built for a platform with `--@isomer//:library_evolution` on,
whatever the command line says: what build_test checks here."""

_LIBRARY_EVOLUTION = str(Label("@isomer//:library_evolution"))

def _evolution_transition_impl(_settings, attr):
    return {
        "//command_line_option:platforms": str(attr.platform),
        _LIBRARY_EVOLUTION: True,
    }

_evolution_transition = transition(
    implementation = _evolution_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms", _LIBRARY_EVOLUTION],
)

def _with_library_evolution_impl(ctx):
    return [DefaultInfo(files = ctx.attr.library[0][DefaultInfo].files)]

with_library_evolution = rule(
    implementation = _with_library_evolution_impl,
    attrs = {
        "library": attr.label(cfg = _evolution_transition, mandatory = True),
        "platform": attr.label(mandatory = True, doc = "The platform `library` is built for."),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Builds `library` for `platform`, Isomer's modules resilient (`--@isomer//:library_evolution`).",
)
