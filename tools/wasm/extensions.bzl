"""Hermetic Electron for the desktop wrapper around the wasm application."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

def _electron_repository_impl(rctx):
    rctx.download_and_extract(
        url = rctx.attr.url,
        sha256 = rctx.attr.sha256,
    )

    # Electron.app contains paths with spaces ("Electron Framework.framework")
    # which Bazel labels cannot express, so the bundle is not exposed as
    # files; the launcher is invoked via this recorded absolute path instead.
    rctx.file(
        "electron_path.txt",
        str(rctx.path("Electron.app/Contents/MacOS/Electron")) + "\n",
    )
    rctx.file("BUILD.bazel", """\
package(default_visibility = ["//visibility:public"])

exports_files(["electron_path.txt"])
""")

electron_repository = repository_rule(
    implementation = _electron_repository_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "sha256": attr.string(mandatory = True),
    },
)

_ELECTRON_WIN_BUILD = """\
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "all",
    srcs = glob(["**"]),
)
"""

def _wasm_tools_impl(_mctx):
    electron_repository(
        name = "electron",
        url = "https://github.com/electron/electron/releases/download/v42.4.0/electron-v42.4.0-darwin-arm64.zip",
        sha256 = "3ce55988c9998bcd1e9c69478dd26887b90e8f8010441172e520e94ba575e520",
    )

    # Windows runtime for the USB-copyable package (Windows file paths have
    # no spaces in this distribution, so plain globbing works).
    http_archive(
        name = "electron_win64",
        url = "https://github.com/electron/electron/releases/download/v42.4.0/electron-v42.4.0-win32-x64.zip",
        sha256 = "ffc056685b4a769d7977ef3d58bdc332446d081f025ee074d77b498d2962e2cd",
        build_file_content = _ELECTRON_WIN_BUILD,
    )

wasm_tools = module_extension(implementation = _wasm_tools_impl)
