"""Swift for Windows built on Linux: a repository rule that pairs a Linux host's
Swift toolchain with the Windows Swift SDK and Microsoft's SDK and MSVC
libraries, and declares the Swift and C/C++ toolchains that target
`aarch64-unknown-windows-msvc` (and x86_64) from it.

Two archives make it (tools/windows/README.md says how each is made):

- the Windows Swift SDK (`make_swift_sdk.sh`): swift.org's Windows.platform,
  the SDK the compiler builds against, and the runtime's DLLs, out of the
  Windows toolchain installer of the same release as the host's Swift;
- Microsoft's half (`make_msvc_sysroot.ps1`, then `make_msvc_sysroot.sh`):
  the Windows SDK's and MSVC's headers and import libraries in clang's
  /winsysroot layout, with the links a case-sensitive file system needs.
  Microsoft's license lets it be used, not redistributed: it's fetched
  from a builder's own server (a placeholder URL each builder's .bazelrc
  resolves, as the Apple SDK archive's is).

Swift compiles with the host's `swiftc`, `-sdk` the Windows SDK, its
`-resource-dir` the SDK's Windows modules beside the host's clang and
shims, and `-visualc-tools-root`/`-windows-sdk-root` naming Microsoft's
half. C and C++ compile with the host's `clang-cl` and link with its
`lld-link` (rules_cc's Windows toolchain configuration, as for MSVC), with
INCLUDE and LIB naming Microsoft's half.
"""

_ARCHS = {
    # Bazel's cpu → (Windows' name for it, the toolchain's cpu for rules_cc)
    "aarch64": ("arm64", "arm64_windows"),
    "x86_64": ("x64", "x64_windows"),
}

def _external_relative(path):
    path = str(path)
    if "/external/" not in path:
        fail("expected a path in an external repository: " + path)
    return "external/" + path.rsplit("/external/", 1)[1]

def _swift_windows_sdk_impl(rctx):
    rctx.download_and_extract(url = rctx.attr.swift_sdk_url, sha256 = rctx.attr.swift_sdk_sha256, type = "tar.gz")
    rctx.download_and_extract(url = rctx.attr.msvc_sysroot_url, sha256 = rctx.attr.msvc_sysroot_sha256, type = "tar.gz")
    version = rctx.read("swift-windows-sdk/VERSION").strip()
    if version != rctx.attr.swift_version:
        fail("The Windows Swift SDK is Swift {}, the host's toolchain {}: they must be one release.".format(
            version,
            rctx.attr.swift_version,
        ))
    versions = {}
    for line in rctx.read("winsysroot/VERSIONS").splitlines():
        key, _, value = line.partition("=")
        versions[key.strip()] = value.strip()

    swiftc = rctx.path(rctx.attr.swiftc)
    usr = swiftc.dirname.dirname
    toolchain_repository = str(swiftc).rsplit("/external/", 1)[1].split("/")[0]

    # The compiler's own resource directory holds Linux's modules, which
    # clash with the SDK's; this one is the SDK's Windows modules beside
    # the host's clang headers and shims.
    sdk = "swift-windows-sdk/Windows.platform/Developer/SDKs/Windows.sdk"
    for entry in rctx.path(sdk + "/usr/lib/swift").readdir():
        if entry.basename not in ("clang", "shims"):
            rctx.symlink(entry, "resource/" + entry.basename)
    rctx.symlink(usr.get_child("lib", "swift", "clang"), "resource/clang")
    rctx.symlink(usr.get_child("lib", "swift", "shims"), "resource/shims")

    # The Windows module maps (and vcruntime's API notes) in place, in the
    # Windows SDK's and MSVC's include directories, rather than in the Swift
    # SDK's usr/share: from there the Swift compiler maps them in through a
    # file-system overlay of its own, which Swift 6.4.2 can't find under a
    # relative -resource-dir ("virtual filesystem overlay file
    # '<clang-system-vfs-overlay>' not found"; swiftlang/swift#92879, in
    # 6.4.x after 6.4.2). The copts below add what mapping ucrt's implied
    # (-fbuiltin-headers-in-system-modules).
    share = sdk + "/usr/share/"
    kits = "winsysroot/Windows Kits/10/Include/" + versions["sdk"] + "/"
    msvc_include = "winsysroot/VC/Tools/MSVC/" + versions["msvc"] + "/include/"
    for name, destination in [
        ("winsdk_um.modulemap", kits + "um/module.modulemap"),
        ("winsdk_shared.modulemap", kits + "shared/module.modulemap"),
        ("ucrt.modulemap", kits + "ucrt/module.modulemap"),
        ("vcruntime.modulemap", msvc_include + "module.modulemap"),
        ("vcruntime.apinotes", msvc_include + "vcruntime.apinotes"),
    ]:
        if rctx.path(share + name).exists:
            rctx.file(destination, rctx.read(share + name), executable = False)
            rctx.delete(share + name)
    # Headers the vcruntime module map names that an older MSVC lacks (the
    # compiler would inject them empty, through the same overlay).
    for header in ["__msvc_bit_utils.hpp", "__msvc_string_view.hpp"]:
        if not rctx.path(msvc_include + header).exists:
            rctx.file(msvc_include + header, "", executable = False)

    # The host's LLVM tools as MSVC's: clang-cl, lld-link, and llvm-ar as
    # llvm-lib (it takes lib.exe's command line under that name).
    for tool, name in [("clang-cl", "clang-cl"), ("lld-link", "lld-link"), ("llvm-ar", "llvm-lib")]:
        rctx.symlink(usr.get_child("bin", tool), "bin/" + name)

    root = "external/" + rctx.name
    rctx.template("BUILD.bazel", rctx.attr._build_template, substitutions = {
        "{execroot_repo}": root,
        "{msvc}": versions["msvc"],
        "{sdk_version}": versions["sdk"],
        "{swift_version}": rctx.attr.swift_version,
        "{toolchain_repo}": rctx.attr.swift_toolchain_repo,
        "{toolchain_root}": _external_relative(usr.dirname),
        "{exec_cpu}": "aarch64" if "aarch64" in toolchain_repository else "x86_64",
    })
    rctx.file(".swift-version", rctx.attr.swift_version)

swift_windows_sdk_repository = repository_rule(
    implementation = _swift_windows_sdk_impl,
    attrs = {
        "msvc_sysroot_sha256": attr.string(mandatory = True),
        "msvc_sysroot_url": attr.string(
            mandatory = True,
            doc = "Microsoft's half (make_msvc_sysroot.sh's archive), usually a placeholder a builder resolves.",
        ),
        "swift_sdk_sha256": attr.string(mandatory = True),
        "swift_sdk_url": attr.string(mandatory = True, doc = "make_swift_sdk.sh's archive."),
        "swift_toolchain_repo": attr.string(
            mandatory = True,
            doc = "The apparent name of the host's standalone Swift toolchain repository, as the module using this rule sees it.",
        ),
        "swift_version": attr.string(mandatory = True),
        "swiftc": attr.label(
            mandatory = True,
            doc = "That toolchain's swiftc (`@<it>//:usr/bin/swiftc`): its tools and clang come from beside it.",
        ),
        "_build_template": attr.label(default = "//tools/windows:swift_windows_sdk.BUILD"),
    },
)
