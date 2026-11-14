"""Features as WebAssembly side modules over one runtime module.

A reactor carries its own copy of the Swift standard library, Foundation and
Isomer's SwiftUI. Linked instead as a runtime module (those libraries once,
every public symbol exported) and a side module per feature (only the
feature's own code, its symbols imported from the runtime), a feature is
kilobytes. docs/side_modules.md has the design; the loaders are
//shared/wasm_host's `WasmDynamicLinker` (WasmKit) and
wasm/libraries/swift_ui/runtime/side_modules.js (browsers, web views).

    wasm_runtime_module(
        name = "runtime",
        deps = ["@isomer//wasm/libraries/swift_ui:hot_bridge", "@isomer//wasm/libraries/swift_ui:isomer"],
    )
    wasm_side_module(
        name = "feature",
        deps = [":feature_lib"],   # the feature's own swift_library (alwayslink)
    )

give `runtime.wasm` and `feature.wasm`. A feature binds to the exact runtime
build it was linked against (Swift has no library evolution on wasm), so
features are versioned per runtime build.
"""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_swift//swift:swift.bzl", "swift_binary")
load("@rules_swift//swift:swift_common.bzl", "swift_common")
load("//swift_ffi/rules:swift_wasm_reactor.bzl", "wasm_export_list")
load("//swift_ffi/rules:utils.bzl", "transition_binary")

_WASM_PLATFORM = Label("//swift_ffi/rules:wasm32-wasip1")

# What a runtime module exports beyond its own public symbols: libc functions
# features call that the runtime itself may not (so --gc-sections would
# otherwise drop them) and the stack protector's.
RUNTIME_LIBC_EXPORTS = [
    "malloc",
    "free",
    "aligned_alloc",
    "getenv",
    "round",
    "malloc_usable_size",
    "__stack_chk_fail",
    "__stack_chk_guard",
]

def _xlinker(flags):
    out = []
    for flag in flags:
        out += ["-Xlinker", flag]
    return out

# A runtime module's link: nothing dead-stripped (a feature may call any of
# it), the table exported and growable (a side module's slots go at its end),
# the stack pointer exported (side modules share it), undefined symbols
# allowed (the app's entry, which the feature defines), the reactor's 16 MiB
# stack. What it exports: every public symbol (RUNTIME_LINKOPTS), or what the
# host calls and its features import (`exports_for`).
_RUNTIME_BASE_LINKOPTS = _xlinker([
    "--no-gc-sections",
    "--export-table",
    "--growable-table",
    "--export=__stack_pointer",
    "--allow-undefined",
    "-z",
    "stack-size=16777216",
] + ["--export=" + name for name in RUNTIME_LIBC_EXPORTS])

RUNTIME_LINKOPTS = _xlinker(["--export-dynamic"]) + _RUNTIME_BASE_LINKOPTS

# What a host calls of a runtime module beyond what every runtime exports
# (the table, the stack pointer, the libc functions above): its
# initialization, the iso_hot ABI and swift_ffi's entries (the dependencies'
# register exports among them).
RUNTIME_HOST_ENTRIES = ["_initialize", "iso_hot_*", "swift_ffi_*"]

def wasm_runtime_module(name, deps, exports_for = [], linkopts = [], copts = [], tags = [], visibility = None, **kwargs):
    """A runtime module: `deps` linked once, for side modules to link against.

    `deps` are what a feature's reactor links but the feature: the iso_hot
    bridge (`@isomer//wasm/libraries/swift_ui:hot_bridge`) and the SwiftUI
    the features use. Gives `<name>.wasm`, with its names (mixed mode's
    split reads them; strip it to ship).

    It exports every public symbol, unless `exports_for` names the side
    modules it serves: then what the host calls and what those side modules
    import. Every public symbol of Isomer's runtime is more than the 100,000
    exports the WebAssembly JS API lets a browser or web view load (WasmKit
    has no such limit); a feature binds to its runtime's build anyway.

    Args:
        name: The target; `<name>.wasm` is the module.
        deps: The libraries in it.
        exports_for: `wasm_side_module` targets whose imports it exports.
        linkopts: More link options.
        copts: More Swift options for the binary's (empty) module.
        tags: Tags for both targets (`manual` is added to the binary).
        visibility: The module's visibility.
        **kwargs: Passed to the `swift_binary`.
    """
    exports = RUNTIME_LINKOPTS
    linker_inputs = []
    if exports_for:
        # Linked once exporting everything, to read the host's entries from
        # (as reactors are: swift_wasm_reactor.bzl's wasm_export_list).
        swift_binary(
            name = name + "_all_binary",
            copts = ["-enable-experimental-feature", "Extern"] + copts,
            linkopts = RUNTIME_LINKOPTS + linkopts,
            linkshared = True,
            deps = deps,
            tags = ["manual"] + tags,
            **kwargs
        )
        transition_binary(
            name = name + "_all.wasm",
            binary = ":" + name + "_all_binary",
            platform = _WASM_PLATFORM,
            tags = ["manual"] + tags,
        )
        wasm_export_list(
            name = name + "_host_exports",
            wasm = ":" + name + "_all.wasm",
            entries = RUNTIME_HOST_ENTRIES,
        )
        native.genrule(
            name = name + "_feature_exports",
            srcs = exports_for,
            outs = [name + "_feature_exports.rsp"],
            cmd = "$(location %s) $@ $(SRCS)" % Label("//tools/wasm/side_module_imports"),
            tools = [Label("//tools/wasm/side_module_imports")],
            tags = tags,
        )
        exports = _RUNTIME_BASE_LINKOPTS + [
            "@$(location :%s_host_exports)" % name,
            "@$(location :%s_feature_exports)" % name,
        ]
        linker_inputs = [":" + name + "_host_exports", ":" + name + "_feature_exports"]
    swift_binary(
        name = name + "_binary",
        copts = ["-enable-experimental-feature", "Extern"] + copts,
        linkopts = exports + linkopts,
        additional_linker_inputs = linker_inputs,
        linkshared = True,
        deps = deps,
        tags = ["manual"] + tags,
        **kwargs
    )
    transition_binary(
        name = name + ".wasm",
        binary = ":" + name + "_binary",
        platform = _WASM_PLATFORM,
        tags = tags,
        visibility = visibility,
    )

