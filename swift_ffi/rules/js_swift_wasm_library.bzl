"""`js_swift_wasm_library`: JavaScript (the browser) consuming a bridged
Swift module compiled to a WebAssembly reactor."""

load(":swift_wasm_reactor.bzl", "HOST_ENTRIES", "swift_wasm_reactor")
load(":utils.bzl", "ffi_generate")

# The shared runtime every generated module imports, and its declarations.
_RUNTIME_JS = Label("//swift_ffi/runtime/js:swift_ffi_runtime.js")
_RUNTIME_DTS = Label("//swift_ffi/runtime/js:swift_ffi_runtime.d.ts")

def js_swift_wasm_library(
        name,
        swift,
        module_name = None,
        linkopts = [],
        exports = None,
        export_entries = None,
        reactor_deps = [],
        platform = Label("//swift_ffi/rules:wasm32-wasip1"),
        runtime = True,
        tags = [],
        visibility = None):
    """WebAssembly bridge: a wasm reactor (`:<name>.wasm`, whose exports are
    the module's C ABI) and the generated bindings, written as JavaScript (an
    ES module, `<name>.js`) with their TypeScript declarations beside them
    (`<name>.d.ts`), plus the staged shared runtime `swift_ffi_runtime.js`
    (and its `.d.ts`). Nothing is compiled: the page loads the modules as
    written, and a consumer who checks its own code with TypeScript reads the
    declarations. `:<name>` is the two modules (what a site serves),
    `:<name>_types` the two declarations; `:<name>_js` and
    `:<name>_runtime_js` each module alone (`:<name>_dts` and
    `:<name>_runtime_dts` each declaration).

    `swift` is the annotated library (linked into the reactor and feeding the
    generator). `module_name` defaults to `swift`'s own Swift module name;
    `linkopts` append to the reactor link (e.g. a larger `-z stack-size`);
    `exports` (and `export_entries`, `reactor_deps`) select the production
    dead-stripped reactor shape (see `swift_wasm_reactor`). Bridges in one
    package share one staged runtime — the second passes `runtime = False`.

    Until 0.54 the bindings were TypeScript compiled with tsc
    (`ts_swift_wasm_library`, which is now this): the JavaScript written here
    is what tsc made of them, so a page runs the same code.
    """
    swift_wasm_reactor(
        name = name,
        swift = swift,
        module_name = module_name,
        linkopts = linkopts,
        exports = exports,
        export_entries = export_entries or HOST_ENTRIES,
        reactor_deps = reactor_deps,
        platform = platform,
        visibility = visibility,
    )

    # The generated module and its declarations (declared outputs, like any
    # codegen).
    ffi_generate(
        name = name + "_js",
        dep = swift,
        platform = platform,
        kind = "js",
        output_name = name + ".js",
        module_name = module_name,
        tags = tags,
        visibility = visibility,
    )
    ffi_generate(
        name = name + "_dts",
        dep = swift,
        platform = platform,
        kind = "dts",
        output_name = name + ".d.ts",
        module_name = module_name,
        tags = tags,
        visibility = visibility,
    )
    srcs = [":" + name + "_js"]
    types = [":" + name + "_dts"]
    if runtime:
        # The shared runtime, staged where the generated module imports it
        # ("./swift_ffi_runtime.js"). Real file copies (not symlinks):
        # bundlers that resolve realpaths must see them inside bindir.
        native.genrule(
            name = name + "_runtime_js",
            srcs = [_RUNTIME_JS],
            outs = ["swift_ffi_runtime.js"],
            cmd = "cp -L $< $@",
            tags = tags,
            visibility = visibility,
        )
        native.genrule(
            name = name + "_runtime_dts",
            srcs = [_RUNTIME_DTS],
            outs = ["swift_ffi_runtime.d.ts"],
            cmd = "cp -L $< $@",
            tags = tags,
            visibility = visibility,
        )
        srcs.append(":" + name + "_runtime_js")
        types.append(":" + name + "_runtime_dts")

    # The modules (what a site serves), and apart from them the declarations
    # (what a type checker reads), as ts_project gave them before 0.54.
    native.filegroup(
        name = name,
        srcs = srcs,
        tags = tags,
        visibility = visibility,
    )
    native.filegroup(
        name = name + "_types",
        srcs = types,
        tags = tags,
        visibility = visibility,
    )
