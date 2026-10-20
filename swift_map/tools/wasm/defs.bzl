"""Rules for assembling and serving the static wasm web application."""

load("@rules_python//python:defs.bzl", "py_binary")

def _static_site_impl(ctx):
    out = ctx.actions.declare_directory(ctx.label.name)

    commands = ["mkdir -p {out}/runtime".format(out = out.path)]
    commands.append("cp {src} {out}/index.html".format(src = ctx.file.index.path, out = out.path))
    commands.append("cp {src} {out}/map.wasm".format(src = ctx.file.wasm.path, out = out.path))
    for js in ctx.files.runtime_js:
        commands.append("cp {src} {out}/runtime/{name}".format(
            src = js.path,
            out = out.path,
            name = js.basename,
        ))
    for js in ctx.files.root_js:
        commands.append("cp {src} {out}/{name}".format(
            src = js.path,
            out = out.path,
            name = js.basename,
        ))

    ctx.actions.run_shell(
        inputs = [ctx.file.index, ctx.file.wasm] + ctx.files.runtime_js + ctx.files.root_js,
        outputs = [out],
        command = " && ".join(commands),
        mnemonic = "AssembleStaticSite",
        progress_message = "Assembling static site %s" % ctx.label,
    )
    return [DefaultInfo(files = depset([out]))]

static_site = rule(
    implementation = _static_site_impl,
    attrs = {
        "index": attr.label(allow_single_file = [".html"], mandatory = True),
        "wasm": attr.label(allow_single_file = [".wasm"], mandatory = True),
        "runtime_js": attr.label_list(allow_files = [".js"]),
        "root_js": attr.label_list(allow_files = [".js"]),
    },
    doc = "Assembles index.html + map.wasm + the JS runtime into one directory.",
)

def web_server(name, site, port = "8080", query = "", **kwargs):
    """`bazel run`-able dev server for a static_site target.

    Serves on localhost and opens the default browser (append `-- --no-open`
    to suppress, e.g. for headless verification).
    """
    py_binary(
        name = name,
        # isomer's own server: it finds the site wherever the runfiles put
        # it (this directory's copy looked one level too shallow once
        # swift_map moved under isomer).
        srcs = ["//tools/wasm:serve.py"],
        main = "//tools/wasm:serve.py",
        args = ["$(rootpath %s)" % site, port, query],
        data = [site],
        **kwargs
    )