def _to_wasm_impl(_settings, _attr):
    return {"//command_line_option:platforms": [str(_WASM_PLATFORM)]}

_to_wasm = transition(
    implementation = _to_wasm_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _wasm_side_module_impl(ctx):
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

    # The toolchain links wasm through its clang; wasm-ld is beside it.
    clang = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = "c++-link-executable",
    )
    wasm_ld = clang.rpartition("/")[0] + "/wasm-ld"

    # swiftrt.o: its constructor registers the module's Swift metadata
    # (conformances, types) with the runtime. The wasm Swift SDK hands it to
    # links through the Swift toolchain's implicit link inputs.
    swiftrt = None
    for cc_info in swift_common.get_toolchain(ctx).implicit_deps_providers.cc_infos:
        for linker_input in cc_info.linking_context.linker_inputs.to_list():
            for file in linker_input.additional_inputs:
                if file.basename == "swiftrt.o":
                    swiftrt = file
    if not swiftrt:
        fail("the wasm Swift toolchain links no swiftrt.o")

    # The feature's own archives: what `deps` themselves link, not what
    # they depend on (that is the runtime's).
    archives = []
    for dep in ctx.attr.deps:
        for linker_input in dep[CcInfo].linking_context.linker_inputs.to_list():
            if linker_input.owner != dep.label:
                continue
            for library in linker_input.libraries:
                archive = library.pic_static_library or library.static_library
                if archive:
                    archives.append(archive)
    if not archives:
        fail("%s: deps link nothing of their own" % ctx.label)

    unfixed = ctx.actions.declare_file(ctx.label.name + ".unfixed.wasm")
    link_map = ctx.actions.declare_file(ctx.label.name + ".map")
    output = ctx.actions.declare_file(ctx.label.name + ".wasm")

    args = ctx.actions.args()
    args.add_all([
        "--experimental-pic",
        "-shared",
        # Its own symbols bound locally: the loader resolves GOT entries
        # against what is already loaded.
        "-Bsymbolic",
        "--unresolved-symbols=import-dynamic",
        # Every input segment kept: the fixup finds a relative pointer's
        # segment by its name and its place among the object's segments of
        # that name (Swift's objects have dozens called swift5_typeref), which
        # dead-stripping some of them would shift. A side module is the
        # feature's own code; little of it is unused.
        "--no-gc-sections",
    ])
    if ctx.attr.strip:
        args.add("--strip-all")
    args.add("--whole-archive")
    args.add_all(archives)
    args.add("--no-whole-archive")
    args.add(swiftrt)
    args.add_all(ctx.attr.exports, format_each = "--export=%s")
    args.add(link_map, format = "-Map=%s")
    args.add("-o", unfixed)
    ctx.actions.run(
        executable = wasm_ld,
        arguments = [args],
        inputs = depset(archives + [swiftrt], transitive = [cc_toolchain.all_files]),
        outputs = [unfixed, link_map],
        mnemonic = "WasmSideModuleLink",
        progress_message = "Linking side module %s" % ctx.label,
    )

    # Swift's relative pointers: the toolchain's wasm-ld (Swift 6.4.2's) gives
    # them a runtime relocation that adds __memory_base; the fixup removes
    # those (tools/wasm/side_module_fixup).
    fixup = ctx.actions.args()
    fixup.add("--map", link_map)
    fixup.add("--out", output)
    fixup.add(unfixed)
    fixup.add_all(archives)
    ctx.actions.run(
        executable = ctx.executable._fixup,
        arguments = [fixup],
        inputs = [unfixed, link_map] + archives,
        outputs = [output],
        mnemonic = "WasmSideModuleFixup",
        progress_message = "Correcting relative pointers in %s" % ctx.label,
    )
    return [DefaultInfo(files = depset([output]))]

wasm_side_module = rule(
    implementation = _wasm_side_module_impl,
    doc = "A feature linked as a WebAssembly side module (`<name>.wasm`).",
    cfg = _to_wasm,
    attrs = {
        "deps": attr.label_list(
            doc = "The feature's own libraries (alwayslink swift_library targets); what they depend on is the runtime module's.",
            providers = [CcInfo],
        ),
        "exports": attr.string_list(
            default = ["__main_argc_argv"],
            doc = "Symbols to export besides those the loader calls: the app's entry, which the runtime calls.",
        ),
        "strip": attr.bool(
            default = True,
            doc = "Strip names (the shipped shape).",
        ),
        "_fixup": attr.label(
            default = Label("//tools/wasm/side_module_fixup"),
            executable = True,
            cfg = "exec",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    fragments = ["cpp"],
    toolchains = use_cc_toolchain() + swift_common.use_toolchain(),
)
