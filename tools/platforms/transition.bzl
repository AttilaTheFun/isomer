"""Forces a target to build for a given platform, regardless of the top-level
`--platforms`. Used to build the wasm / Android `swift_binary` outputs from a
host (macOS) `bazel build` without passing `--platforms` on the command line.
"""

_INTERNATIONALIZATION = str(Label("//foundation:internationalization"))

def _platform_transition_impl(settings, attr):
    return {
        "//command_line_option:platforms": str(attr.platform),
        # Isomer's Foundation with FoundationInternationalization and ICU
        # (//foundation), when the binary asks for it or the build does.
        _INTERNATIONALIZATION: attr.internationalization or settings[_INTERNATIONALIZATION],
    }

_platform_transition = transition(
    implementation = _platform_transition_impl,
    inputs = ["//command_line_option:platforms", _INTERNATIONALIZATION],
    outputs = ["//command_line_option:platforms", _INTERNATIONALIZATION],
)

def _transition_binary_impl(ctx):
    # Forward the (platform-built) files of the wrapped binary.
    return [DefaultInfo(files = ctx.attr.binary[0][DefaultInfo].files)]

transition_binary = rule(
    implementation = _transition_binary_impl,
    attrs = {
        "binary": attr.label(cfg = _platform_transition, mandatory = True),
        "platform": attr.label(mandatory = True, doc = "Platform to build `binary` for."),
        "internationalization": attr.bool(
            default = False,
            doc = "Build Isomer's Foundation with FoundationInternationalization (ICU).",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
