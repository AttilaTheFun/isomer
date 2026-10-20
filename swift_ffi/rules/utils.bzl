"""Internal shared Starlark for the swift_ffi rules: the analyzer aspect and
its provider, the generator invocation rule, the platform transition, and
small helpers. Nothing here is public API — load the per-macro files
(`kt_swift_library.bzl`, `ts_swift_wasm_library.bzl`, …) instead."""

load("@rules_swift//swift:providers.bzl", "SwiftInfo")

# --- The analyzer aspect (per-source FFI IR) ---------------------------------

FFIAnalysisInfo = provider(
    doc = "Propagates the per-source JSON IR produced by the analyzer aspect.",
    fields = {
        "analysis_files": "The analysis JSON files produced directly by this target.",
        "transitive_analysis_files": "Depset of this target's and its dependencies' analysis files.",
        "reaches_runtime": "Whether this target is, or depends on, the swift_ffi runtime (the module the export macros are declared in).",
    },
)

# The module that declares the export macros: a library that neither is it
# nor depends on it cannot export anything, so its sources are not analyzed
# (Foundation and the rest of a platform's libraries).
_RUNTIME_MODULE = "IsomerFFI"

# Attributes the aspect follows to analyze the whole dependency tree.
# `actual`: an `alias` in the dependency graph (a per-platform select of the
# bridged library) is transparent — the aspect follows it to the real target.
_DEPS_ATTRS = ["deps", "private_deps", "actual"]

def _analyze_sources(ctx, analyzer, label, srcs, module_name):
    analysis_files = []
    for src in srcs:
        if not src.path.endswith(".swift"):
            continue
        # Named by the source's path in its package: two files of one
        # target may share a basename in different directories.
        relative = src.short_path
        if label.package and relative.find(label.package + "/") >= 0:
            relative = relative[relative.find(label.package + "/") + len(label.package) + 1:]
        analysis_file = ctx.actions.declare_file("{}_{}_ffi.json".format(
            label.name,
            relative.replace("/", "__").replace(".", "_"),
        ))
        args = ctx.actions.args()
        args.add("--source-file-path", src)
        args.add("--module-name", module_name)
        args.add("--analysis-file-path", analysis_file)
        ctx.actions.run(
            inputs = [src],
            outputs = [analysis_file],
            arguments = [args],
            executable = analyzer,
            mnemonic = "SwiftFFIAnalyze",
            progress_message = "Analyzing %s for swift_ffi exports" % src.short_path,
            # The analyzer is a swift.org-toolchain swift_binary; run as a build
            # action it must find the dynamic Swift runtime (libswiftCore.so /
            # swiftCore.dll). Bazel's strict action env scrubs the PATH the
            # Windows loader needs, so run under the default shell env instead.
            # (Linux additionally needs the action to run in the exec root so the
            # toolchain's relative RUNPATH resolves — consumers pin this mnemonic
            # to the local strategy; macOS resolves via absolute install-names.)
            use_default_shell_env = True,
        )
        analysis_files.append(analysis_file)
    return analysis_files

def _analyzer_aspect_impl(target, ctx):
    transitive = []
    reaches_runtime = False
    for attr in _DEPS_ATTRS:
        value = getattr(ctx.rule.attr, attr, None)
        if value == None:
            continue
        # `actual` (alias) is a single target; deps are lists.
        deps = value if type(value) == "list" else [value]
        for dep in deps:
            if FFIAnalysisInfo in dep:
                transitive.append(dep[FFIAnalysisInfo].transitive_analysis_files)
                reaches_runtime = reaches_runtime or dep[FFIAnalysisInfo].reaches_runtime

    # The declaring module, so generators can emit an import for every
    # module that contributed exports (they may be transitive deps).
    module_name = getattr(ctx.rule.attr, "module_name", "") or target.label.name
    reaches_runtime = reaches_runtime or module_name == _RUNTIME_MODULE

    srcs = getattr(ctx.rule.files, "srcs", []) if reaches_runtime else []
    analysis_files = _analyze_sources(
        ctx, ctx.executable._analyzer, target.label, srcs, module_name)

    return [FFIAnalysisInfo(
        analysis_files = analysis_files,
        transitive_analysis_files = depset(
            direct = analysis_files,
            transitive = transitive,
        ),
        reaches_runtime = reaches_runtime,
    )]

