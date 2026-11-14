"""Mixed mode's native part: native copies of a runtime module's hot functions.

The runtime module (tools/wasm/side_modules.bzl's `wasm_runtime_module`)
stays one wasm module that WasmKit interprets; native copies of a set of its
functions, compiled to C by WABT's wasm2c, go into the app beside it and run
over the same memory and table (`MixedWasmKitRuntime`,
//shared/wasm_host:mixed_runtime; docs/side_modules.md).

    wasm_mixed_native(
        name = "native",
        runtime = ":runtime.wasm",       # with its names (not stripped)
        native_set = "native_set.txt",   # the functions to copy, by name
        routed = "routed.txt",           # runtime functions features call natively
    )

gives `:native` (a cc_library of the native part, for the app to link) and
`:native_shim` / `:native_slots` (`native_generated/shim.wasm` and
`native_generated/slots.txt`, which `MixedNativePart` reads at launch, e.g.
from the app's bundle). The
native set comes from profiling the app (docs/side_modules.md); a set naming
functions the runtime no longer has still builds, without them.
"""

load("@rules_cc//cc:defs.bzl", "cc_library")

# The runtime's entry points the host calls, which the native part must
# export (wasm-split keeps exported functions native).
MIXED_ENTRIES = [
    "memory",
    "__indirect_function_table",
    "__stack_pointer",
    "iso_hot_start",
    "iso_hot_render",
    "iso_hot_render_pending",
    "iso_hot_event",
    "iso_hot_resize",
    "iso_hot_alloc",
    "iso_hot_free",
    "iso_hot_shutdown",
    "iso_hot_pending_tasks",
    "iso_hot_configure",
    "iso_hot_set_color_scheme",
    # The guest's Swift jobs (a view's Task, a timer): entry points too, or
    # every job runs interpreted.
    "swift_ffi_task_run",
    "swift_ffi_async_resume",
]

_OUTPUTS = ["hot_%d.c" % k for k in range(8)] + [
    "hot.h",
    "hot-impl.h",
    "mixed_glue.c",
    "mixed_glue.h",
    "shim.wasm",
    "slots.txt",
]

def _wasm_mixed_generate_impl(ctx):
    outputs = {name: ctx.actions.declare_file("%s/%s" % (ctx.label.name, name)) for name in _OUTPUTS}
    out_dir = outputs["hot.h"].dirname
    wasm_split = [f for f in ctx.files._wasm_split if f.basename == "wasm-split"][0]
    entries = ",".join(MIXED_ENTRIES + ["@" + f.path for f in ctx.files.routed])
    args = ctx.actions.args()
    args.add("generate")
    args.add("--wasm-split", wasm_split)
    args.add("--wasm2c", ctx.executable._wasm2c)
    args.add("--wat2wasm", ctx.executable._wat2wasm)
    args.add("--runtime", ctx.file.runtime)
    args.add("--set", ctx.file.native_set)
    args.add("--entries", entries)
    args.add("--out", out_dir)
    ctx.actions.run(
        executable = ctx.executable._generator,
        arguments = [args],
        inputs = ctx.files._wasm_split + [ctx.file.runtime, ctx.file.native_set] + ctx.files.routed,
        tools = [ctx.attr._wasm2c[DefaultInfo].files_to_run, ctx.attr._wat2wasm[DefaultInfo].files_to_run],
        outputs = outputs.values(),
        mnemonic = "WasmMixedGenerate",
        progress_message = "Generating mixed mode's native part for %s" % ctx.label,
    )
    return [DefaultInfo(files = depset(outputs.values()))]

