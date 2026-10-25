"""Playground project templates assembled from //playground/shared/sample_sources.

A template is ONE .swift file the Playground compiles as a single-file project
against its SDK: a header, a `@main` App wrapper that hosts the example's
screen, then the shared source(s) with their `import` lines stripped (the
wrapper imports what the SDK provides). The sources are copies of the example
apps' screens (examples/shared/example_application)."""

def playground_sample(name, out, title, srcs, app = None, services = False, platform_services = False, bridge_shim = False):
    """Assembles samples/<out>.swift from `srcs` (labels of shared sources).

    Args:
      name: the genrule name.
      out: the output file name under samples/ (also the template resource).
      title: one-line description for the file header.
      srcs: shared .swift sources, concatenated in order, imports stripped.
      app: the `@main` App body lines (a list of source lines); None when a
        source declares its own `@main` App (the splash page).
      services: also append PlatformServicesAccess.swift (URLSession and
        FileManager helpers) + import Foundation.
      platform_services: import PlatformServices (the image picker: what of
        the injected services Foundation has no API for).
      bridge_shim: append a `Bridge` shim (the example apps' web bridge
        isn't in the Playground SDK; the shim routes openURL and log to the
        Isomer module).
    """
    all_srcs = list(srcs)
    if services:
        all_srcs.append("//playground/shared/sample_sources:PlatformServicesAccess.swift")
    lines = [
        "// %s — as a Playground project. Same source as the example apps'." % title,
        "import SwiftUI",
        "import Isomer",
        "import Observation",
    ]
    if services:
        lines.append("import Foundation")
    if platform_services:
        lines.append("import PlatformServices")
    lines.append("")
    if app:
        lines += ["@main"] + app + [""]
    if bridge_shim:
        lines += [
            "/// The example apps' web bridge, over the Isomer module.",
            "enum Bridge {",
            "    static func log(_ message: String) { print(message) }",
            "    @MainActor static func openURL(_ url: String) { Platform.openURL(url) }",
            "}",
            "",
        ]
    header = "\n".join(["echo %s;" % _sq(line) for line in lines])
    # Each source without its `import` lines, and without the block that
    # imports FoundationNetworking where the toolchain's corelibs Foundation
    # keeps URLSession (Linux, Windows): a project compiles for wasm only,
    # where Foundation is Isomer's and has it.
    bodies = "\n".join([
        "awk '/^#if .*FoundationNetworking/ { skip = 1 } !skip && !/^import / { print } /^#endif/ { skip = 0 }' $(location %s); echo '';" % src
        for src in all_srcs
    ])
    native.genrule(
        name = name,
        srcs = all_srcs,
        outs = ["samples/" + out],
        cmd = "{ " + header + "\n" + bodies + " } > $@",
    )

def _sq(text):
    """Single-quotes `text` for the shell."""
    return "'" + text.replace("'", "'\"'\"'") + "'"
