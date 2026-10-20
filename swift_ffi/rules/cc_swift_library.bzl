"""`cc_swift_library`: C++ consuming a bridged Swift module (compiled)."""

load("@rules_cc//cc:defs.bzl", "cc_library")
load(":bridge_cc_library.bzl", "bridge_cc_library")
load(":utils.bzl", "ffi_generate")

_RUNTIME_CPP = Label("//swift_ffi/runtime/cpp")

def cc_swift_library(
        name,
        swift,
        deps = [],
        module_name = None,
        visibility = None,
        **kwargs):
    """C++ consuming a bridged Swift module (compiled): a header-only
    `cc_library` (`:<name>`) of generated idiomatic C++ — RAII interface
    wrappers, `std::function` closures, `swiftffi::Result` / `swiftffi::Lazy`,
    real templates for generic exports. Takes the annotated `swift_library`
    directly; the C ABI layer is created internally (no consumer-written
    bridge target).
    """
    bridge_cc_library(
        name = name + "_bridge",
        swift = swift,
        module_name = module_name,
        tags = ["manual"],
    )
    ffi_generate(
        name = name + "_gen_hpp",
        dep = swift,
        kind = "cpp",
        output_name = name + ".hpp",
        module_name = module_name,
        header_name = name + "_bridge.h",
    )
    cc_library(
        name = name,
        hdrs = [":" + name + "_gen_hpp"],
        includes = ["."],
        deps = [":" + name + "_bridge", _RUNTIME_CPP] + deps,
        visibility = visibility,
        **kwargs
    )
