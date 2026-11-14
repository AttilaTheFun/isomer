"""The C++ runtime an Android JNI library links (`--//swift_ffi/rules:libcxx`).

The NDK's cc toolchains (rules_android_ndk's, through
hermetic_android_toolchains' @androidndk) link the C++ runtime statically:
their `static_link_cpp_runtimes` feature, on by default, adds
`libc++_static.a` and `libc++abi.a` (the toolchain's `static_runtime_lib`)
to every link, and their `dynamic_runtime_lib` is empty. rules_swift's
Android toolchain links a `swift_binary` through them, so a JNI library
holds its own libc++, which the Swift runtime's archives (C++ themselves)
and Swift's C++ interoperability (`-lc++`, resolved by rules_swift to the
static pair) use too.

With `libcxx=shared` kt_swift_library and kt_swift_platform turn that
feature off for their links and put the NDK's `libc++_shared.so` on the
command line ahead of everything that refers to it (the user link flags
come before the toolchain's own, `-lc++` among them, and lld takes a symbol
from the first library defining it): the library needs `libc++_shared.so`
(DT_NEEDED) and defines none of it. The app then ships that
`libc++_shared.so` (isomer_android_app does, through `:cxx_runtime`), and
any other library in the process sharing C++ objects with it (a prebuilt
library built with the same NDK and `c++_shared`) uses the same runtime.
"""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")

def _ndk_libcxx_shared_impl(ctx):
    cc_toolchain = find_cc_toolchain(ctx)
    triple = cc_toolchain.target_gnu_system_name
    if "android" not in triple:
        # Not an Android build (a wildcard build of the package, say):
        # nothing, rather than a failure for a library nobody asked for.
        return [DefaultInfo()]

    # The NDK's sysroot keeps one per target, beside the static runtime the
    # toolchain links by default: sysroot/usr/lib/<triple>/libc++_shared.so.
    suffix = "/usr/lib/%s/libc++_shared.so" % triple
    found = [f for f in cc_toolchain.all_files.to_list() if f.path.endswith(suffix)]
    if not found:
        fail("The Android cc toolchain for %s has no libc++_shared.so among its files (looked for *%s)." % (triple, suffix))
    return [DefaultInfo(files = depset(found[:1]))]

ndk_libcxx_shared = rule(
    implementation = _ndk_libcxx_shared_impl,
    toolchains = use_cc_toolchain(),
    fragments = ["cpp"],
    doc = "The NDK's `libc++_shared.so` for the target the Android cc toolchain links for (nothing off Android).",
)
