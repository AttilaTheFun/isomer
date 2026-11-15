"""A check of an APK or AAR whose app links the NDK's shared C++ runtime
(`isomer_android_app(libcxx = "shared")`, `isomer_android_aar(libcxx =
"shared")`): check.sh run on it at build
time with the NDK's own llvm-nm and llvm-objdump, so `build_test` checks
it and nothing runs or draws."""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")

_NdkToolsInfo = provider(
    doc = "The Android cc toolchain's binary tools.",
    fields = {
        "files": "depset of File: the toolchain's files, the tools among them.",
        "nm": "string: llvm-nm's path.",
        "objdump": "string: llvm-objdump's path.",
    },
)

def _ndk_tools_impl(ctx):
    cc_toolchain = find_cc_toolchain(ctx)
    return [_NdkToolsInfo(
        files = cc_toolchain.all_files,
        nm = cc_toolchain.nm_executable,
        objdump = cc_toolchain.objdump_executable,
    )]

ndk_tools = rule(
    implementation = _ndk_tools_impl,
    toolchains = use_cc_toolchain(),
    fragments = ["cpp"],
    doc = "The cc toolchain's llvm-nm and llvm-objdump (the NDK's, built for Android).",
)

def _android_impl(_settings, _attr):
    return {"//command_line_option:platforms": [str(Label("@isomer//tools/platforms:android_arm64"))]}

# The toolchain resolved for Android, its tools for the machine running
# the check.
_android = transition(
    implementation = _android_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _libcxx_shared_check_impl(ctx):
    tools = ctx.attr._ndk_tools[0][_NdkToolsInfo]
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    # An AAR leaves libc++_shared.so to its host: the NDK's is read instead.
    aar = ctx.file.apk.extension == "aar"
    given = ctx.attr._ndk_libcxx[0][DefaultInfo].files.to_list() if aar else []
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
            "jni" if aar else "lib",
        ] + [f.path for f in given],
        inputs = depset([ctx.file.apk] + given, transitive = [tools.files]),
        tools = [ctx.executable._zipper],
        outputs = [out],
        mnemonic = "LibcxxSharedCheck",
        progress_message = "Checking %{label}'s C++ runtime",
    )
    return [DefaultInfo(files = depset([out]))]

libcxx_shared_check = rule(
    implementation = _libcxx_shared_check_impl,
    attrs = {
        "abi": attr.string(default = "arm64-v8a"),
        "apk": attr.label(allow_single_file = [".apk", ".aar"], mandatory = True, doc = "The APK, or an AAR."),
        "library": attr.string(mandatory = True, doc = "The app's library's file name in lib/<abi>/ (an AAR's jni/<abi>/)."),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
        "_check": attr.label(default = Label(":check"), executable = True, cfg = "exec"),
        "_ndk_libcxx": attr.label(default = "@isomer//swift_ffi/rules:ndk_libcxx_shared", cfg = _android),
        "_ndk_tools": attr.label(default = Label(":ndk_tools"), cfg = _android),
        "_zipper": attr.label(default = "@bazel_tools//tools/zip:zipper", executable = True, cfg = "exec"),
    },
    doc = "Checks that `apk` ships libc++_shared.so (an AAR: leaves it to its host) and that `library` needs it and holds no libc++ of its own.",
)
