"""CI's release tools as they're run: a Swift tool linked to Swift's runtime dynamically.

rules_swift links a Linux binary's Swift runtime statically (its
swift.static_stdlib feature, on for Linux by default), Foundation with it, and
a statically linked Foundation can't write a Bool into a property list
(PropertyListSerialization: "property lists cannot contain objects of type
'Not A Type'"): build_tools' `sign apple` fails on the first entitlement that
is one (get-task-allow, a development profile's). So the tool is built with
the feature off, in a configuration of its own: linked to the runtime the
Swift toolchain ships, beside it in Bazel's tree (its runfiles), found by its
rpath. Nothing else in the build changes.
"""

def _dynamic_runtime_impl(settings, _attr):
    features = [f for f in settings["//command_line_option:features"] if f != "swift.static_stdlib"]
    return {"//command_line_option:features": features + ["-swift.static_stdlib"]}

_dynamic_runtime = transition(
    implementation = _dynamic_runtime_impl,
    inputs = ["//command_line_option:features"],
    outputs = ["//command_line_option:features"],
)

def _swift_tool_impl(ctx):
    binary = ctx.attr.binary[0] if type(ctx.attr.binary) == "list" else ctx.attr.binary
    executable = binary[DefaultInfo].files_to_run.executable
    tool = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = tool, target_file = executable, is_executable = True)
    return [DefaultInfo(
        executable = tool,
        files = depset([tool]),
        runfiles = ctx.runfiles([tool, executable]).merge(binary[DefaultInfo].default_runfiles),
    )]

swift_tool = rule(
    implementation = _swift_tool_impl,
    doc = "A Swift executable (a package's, through rules_swift_package_manager), linked to Swift's runtime dynamically.",
    executable = True,
    attrs = {
        "binary": attr.label(cfg = _dynamic_runtime, executable = True, mandatory = True),
    },
)
