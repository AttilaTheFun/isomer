"""`ts_swift_wasm_library`: the name `js_swift_wasm_library` had until 0.54,
when swift_ffi's web bindings stopped being TypeScript compiled with tsc
(an Isomer app's build then needed rules_ts, rules_js and a TypeScript of
Isomer's choosing). Kept so a BUILD file that loads it still builds: the
outputs are the same files (`<name>.js`, `<name>.d.ts`,
`swift_ffi_runtime.js` and `.d.ts`, `:<name>.wasm`). Load
`js_swift_wasm_library` from js_swift_wasm_library.bzl instead."""

load(":js_swift_wasm_library.bzl", "js_swift_wasm_library")

def ts_swift_wasm_library(name, swift, deps = [], **kwargs):
    """Deprecated: `js_swift_wasm_library`. `deps` were the ts_project's
    (npm packages for tsc); with no compile there is nothing to give them to.
    """
    if deps:
        fail("ts_swift_wasm_library(deps = ...): nothing compiles the bindings since 0.54 " +
             "(js_swift_wasm_library); type-check your own TypeScript against <name>.d.ts instead")
    js_swift_wasm_library(name = name, swift = swift, **kwargs)
