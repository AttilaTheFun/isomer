"""`rs_swift_library`: Rust consuming a bridged module across its C ABI — the
Rust peer of `cc_swift_library`. Lives in its own file so only Rust consumers
need rules_rust (swift_ffi declares it as a dev dependency for the example
cells)."""

load("@rules_rust//rust:defs.bzl", "rust_library")
load(":bridge_cc_library.bzl", "bridge_cc_library")
load(":utils.bzl", "ffi_generate")

def rs_swift_library(
        name,
        swift,
        module_name = None,
        deps = [],
        visibility = None,
        **kwargs):
    """Rust bindings over a `bridge_cc_library`: a `rust_library` (`:<name>`)
    of generated idiomatic Rust (v1 surface: scalars, String, byte vectors,
    structs, throwing functions).

    Takes the annotated `swift_library` directly; the C ABI layer is created
    internally (no consumer-written bridge target).
    """
    bridge_cc_library(
        name = name + "_bridge",
        swift = swift,
        module_name = module_name,
        tags = ["manual"],
    )
    ffi_generate(
        name = name + "_gen_rs",
        dep = swift,
        kind = "rust",
        output_name = name + ".rs",
        module_name = module_name,
    )
    rust_library(
        name = name,
        srcs = [":" + name + "_gen_rs"],
        crate_name = name,
        crate_root = ":" + name + "_gen_rs",
        edition = "2021",
        deps = [":" + name + "_bridge"] + deps,
        visibility = visibility,
        **kwargs
    )
