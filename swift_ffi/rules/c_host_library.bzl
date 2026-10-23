"""`c_host_library`: plain C consuming a bridged module that runs as a
WebAssembly reactor (a host with NO compiled Swift, driving a C engine)."""

load("@rules_cc//cc:defs.bzl", "cc_library")
load(":utils.bzl", "ffi_generate")

_RUNTIME_C_HOST = Label("//swift_ffi/runtime/c_host:swift_ffi_host")

def c_host_library(name, swift, module_name = None, deps = [], visibility = None, **kwargs):
    """Native-C host of a WebAssembly bridge, for a host with NO compiled Swift
    driving a C WebAssembly engine: a `cc_library` exposing the generated
    `c-host-wasm` header plus the engine-agnostic C runtime
    (//swift_ffi/runtime/c_host). The
    C peer of `swift_wasm_library`'s host side — it does NOT build the reactor
    (a wasm host that has no Swift usually gets the reactor from the app that
    owns it; pair with `swift_wasm_reactor` for a self-contained app). The
    consumer brings the engine (Isomer's own hosts are Swift, on WasmKit,
    since WAMR's C binding went in 0.38), supplies a `SwiftFFIEngine`
    vtable, binds the FIXED five-entry `swift_ffi` import
    table, instantiates, then activates dependencies.

    Only the c-host-representable subset of the module is emitted (scalars,
    String, [UInt8], host-implementable interfaces); async / @ExportedStruct /
    generics / closures / interface-returning functions are skipped and listed
    in a comment at the top of the generated header.

    Include the generated header from exactly one translation unit (its functions
    are `static`). `includes = ["."]` puts the generated header on dependents'
    include path so it resolves by basename.
    """
    ffi_generate(
        name = name + "_src",
        dep = swift,
        kind = "c-host-wasm",
        output_name = name + ".h",
        module_name = module_name,
    )
    cc_library(
        name = name,
        hdrs = [":" + name + "_src"],
        includes = ["."],
        deps = [_RUNTIME_C_HOST] + deps,
        visibility = visibility,
        **kwargs
    )