analyzer_aspect = aspect(
    implementation = _analyzer_aspect_impl,
    attr_aspects = _DEPS_ATTRS,
    attrs = {
        "_analyzer": attr.label(
            default = "//swift_ffi/swift_ffi_analyzer",
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Collects swift_ffi export IR from a swift_library and its dependencies.",
)

# --- The generator invocation rule -------------------------------------------

def _module_name(ctx, dep):
    """The bridged Swift module: an explicit override, or the dep's own name."""
    if ctx.attr.module_name:
        return ctx.attr.module_name
    if SwiftInfo in dep:
        for module in dep[SwiftInfo].direct_modules:
            if module.swift:
                return module.name
    return dep.label.name

def _ffi_generate_impl(ctx):
    # `dep` carries an (optional) platform transition, so it is a list.
    dep = ctx.attr.dep[0]
    analysis_files = dep[FFIAnalysisInfo].transitive_analysis_files
    module_name = _module_name(ctx, dep)

    # By convention the Kotlin facade for module `Foo` is `FooBridge`.
    java_class = ctx.attr.java_class or (module_name + "Bridge")

    # Pass the analysis file paths through a JSON manifest to dodge command-line
    # length limits and keep the action's inputs explicit.
    manifest = ctx.actions.declare_file(ctx.label.name + "_manifest.json")
    ctx.actions.write(
        output = manifest,
        content = json.encode([f.path for f in analysis_files.to_list()]),
    )

    output = ctx.actions.declare_file(ctx.attr.output_name)

    args = ctx.actions.args()
    args.add("--analysis-manifest", manifest)
    args.add("--kind", ctx.attr.kind)
    args.add("--output", output)
    args.add("--module-name", module_name)
    args.add("--java-package", ctx.attr.java_package)
    args.add("--java-class", java_class)
    args.add("--library-name", ctx.attr.library_name)
    if ctx.attr.header_name:
        args.add("--header-name", ctx.attr.header_name)

    ctx.actions.run(
        inputs = depset([manifest], transitive = [analysis_files]),
        outputs = [output],
        arguments = [args],
        executable = ctx.executable._generator,
        mnemonic = "SwiftFFIGenerate",
        progress_message = "Generating swift_ffi %s bindings for %s" % (ctx.attr.kind, ctx.label.name),
        # See the analyzer aspect above: the generator is a swift.org-toolchain
        # swift_binary that must find the dynamic Swift runtime when run as a
        # build action, which Bazel's strict action env otherwise hides.
        use_default_shell_env = True,
    )

    return [DefaultInfo(files = depset([output]))]

def _dep_platform_transition_impl(settings, attr):
    # Optional: no `platform` keeps the caller's configuration.
    if not attr.platform:
        return {"//command_line_option:platforms": settings["//command_line_option:platforms"]}
    return {"//command_line_option:platforms": [attr.platform]}

_dep_platform_transition = transition(
    implementation = _dep_platform_transition_impl,
    inputs = ["//command_line_option:platforms"],
    outputs = ["//command_line_option:platforms"],
)

ffi_generate = rule(
    implementation = _ffi_generate_impl,
    attrs = {
        "dep": attr.label(
            mandatory = True,
            aspects = [analyzer_aspect],
            # Analyzed in the TARGET platform's configuration (when `platform`
            # is set): a per-platform `select`/alias in the library's deps
            # then resolves to the platform's real module, not the host's.
            cfg = _dep_platform_transition,
            doc = "The swift_library whose annotated sources are bridged.",
        ),
        "platform": attr.label(
            doc = "The platform whose configuration `dep` is analyzed in (the bridged binary's).",
        ),
        "kind": attr.string(
            mandatory = True,
            values = ["jni-adapter", "c-header", "cpp", "rust", "ts", "kotlin", "swift-host-wasm", "c-host-wasm"],
        ),
        "output_name": attr.string(mandatory = True, doc = "Generated file name."),
        "module_name": attr.string(
            doc = "Override for the bridged Swift module; defaults to the dep's module name.",
        ),
        "java_package": attr.string(default = "com.example"),
        "java_class": attr.string(
            doc = "Override for the Kotlin facade name; defaults to <Module>Bridge.",
        ),
        "library_name": attr.string(default = "native"),
        "header_name": attr.string(
            doc = "The generated C header file name the jni-adapter/cpp artifacts include.",
        ),
        "_generator": attr.label(
            default = "//swift_ffi/swift_ffi_generator",
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Generates one swift_ffi bridge artifact from a swift_library.",
)

# --- The platform transition --------------------------------------------------

def _platform_transition_impl(_settings, attr):
    return {"//command_line_option:platforms": [attr.platform]}


_platform_transition = transition(
    implementation = _platform_transition_impl,
    inputs = ["//command_line_option:platforms"],
    outputs = ["//command_line_option:platforms"],
)

def _transition_binary_impl(ctx):
    # Forward the (single) file from the transitioned binary under the rule's
    # own name, so the artifact lands at e.g. `libgreeter.so` / `greeter.wasm`.
    binary = ctx.attr.binary[0]
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = out, target_file = binary[DefaultInfo].files.to_list()[0])
    return [DefaultInfo(files = depset([out]))]

transition_binary = rule(
    implementation = _transition_binary_impl,
    attrs = {
        "binary": attr.label(cfg = _platform_transition, mandatory = True),
        "platform": attr.label(mandatory = True, doc = "Target platform to build for."),
    },
    doc = "Builds `binary` for `platform` and republishes it under this target's name.",
)

# --- Small helpers -------------------------------------------------------------

def _pick_output_impl(ctx):
    """Exposes ONE file of a target's default outputs by basename."""
    for f in ctx.attr.src[DefaultInfo].files.to_list():
        if f.basename == ctx.attr.basename:
            return [DefaultInfo(files = depset([f]))]
    fail("no output named %s in %s" % (ctx.attr.basename, ctx.attr.src.label))

pick_output = rule(
    implementation = _pick_output_impl,
    attrs = {
        "src": attr.label(mandatory = True),
        "basename": attr.string(mandatory = True),
    },
)

# The stub source a linkshared swift_binary compiles when the whole payload
# arrives through deps (the macro-expanded C ABI lives in the annotated
# library itself — there is no generated glue source).
REACTOR_STUB = Label("//swift_ffi/rules:reactor_stub.swift")
