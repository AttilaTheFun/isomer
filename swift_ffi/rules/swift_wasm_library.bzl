"""`swift_wasm_library`: compiled Swift consuming a bridged module that runs
as a WebAssembly reactor: `swift_library (host app) > swift_wasm_library >
swift_library (the annotated module, compiled to wasm)`."""

load("@rules_swift//swift:swift_library.bzl", "swift_library")
load(":utils.bzl", "ffi_generate")

_RUNTIME_HOST = Label("//swift_ffi/runtime/swift_wasm_host")

def swift_wasm_library(
        name,
        swift,
        module_name = None,
        host_module_name = None,
        deps = [],
        visibility = None,
        **kwargs):
    """Native-Swift host bindings for a bridged wasm reactor: a
    `swift_library` (`:<name>`) of generated `swift-host-wasm` bindings. A
    native process supplies a `SwiftFFIWasmEngine` and loads a reactor built
    by an explicit `swift_wasm_reactor` target with the generated
    `<Module>.load(engine:wasm:)`. The consumer-facing seam behind
    isomer's WasmView pattern.
    """
    ffi_generate(
        name = name + "_host_src",
        dep = swift,
        kind = "swift-host-wasm",
        output_name = name + "_host.swift",
        module_name = module_name,
    )
    swift_library(
        name = name,
        srcs = [":" + name + "_host_src"],
        module_name = host_module_name or ((module_name + "Host") if module_name else name),
        deps = [_RUNTIME_HOST] + deps,
        visibility = visibility,
        **kwargs
    )
