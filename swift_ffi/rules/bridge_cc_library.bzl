"""`bridge_cc_library`: the generated C ABI of one bridged module, as a
`cc_library` — the C header (docs/abi.md) over the annotated `swift_library`
itself (whose macro expansions carry every `@c` symbol; there is no separate
glue module). An implementation detail of the per-language macros; depend on
it directly only from hand-written C."""

load("@rules_cc//cc:defs.bzl", "cc_library")
load("@rules_swift//swift:swift_interop_hint.bzl", "swift_interop_hint")
load(":utils.bzl", "ffi_generate")

_SWIFT_ABI = Label("//swift_ffi/runtime/swift_abi")

def bridge_cc_library(name, swift, deps = [], module_name = None, visibility = None, **kwargs):
    """The C ABI of one bridged module: `:<name>` is a `cc_library` exposing
    the generated header (`<name>.h`, resolving by basename) over the
    annotated `swift_library` (`swift`), which self-contains the exported
    symbols. `module_name` defaults to `swift`'s own Swift module name."""
    ffi_generate(
        name = name + "_header_src",
        dep = swift,
        kind = "c-header",
        output_name = name + ".h",
        module_name = module_name,
    )
    swift_interop_hint(
        name = name + "_interop",
        module_name = name + "_c",
    )
    cc_library(
        name = name,
        hdrs = [":" + name + "_header_src"],
        aspect_hints = [":" + name + "_interop"],
        includes = ["."],
        deps = [_SWIFT_ABI, swift] + deps,
        visibility = visibility,
        **kwargs
    )
