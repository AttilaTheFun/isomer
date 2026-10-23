"""The compiler a Playground carries as files: swift-frontend and wasm-ld,
with what they load, beside the wasm Swift SDK's WASI sysroot and static
standard library, as one directory (playground_toolchain/) the app ships
with (the Mac's Resources; beside the Linux and Windows apps). The app runs
them as processes (BundledCompiler.swift); the iPhone links the same
compiler into the app (build_embedded_toolchain.sh), and every one passes
the same arguments (CompilerArguments.swift).

Everything comes from the toolchains rules_swift registered for wasm32,
resolved for the platform the app is built on: the Swift toolchain's files
(the host compiler, its libraries and macro plugins, the wasm SDK bundle)
and the C toolchain's (lld). Nothing is staged by hand. On a Mac the Mach-O
files are thinned to arm64 (lipo), about half their universal size; each
slice keeps its own signature.

    playground_toolchain/usr/bin/{swift-frontend,wasm-ld}
    playground_toolchain/usr/lib/swift/host/compiler/lib_CompilerSwift*   (what the frontend links)
    playground_toolchain/usr/lib/swift/host/libSwift*                     (the macro plugin server and SwiftSyntax)
    playground_toolchain/usr/lib/swift/host/plugins/*                     (ObservationMacros, SwiftMacros)
    playground_toolchain/data/{WASI.sdk,swift_static}
"""

_SWIFT_TOOLCHAIN_TYPE = "@rules_swift//toolchains:toolchain_type"
_CC_TOOLCHAIN_TYPE = "@bazel_tools//tools/cpp:toolchain_type"

def _wasm_platform_impl(_settings, _attr):
    return {"//command_line_option:platforms": [str(Label("@isomer//swift_ffi/rules:wasm32-wasip1"))]}

_wasm_platform = transition(
    implementation = _wasm_platform_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _wasm_swift_sdk_files_impl(ctx):
    # The wasm Swift toolchain's own inputs: the SDK bundle (its sysroot and
    # static resources) and the host compiler. The bundle's filegroup is
    # private to its repository; toolchain resolution reaches it.
    toolchain = ctx.toolchains[_SWIFT_TOOLCHAIN_TYPE].swift_toolchain
    files = []
    for config in toolchain.tool_configs.values():
        for tool in config.additional_tools:
            if type(tool) == "File":
                files.append(tool)

    # The C toolchain's: the linker (lld) the Swift toolchain links with.
    cc = ctx.toolchains[_CC_TOOLCHAIN_TYPE].cc
    return [DefaultInfo(files = depset(files, transitive = [cc.all_files]))]

wasm_swift_sdk_files = rule(
    implementation = _wasm_swift_sdk_files_impl,
    cfg = _wasm_platform,
    toolchains = [_SWIFT_TOOLCHAIN_TYPE, _CC_TOOLCHAIN_TYPE],
    doc = "The files of the Swift and C toolchains resolved for wasm32-wasip1 (the host compiler, lld and the wasm SDK bundle among them).",
)

_LIBRARY_SUFFIXES = (".dylib", ".so")

def _is_library(name):
    for suffix in _LIBRARY_SUFFIXES:
        if name.endswith(suffix):
            return True
    return False

def _destination(path):
    """Where a toolchain file goes under playground_toolchain/, or None."""
    for tool in ("swift-frontend", "wasm-ld"):
        if path.endswith("/usr/bin/" + tool):
            return "usr/bin/" + tool
    if path.endswith("/usr/bin/lld"):
        # lld takes its flavour from its name: as wasm-ld it links WebAssembly.
        return "usr/bin/wasm-ld"
    marker = "/usr/lib/swift/host/"
    if marker in path:
        rest = path.split(marker, 1)[1]
        if rest.startswith("compiler/lib_CompilerSwift") and _is_library(rest):
            return "usr/lib/swift/host/" + rest
        if rest.startswith("plugins/") and _is_library(rest) and rest.count("/") == 1:
            # The macros a project's code reaches: @Observable, and the
            # standard library's (#Preview aside, @TaskLocal, @DebugDescription).
            name = rest.split("/")[1]
            if name.startswith("libObservationMacros.") or name.startswith("libSwiftMacros."):
                return "usr/lib/swift/host/" + rest
            return None
        if rest.startswith("libSwift") and _is_library(rest) and "/" not in rest:
            return "usr/lib/swift/host/" + rest
        return None
    if "/wasm32-unknown-wasip1/" in path:
        for marker, name in (("/wasm32-unknown-wasip1/WASI.sdk/", "WASI.sdk"), ("/usr/lib/swift_static/", "swift_static")):
            if marker in path:
                return "data/%s/%s" % (name, path.split(marker, 1)[1])
    return None

def _playground_toolchain_impl(ctx):
    out = ctx.actions.declare_directory(ctx.attr.name)
    files = []
    lines = []
    seen = {}
    for f in ctx.files.files:
        destination = _destination(f.path)
        if destination and destination not in seen:
            seen[destination] = True
            files.append(f)
            lines.append("%s\t%s" % (f.path, destination))
    manifest = ctx.actions.declare_file(ctx.attr.name + ".manifest")
    ctx.actions.write(manifest, "\n".join(lines) + "\n")
    ctx.actions.run_shell(
        inputs = files + [manifest],
        outputs = [out],
        arguments = [manifest.path, out.path + "/playground_toolchain", "1" if ctx.attr.thin_arm64 else "0"],
        command = """
set -euo pipefail
manifest="$1"; root="$2"; thin="$3"
while IFS=$'\\t' read -r source destination; do
  target="$root/$destination"
  mkdir -p "$(dirname "$target")"
  if [ "$thin" = 1 ] && /usr/bin/lipo -archs "$source" 2>/dev/null | grep -q arm64 && \\
     [ "$(/usr/bin/lipo -archs "$source")" != arm64 ]; then
    /usr/bin/lipo -thin arm64 -output "$target" "$source"
  else
    cp -L "$source" "$target"
  fi
done < "$manifest"
for tool in swift-frontend wasm-ld; do
  [ -f "$root/usr/bin/$tool" ] || { echo "playground_toolchain: no $tool among the inputs" >&2; exit 1; }
  chmod +x "$root/usr/bin/$tool"
done
[ -d "$root/data/WASI.sdk" ] && [ -d "$root/data/swift_static" ] || { echo "playground_toolchain: no wasm SDK among the inputs" >&2; exit 1; }
""",
        mnemonic = "PlaygroundToolchain",
        progress_message = "Assembling the Playground's compiler",
        # About 2 GB of toolchain in, not worth a remote cache's round trip.
        execution_requirements = {"no-remote": "1"},
    )
    return [DefaultInfo(files = depset([out]))]

playground_toolchain = rule(
    implementation = _playground_toolchain_impl,
    attrs = {
        "files": attr.label_list(allow_files = True, doc = "The toolchains' files (wasm_swift_sdk_files)."),
        "thin_arm64": attr.bool(doc = "Thin universal Mach-O files to arm64 (lipo; a Mac's)."),
    },
    doc = "The Playground's compiler as one directory the app ships with.",
)
