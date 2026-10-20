"""`ts_swift_wasm_library`: TypeScript (the browser) consuming a bridged
Swift module compiled to a WebAssembly reactor."""

load("@aspect_rules_ts//ts:defs.bzl", "ts_project")
load(":swift_wasm_reactor.bzl", "HOST_ENTRIES", "swift_wasm_reactor")
load(":utils.bzl", "ffi_generate", "pick_output")

_RUNTIME_TS = Label("//swift_ffi/runtime/ts:swift_ffi_runtime.ts")

# Self-contained compiler options for bridge modules (written as an
# in-package synthetic tsconfig by ts_project).
_BRIDGE_TSCONFIG = {
    "compilerOptions": {
        "module": "es2022",
        "moduleResolution": "bundler",
        "target": "es2022",
        "lib": ["es2022", "esnext.disposable", "dom"],
        "types": [],
        "strict": True,
        "sourceMap": False,
        "declaration": True,
    },
}

def ts_swift_wasm_library(
        name,
        swift,
        deps = [],
        module_name = None,
        linkopts = [],
        exports = None,
        export_entries = None,
        reactor_deps = [],
        platform = Label("//swift_ffi/rules:wasm32-wasip1"),
        runtime = True,
        visibility = None,
        **kwargs):
    """WebAssembly bridge: a wasm reactor (`:<name>.wasm`, whose exports are
    the module's C ABI) + a real `ts_project` named `:<name>` compiling the
    generated bindings (typed, ES2022 modules: `<name>.js` + `<name>.d.ts`,
    plus the staged shared runtime `swift_ffi_runtime.js`).

    `swift` is the annotated library (linked into the reactor and feeding the
    generator); `deps`/`**kwargs` pass through to the ts_project (add npm
    packages there if your Swift surface needs them). `module_name` defaults
    to `swift`'s own Swift module name; `linkopts` append to the reactor link
    (e.g. a larger `-z stack-size`); `exports` (and `export_entries`,
    `reactor_deps`) select the production dead-stripped reactor shape (see
    `swift_wasm_reactor`). Bridges in one package share one staged
    runtime — the second passes `runtime = False`.
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

    # The generated bindings source (a declared output, like any codegen).
    ffi_generate(
        name = name + "_gen_ts",
        dep = swift,
        platform = platform,
        kind = "ts",
        output_name = name + ".ts",
        module_name = module_name,
    )
    srcs = [":" + name + "_gen_ts"]
    if runtime:
        # The shared runtime, staged where the generated module imports it
        # ("./swift_ffi_runtime.js"). A real file copy (not a symlink):
        # bundlers that resolve realpaths must see it inside bindir.
        native.genrule(
            name = name + "_runtime_ts",
            srcs = [_RUNTIME_TS],
            outs = ["swift_ffi_runtime.ts"],
            cmd = "cp -L $< $@",
        )
        srcs.append(":" + name + "_runtime_ts")

    # Individual compiled outputs, addressable for consumer-side
    # post-processing (e.g. shadowing just the runtime while passing the
    # generated module through): `:<name>_js` and `:<name>_runtime_js`,
    # peers of the already-addressable `:<name>.wasm`.
    pick_output(
        name = name + "_js",
        src = ":" + name,
        basename = name + ".js",
        visibility = visibility,
    )
    if runtime:
        pick_output(
            name = name + "_runtime_js",
            src = ":" + name,
            basename = "swift_ffi_runtime.js",
            visibility = visibility,
        )

    ts_project(
        name = name,
        srcs = srcs,
        declaration = True,
        transpiler = "tsc",
        tsconfig = _BRIDGE_TSCONFIG,
        # Resolved against swift_ffi's repo mapping so consumers don't need
        # their own rules_ts/npm setup.
        tsc = Label("@npm_typescript//:tsc"),
        tsc_worker = Label("@npm_typescript//:tsc_worker"),
        validator = Label("@npm_typescript//:validator"),
        visibility = visibility,
        deps = deps,
        **kwargs
    )
