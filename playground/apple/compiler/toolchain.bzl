"""The Mac Playground's compiler: the swift.org toolchain's swift-frontend and
wasm-ld, with what they load, beside the wasm Swift SDK's WASI sysroot and
static standard library, as one directory the app carries in its Resources
(playground_toolchain/). The Mac runs them as processes; the iPhone links
the same compiler into the app (build_embedded_toolchain.sh), and both pass
the same arguments (CompilerArguments.swift).

Everything comes from the repositories rules_swift already fetched (the
host toolchain and the wasm SDK bundle): nothing is staged by hand. The
Mach-O files are thinned to arm64 (lipo), about half their universal size;
each slice keeps its own signature.

    playground_toolchain/usr/bin/{swift-frontend,wasm-ld}
    playground_toolchain/usr/lib/swift/host/compiler/lib_CompilerSwift*.dylib
    playground_toolchain/usr/lib/swift/host/libSwift*.dylib   (the macro plugin server and SwiftSyntax)
    playground_toolchain/usr/lib/swift/host/plugins/*.dylib   (ObservationMacros, SwiftMacros)
    playground_toolchain/data/{WASI.sdk,swift_static}
"""

_SWIFT_TOOLCHAIN_TYPE = "@rules_swift//toolchains:toolchain_type"

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
    return [DefaultInfo(files = depset(files))]

wasm_swift_sdk_files = rule(
    implementation = _wasm_swift_sdk_files_impl,
    cfg = _wasm_platform,
    toolchains = [_SWIFT_TOOLCHAIN_TYPE],
    doc = "The files of the Swift toolchain resolved for wasm32-wasip1 (the wasm SDK bundle among them).",
)

def _destination(path):
    """Where a toolchain file goes under playground_toolchain/, or None."""
    if path.endswith("/usr/bin/swift-frontend"):
        return "usr/bin/swift-frontend"
    if path.endswith("/usr/bin/lld"):
        # lld takes its flavour from its name: wasm-ld links WebAssembly.
        return "usr/bin/wasm-ld"
    marker = "/usr/lib/swift/host/"
    if marker in path:
        rest = path.split(marker, 1)[1]
        if rest.startswith("compiler/lib_CompilerSwift") and rest.endswith(".dylib"):
            return "usr/lib/swift/host/" + rest
        if rest.startswith("plugins/") and rest.endswith(".dylib") and rest.count("/") == 1:
            return "usr/lib/swift/host/" + rest
        if rest.startswith("libSwift") and rest.endswith(".dylib") and "/" not in rest:
            return "usr/lib/swift/host/" + rest
        return None
    for marker, name in (("/wasm32-unknown-wasip1/WASI.sdk/", "WASI.sdk"), ("/usr/lib/swift_static/", "swift_static")):
        if marker in path and "/wasm32-unknown-wasip1/" in path:
            return "data/%s/%s" % (name, path.split(marker, 1)[1])
    return None

def _macos_playground_toolchain_impl(ctx):
    out = ctx.actions.declare_directory(ctx.attr.name)
    files = []
    lines = []
    for f in ctx.files.toolchain + ctx.files.wasm_sdk:
        destination = _destination(f.path)
        if destination:
            files.append(f)
            lines.append("%s\t%s" % (f.path, destination))
    manifest = ctx.actions.declare_file(ctx.attr.name + ".manifest")
    ctx.actions.write(manifest, "\n".join(lines) + "\n")
    ctx.actions.run_shell(
        inputs = files + [manifest],
        outputs = [out],
        arguments = [manifest.path, out.path + "/playground_toolchain"],
        command = """
set -euo pipefail
manifest="$1"; root="$2"
while IFS=$'\\t' read -r source destination; do
  target="$root/$destination"
  mkdir -p "$(dirname "$target")"
  if /usr/bin/lipo -archs "$source" 2>/dev/null | grep -q arm64 && \\
     [ "$(/usr/bin/lipo -archs "$source")" != arm64 ]; then
    /usr/bin/lipo -thin arm64 -output "$target" "$source"
  else
    cp -L "$source" "$target"
  fi
done < "$manifest"
for tool in swift-frontend wasm-ld; do
  [ -f "$root/usr/bin/$tool" ] || { echo "macos_playground_toolchain: no $tool among the inputs" >&2; exit 1; }
done
[ -d "$root/data/WASI.sdk" ] && [ -d "$root/data/swift_static" ] || { echo "macos_playground_toolchain: no wasm SDK among the inputs" >&2; exit 1; }
chmod +x "$root/usr/bin/swift-frontend" "$root/usr/bin/wasm-ld"
""",
        mnemonic = "PlaygroundToolchain",
        progress_message = "Assembling the Mac Playground's toolchain",
        # lipo is Xcode's; the inputs are ~2 GB of toolchain, not worth a
        # remote cache's round trip.
        execution_requirements = {"no-remote": "1"},
    )
    return [DefaultInfo(files = depset([out]))]

macos_playground_toolchain = rule(
    implementation = _macos_playground_toolchain_impl,
    attrs = {
        "toolchain": attr.label_list(allow_files = True, doc = "The swift.org macOS toolchain's files (swift-frontend, lld, host libraries)."),
        "wasm_sdk": attr.label_list(allow_files = True, doc = "The wasm Swift SDK bundle's files."),
    },
    doc = "The Mac Playground's compiler as one directory for the app's Resources.",
)
