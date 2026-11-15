"""A prebuilt Swift library's artifacts, and the checks of the apps that
take them (docs/prebuilt_swift_libraries.md in isomer).

`swift_library_artifacts` is what a library's author ships: the static
archive, the `.swiftinterface` and the `.swiftmodule` of a `swift_library`
built with `library_evolution`, under the names a release of it would carry
(`lib<Module>.a`, `<Module>.swiftinterface`, `<Module>.swiftmodule`). The
app's `swift_import` takes those files, not the library's target, as it
would take them from an archive downloaded beside its build: the
`.swiftmodule`, since rules_swift 4.2.2 compiles a `.swiftinterface` for
Android without the Swift SDK (no `-sdk`, no resource directory: "no such
module 'Swift'"; docs/prebuilt_swift_libraries.md).

`prebuilt_library_check` runs check.sh on an app's APK at build time with
the NDK's own llvm-nm and llvm-objdump (android_libcxx_shared's
`ndk_tools`), so `build_test` checks it and nothing runs or draws."""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_swift//swift:providers.bzl", "SwiftInfo")
load("//tests/android_libcxx_shared:check.bzl", "NdkToolsInfo")

def _swift_library_artifacts_impl(ctx):
    library = ctx.attr.library
    modules = library[SwiftInfo].direct_modules
    if len(modules) != 1 or not modules[0].swift:
        fail("%s is not one Swift module" % library.label)
    module = modules[0]
    interface = module.swift.swiftinterface
    if not interface:
        fail("%s has no .swiftinterface: build it with `library_evolution = True`" % library.label)

    # The library's own archive: the linker input it owns (its deps'
    # archives are theirs, never shipped with it).
    archives = [
        library_to_link.pic_static_library or library_to_link.static_library
        for linker_input in library[CcInfo].linking_context.linker_inputs.to_list()
        if linker_input.owner == library.label
        for library_to_link in linker_input.libraries
        if library_to_link.pic_static_library or library_to_link.static_library
    ]
    if len(archives) != 1:
        fail("%s links %d archives of its own, not one" % (library.label, len(archives)))
    archive = ctx.actions.declare_file("%s/lib%s.a" % (ctx.label.name, module.name))
    ctx.actions.symlink(output = archive, target_file = archives[0])
    swiftinterface = ctx.actions.declare_file("%s/%s.swiftinterface" % (ctx.label.name, module.name))
    ctx.actions.symlink(output = swiftinterface, target_file = interface)
    swiftmodule = ctx.actions.declare_file("%s/%s.swiftmodule" % (ctx.label.name, module.name))
    ctx.actions.symlink(output = swiftmodule, target_file = module.swift.swiftmodule)
    return [
        DefaultInfo(files = depset([archive, swiftinterface, swiftmodule])),
        OutputGroupInfo(
            archive = depset([archive]),
            swiftinterface = depset([swiftinterface]),
            swiftmodule = depset([swiftmodule]),
        ),
    ]

swift_library_artifacts = rule(
    implementation = _swift_library_artifacts_impl,
    attrs = {
        "library": attr.label(mandatory = True, providers = [SwiftInfo, CcInfo]),
    },
    doc = "A library-evolution `swift_library`'s static archive, .swiftinterface and .swiftmodule, as shipped (output groups `archive`, `swiftinterface`, `swiftmodule`).",
)

def _android_impl(_settings, _attr):
    return {"//command_line_option:platforms": [str(Label("@isomer//swift_ffi/rules:android-aarch64"))]}

# The archives read in the configuration the app's library links them in
# (swift_ffi's transition_binary sets this platform), so they are the same
# files; the NDK's tools resolved for Android, built for the machine running
# the check.
_android = transition(
    implementation = _android_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _prebuilt_library_check_impl(ctx):
    tools = ctx.attr._ndk_tools[0][NdkToolsInfo]
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    if bool(ctx.files.archives) == bool(ctx.attr.shared_library):
        fail("give `archives` (route b) or `shared_library` (route a), not both")
    route = ["archive"] + [f.path for f in ctx.files.archives] if ctx.files.archives else ["shared", ctx.attr.shared_library]
    ctx.actions.run(
        executable = ctx.executable._check,
        arguments = [
            tools.nm,
            tools.objdump,
            ctx.executable._zipper.path,
            ctx.file.apk.path,
            ctx.attr.abi,
            ctx.attr.library,
            out.path,
            ",".join(ctx.attr.modules),
        ] + route,
        inputs = depset([ctx.file.apk] + ctx.files.archives, transitive = [tools.files]),
        tools = [ctx.executable._zipper],
        outputs = [out],
        mnemonic = "PrebuiltSwiftLibraryCheck",
        progress_message = "Checking %{label}'s prebuilt Swift library",
    )
    return [DefaultInfo(files = depset([out]))]

prebuilt_library_check = rule(
    implementation = _prebuilt_library_check_impl,
    attrs = {
        "abi": attr.string(default = "arm64-v8a"),
        "apk": attr.label(allow_single_file = [".apk"], mandatory = True),
        "archives": attr.label_list(
            allow_files = [".a"],
            cfg = _android,
            doc = "Route (b): the prebuilt static archives linked into `library`.",
        ),
        "library": attr.string(mandatory = True, doc = "The app's library's file name in lib/<abi>/."),
        "modules": attr.string_list(mandatory = True, doc = "The prebuilt library's Swift modules, whose symbols the checks look for."),
        "shared_library": attr.string(doc = "Route (a): the prebuilt shared library's file name in lib/<abi>/."),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
        "_check": attr.label(default = Label(":check"), executable = True, cfg = "exec"),
        "_ndk_tools": attr.label(default = Label(":ndk_tools"), cfg = _android),
        "_zipper": attr.label(default = "@bazel_tools//tools/zip:zipper", executable = True, cfg = "exec"),
    },
    doc = "Checks that an app's APK links a prebuilt Swift library as route (a) or (b) has it (check.sh).",
)
