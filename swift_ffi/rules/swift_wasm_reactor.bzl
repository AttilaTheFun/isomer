"""`swift_wasm_reactor`: an annotated module compiled to a standalone
WebAssembly reactor (its macro-expanded `@c` exports ARE the C ABI)."""

load("@rules_swift//swift:swift_binary.bzl", "swift_binary")
load(":utils.bzl", "REACTOR_STUB", _transition_binary = "transition_binary")

# Re-exported for consumers that assemble bespoke reactors (extra sources,
# custom export lists) around their own swift_binary.
transition_binary = _transition_binary

# wasm-ld needs the `@c` exports retained in the reactor. We can't enumerate
# the symbol names at analysis time, so by DEFAULT export everything and keep
# it from being garbage-collected (the dev shape). A production reactor
# passes `exports = [...]` instead (below) for a dead-stripped module.
WASM_LINKOPTS = [
    "-Xlinker",
    "--export-all",
    "-Xlinker",
    "--no-gc-sections",
]

# The fixed-name runtime entries every host drives (docs/abi.md) — appended
# automatically to a curated `exports` list so a consumer cannot strip the
# staging allocator or box drains by accident (the failure is silent: staged
# buffers alloc nothing and completions arrive empty). `--export-if-defined`
# because a module that never uses Lazy still links.
_FIXED_RUNTIME_EXPORTS = [
    "_initialize",
    "swift_ffi_alloc",
    "swift_ffi_dealloc",
    "swift_ffi_string_len",
    "swift_ffi_string_copy",
    "swift_ffi_string_release",
    "swift_ffi_lazy_get",
    "swift_ffi_lazy_release",
    "swift_ffi_task_run",
    "swift_ffi_async_resume",
]

# What a host looks up in a reactor by name, for `exports = "host"` and
# `wasm_export_list`: swift_ffi's entries (generated and fixed), the
# reactor's initializer, and what the runtimes read (the heap's start and
# the data's end, between which WAMR puts the stack it is given; the
# allocator; the function table).
HOST_ENTRIES = [
    "swift_ffi_*",
    "_initialize",
    "__heap_base",
    "__data_end",
    "malloc",
    "free",
    "__indirect_function_table",
]

def wasm_export_list(name, wasm, entries = HOST_ENTRIES, visibility = None):
    """The exports a shipped reactor needs, read from a link of it with every
    symbol exported (`wasm`, linked `--export-all --no-gc-sections`): a
    response file (`<name>.rsp`) for the clang driver that links reactors, of
    `-Wl,--export-if-defined=` lines for the exports matching `entries`
    (`prefix*` or a name).

    Link the shipped reactor again from the same objects with
    `-Xlinker --gc-sections` and `@$(location :<name>)` (clang expands it, so
    not behind `-Xlinker`), the file in `additional_linker_inputs`.
    Exporting everything keeps every function and value in the program
    (Visor's reactor: 144,233 exports, an export section of 10 MB, nothing
    dropped), where its hosts call some sixty; and the names a host calls
    cannot be listed while the build is planned, but read from the first
    link they cannot drift from the code.
    """
    native.genrule(
        name = name,
        srcs = [wasm],
        outs = [name + ".rsp"],
        cmd = "$(location %s) $< $@ %s" % (
            Label("//swift_ffi/rules:export_list"),
            " ".join(["'%s'" % entry for entry in entries]),
        ),
        tools = [Label("//swift_ffi/rules:export_list")],
        tags = ["manual"],
        visibility = visibility,
    )

def swift_wasm_reactor(
        name,
        swift,
        module_name = None,
        linkopts = [],
        exports = None,
        export_entries = HOST_ENTRIES,
        reactor_deps = [],
        platform = Label("//swift_ffi/rules:wasm32-wasip1"),
        visibility = None):
    """A swift_ffi module compiled to a standalone WebAssembly reactor
    (`:<name>.wasm`).

    By default the whole macro-expanded `@c` ABI is exported and nothing is
    garbage-collected (the dev shape — symbol names aren't enumerable at
    analysis time). Pass `exports = [...]` for a PRODUCTION reactor instead:
    the module links with `--gc-sections` and exports exactly your list plus
    the fixed runtime entries (`swift_ffi_alloc`, the string/Lazy boxes,
    `_initialize`, `swift_ffi_task_run`), which are appended automatically.
    List every symbol a host calls: your `swift_ffi_[<ns>_]<function>` and
    `..._<Proto>_invoke`/`_release` entries, and — if the host injects
    dependencies — every `swift_ffi_[<ns>_]register_<Proto>` export (a missing
    register means the guest's proxy factory never files and lookups resolve
    nil). A typo fails the link loudly (`--export`, not `-if-defined`). Add
    `--strip-all` via `linkopts` yourself if you also want names stripped.

    `exports = "host"` is the production shape without the list: the
    reactor is linked once exporting everything, the exports matching
    `export_entries` (`prefix*` or a name; `HOST_ENTRIES` by default, all of
    swift_ffi's) are read from it (`wasm_export_list`), and the reactor
    shipped exports those and drops the rest. `reactor_deps` are linked into
    the reactor shipped only (not the one its exports are read from): what
    replaces part of the program read from that one (a trimmed ICU's data).

    The same reactor any wasm host loads — the browser (`ts_swift_wasm_library`
    bundles its own), a native Swift host (`swift_wasm_library`), or a plain C
    host driving WAMR (`//swift_ffi/runtime/c_host_wamr`). `c_host_library`
    deliberately builds no reactor (a C host with no Swift usually gets one from
    the app that owns it), so a self-contained C-host application pairs this with
    it. `module_name` is unused (kept for call-site compatibility); `linkopts`
    append to the reactor link (e.g. a larger `-z stack-size`).
    """
    _ = module_name  # The ABI ships inside `swift`; nothing is generated here.
    linker_inputs = []
    if exports == None:
        export_linkopts = WASM_LINKOPTS
    elif exports == "host":
        # Linked twice: once exporting everything, to read the entries
        # matching `export_entries` from (wasm_export_list), then the reactor
        # shipped, exporting just those and dropping what they do not reach.
        swift_binary(
            name = name + "_all_reactor",
            srcs = [REACTOR_STUB],
            module_name = name + "_all_reactor",
            deps = [swift],
            linkshared = True,
            linkopts = WASM_LINKOPTS + linkopts,
            tags = ["manual"],
        )
        _transition_binary(
            name = name + "_all.wasm",
            binary = ":" + name + "_all_reactor",
            platform = platform,
            tags = ["manual"],
        )
        wasm_export_list(
            name = name + "_exports",
            wasm = ":" + name + "_all.wasm",
            entries = export_entries,
        )
        export_linkopts = ["-Xlinker", "--gc-sections", "@$(location :%s_exports)" % name]
        linker_inputs = [":" + name + "_exports"]
    else:
        export_linkopts = ["-Xlinker", "--gc-sections"]
        for symbol in _FIXED_RUNTIME_EXPORTS:
            export_linkopts += ["-Xlinker", "--export-if-defined=" + symbol]
        for symbol in exports:
            export_linkopts += ["-Xlinker", "--export=" + symbol]
    swift_binary(
        name = name + "_reactor",
        srcs = [REACTOR_STUB],
        additional_linker_inputs = linker_inputs,
        module_name = name + "_reactor",
        deps = [swift] + reactor_deps,
        linkshared = True,
        linkopts = export_linkopts + linkopts,
        tags = ["manual"],
    )
    _transition_binary(
        name = name + ".wasm",
        binary = ":" + name + "_reactor",
        platform = platform,
        tags = ["manual"],
        visibility = visibility,
    )
