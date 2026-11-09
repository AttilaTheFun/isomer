"""The iso CLI as a file of its own, where a workspace's bazel-bin keeps it."""

def _executable_copy_impl(ctx):
    # The binary alone: a Swift binary's target also gives its module and
    # its other outputs, which a copy to move elsewhere needs none of.
    src = ctx.attr.src[DefaultInfo].files_to_run.executable
    out = ctx.actions.declare_file(ctx.attr.out or ctx.label.name)
    ctx.actions.symlink(output = out, target_file = src, is_executable = True)
    return [DefaultInfo(executable = out, files = depset([out]))]

executable_copy = rule(
    implementation = _executable_copy_impl,
    doc = "An executable target's binary under this package's name (`cp` follows the link).",
    attrs = {
        "out": attr.string(doc = "The file's name (the target's by default)."),
        "src": attr.label(executable = True, cfg = "target", mandatory = True),
    },
    executable = True,
)