_wasm_mixed_generate = rule(
    implementation = _wasm_mixed_generate_impl,
    attrs = {
        "runtime": attr.label(allow_single_file = [".wasm"], mandatory = True),
        "native_set": attr.label(allow_single_file = True, mandatory = True),
        "routed": attr.label(allow_files = True),
        "_generator": attr.label(default = Label("//tools/wasm_mixed"), executable = True, cfg = "exec"),
        "_wasm_split": attr.label(default = Label("//tools/wasm_mixed:wasm_split"), cfg = "exec"),
        "_wasm2c": attr.label(default = Label("//tools/wasm_mixed:wasm2c"), executable = True, cfg = "exec"),
        "_wat2wasm": attr.label(default = Label("//tools/wasm_mixed:wat2wasm"), executable = True, cfg = "exec"),
    },
)

def _pick_impl(ctx):
    for f in ctx.files.src:
        if f.basename == ctx.attr.basename:
            return [DefaultInfo(files = depset([f]))]
    fail("no %s in %s" % (ctx.attr.basename, ctx.attr.src.label))

_pick = rule(
    implementation = _pick_impl,
    attrs = {
        "src": attr.label(mandatory = True),
        "basename": attr.string(mandatory = True),
    },
)

def _c_sources_impl(ctx):
    return [DefaultInfo(files = depset([f for f in ctx.files.src if f.extension in ("c", "h")]))]

_c_sources = rule(
    implementation = _c_sources_impl,
    attrs = {"src": attr.label(mandatory = True)},
)

def wasm_mixed_native(name, runtime, native_set, routed = None, bounds_checks = False, tags = [], visibility = None):
    """The native part of a runtime module in mixed mode.

    Args:
        name: `:<name>` is the cc_library; `:<name>_shim` and `:<name>_slots`
            the shim module and slot map `MixedNativePart` reads.
        runtime: The runtime module, with its name section.
        native_set: The functions to copy to native code, one name a line.
        routed: Runtime functions features call through their native copies.
        bounds_checks: Compile memory bounds checks into the native code. Off,
            it relies on WasmKit's guard pages (faster, 3.9 MB against 7.4 MB
            of native code for the Storybook's runtime), and
            MixedWasmKitRuntime refuses to launch where WasmKit has none.
        tags: Tags for every target.
        visibility: The cc_library's and files' visibility.
    """
    _wasm_mixed_generate(
        name = name + "_generated",
        runtime = runtime,
        native_set = native_set,
        routed = routed,
        tags = tags,
    )
    for output, basename in [("shim", "shim.wasm"), ("slots", "slots.txt")]:
        _pick(
            name = name + "_" + output,
            src = ":" + name + "_generated",
            basename = basename,
            tags = tags,
            visibility = visibility,
        )
    _c_sources(
        name = name + "_c",
        src = ":" + name + "_generated",
        tags = tags,
    )
    native.genrule(
        name = name + "_mode",
        outs = [name + "_mode.c"],
        cmd = "echo 'int iso_mixed_checks_bounds(void) { return %d; }' > $@" % (1 if bounds_checks else 0),
        tags = tags,
    )
    cc_library(
        name = name,
        srcs = [
            ":" + name + "_c",
            ":" + name + "_mode",
            Label("@wabt_sources//:runtime_srcs"),
        ],
        # The generated files include each other as siblings, and wasm2c's
        # runtime headers.
        copts = [
            "-O2",
            "-w",
        ],
        # wasm2c's runtime: memory is WasmKit's (the bridge's), no signal
        # handler of wasm2c's own (WasmKit's), and traps end the process
        # (iso_mixed_trap_handler: native code can't unwind into Swift).
        defines = [
            "WASM_RT_USE_MMAP=1",
            "WASM_RT_SKIP_SIGNAL_RECOVERY=1",
            "WASM_RT_NONCONFORMING_UNCHECKED_STACK_EXHAUSTION=1",
            "WASM_RT_TRAP_HANDLER=iso_mixed_trap_handler",
        ] + (["WASM_RT_MEMCHECK_BOUNDS_CHECK=1"] if bounds_checks else ["WASM_RT_MEMCHECK_GUARD_PAGES=1"]),
        alwayslink = True,
        tags = tags,
        visibility = visibility,
        deps = [Label("@wabt_sources//:runtime_headers")],
    )
