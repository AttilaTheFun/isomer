"""A program built out of band against a wasm_sdk_bundle, as the Playground
builds a project: swift-frontend compiles the sources against the bundle's
modules and C modules alone, and wasm-ld links the object with the bundle's
archives (whole-archive) and the Swift SDK's standard library. Nothing of
Bazel's Swift rules takes part, and nothing of the SDK's Foundation is
linked but what the bundle carries: a module or archive missing from it is
a compile or link error here.

The Playground links a reactor (crt1-reactor.o, its hosts' entries
exported); this links a WASI command (crt1-command.o), so a test can run it.
"""

def _wasm_platform_transition_impl(_settings, attr):
    return {"//command_line_option:platforms": [attr.platform]}

_wasm_platform_transition = transition(
    implementation = _wasm_platform_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

_SWIFT_STATIC = "/swift.xctoolchain/usr/lib/swift_static/"

def _find(files, triple):
    """swift-frontend, the linker, the WASI sysroot and the static resource
    directory among the wasm toolchains' files."""
    frontend = None
    wasm_ld = None
    lld = None
    wasi_sdk = None
    swift_static = None
    for f in files:
        path = f.path
        if path.endswith("/usr/bin/swift-frontend"):
            frontend = f
        elif path.endswith("/usr/bin/wasm-ld"):
            wasm_ld = f
        elif path.endswith("/usr/bin/lld"):
            lld = f
        elif not wasi_sdk and ("/%s/WASI.sdk/" % triple) in path:
            wasi_sdk = path.split("/%s/WASI.sdk/" % triple, 1)[0] + "/%s/WASI.sdk" % triple
        elif not swift_static and ("/%s%s" % (triple, _SWIFT_STATIC)) in path:
            swift_static = path.split(_SWIFT_STATIC, 1)[0] + _SWIFT_STATIC.rstrip("/")
    linker = wasm_ld or lld
    if not (frontend and linker and wasi_sdk and swift_static):
        fail("sdk_bundle_program: the wasm toolchains have no %s" % ", ".join([
            name
            for name, found in [("swift-frontend", frontend), ("wasm-ld", linker), ("WASI.sdk", wasi_sdk), ("swift_static", swift_static)]
            if not found
        ]))
    return struct(
        frontend = frontend,
        linker = linker,
        # lld takes its flavour from its name, or from -flavor.
        flavor = [] if wasm_ld else ["-flavor", "wasm"],
        wasi_sdk = wasi_sdk,
        swift_static = swift_static,
    )

def _sdk_bundle_program_impl(ctx):
    triple = "wasm32-unknown-wasip1"
    tools = _find(ctx.files._toolchain_files, triple)
    bundle = ctx.file.bundle
    out = ctx.actions.declare_file(ctx.label.name + ".wasm")
    ctx.actions.run_shell(
        inputs = depset(
            [bundle] + ctx.files.srcs,
            transitive = [ctx.attr._toolchain_files[0][DefaultInfo].files],
        ),
        outputs = [out],
        arguments = [
            bundle.path,
            tools.frontend.path,
            tools.linker.path,
            " ".join(tools.flavor),
            tools.wasi_sdk,
            tools.swift_static,
            triple,
            out.path,
            " ".join(ctx.attr.expected_modules),
        ] + [f.path for f in ctx.files.srcs],
        command = """
set -euo pipefail
bundle="$1"; frontend="$2"; linker="$3"; flavor="$4"; wasi="$5"; static="$6"; triple="$7"; out="$8"; expected="$9"
shift 9
# Absolute paths, as the apps pass them (the frontend resolves its Clang
# overlays against a relative resource directory and finds none).
here="$PWD"
absolute() { case "$1" in /*) echo "$1" ;; *) echo "$here/$1" ;; esac; }
bundle="$(absolute "$bundle")"; frontend="$(absolute "$frontend")"; linker="$(absolute "$linker")"
wasi="$(absolute "$wasi")"; static="$(absolute "$static")"; out="$(absolute "$out")"
sources=()
for source in "$@"; do sources+=("$(absolute "$source")"); done
# The modules the bundle must list (its manifest, as the apps read it).
for name in $expected; do
  grep -q "\\"name\\": \\"$name\\"" "$bundle/manifest.json" ||
    { echo "sdk_bundle_program: the bundle's manifest lists no module $name" >&2; exit 1; }
done
# The C modules: each one's map and include directory, as the manifest names
# them (include/<Name>; include/ for the SDK's, whose headers include each
# other by their directory's name, and some of which, ICU's uchar.h and
# platform.h, would shadow the C library's from a directory of their own).
clang=()
while read -r key value; do
  case "$key" in
    modulemap) clang+=(-Xcc "-fmodule-map-file=$bundle/$value") ;;
    include) clang+=(-Xcc -I -Xcc "$bundle/$value") ;;
  esac
done < <(sed -n -e 's/^ *"modulemap": "\\([^"]*\\)".*/modulemap \\1/p' -e 's/^ *"include": "\\([^"]*\\)".*/include \\1/p' "$bundle/manifest.json")
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# CompilerArguments.frontend's, as the Playground's compilers run it.
"$frontend" -frontend -c "${sources[@]}" \\
  -target "$triple" -disable-objc-interop \\
  -sdk "$wasi" -I "$bundle/modules" "${clang[@]}" \\
  -static -swift-version 5 -Onone -empty-abi-descriptor \\
  -resource-dir "$static" -use-static-resource-dir \\
  -Xcc "--target=$triple" -module-cache-path "$work/cache" \\
  -module-name SDKBundleProgram -parse-as-library -o "$work/program.o"
# CompilerArguments.link's, a command's start file in place of the reactor's.
archives=()
while read -r archive; do archives+=("$bundle/lib/$archive"); done < <(ls "$bundle/lib" | sort -n)
"$linker" $flavor -m wasm32 \\
  -L"$static/wasi" -L"$wasi/lib/wasm32-wasip1" \\
  "$wasi/lib/wasm32-wasip1/crt1-command.o" \\
  "$work/program.o" \\
  --whole-archive "${archives[@]}" --no-whole-archive \\
  --gc-sections \\
  -z stack-size=16777216 \\
  "$static/wasi/wasm32/swiftrt.o" \\
  -lswiftCore -lswiftSwiftOnoneSupport -lswiftWASILibc \\
  -lswift_Concurrency -lswift_RegexParser -lswift_StringProcessing \\
  -lswiftObservation -lswiftSynchronization \\
  -lc++ -lc++abi -ldl -lm \\
  -lwasi-emulated-mman -lwasi-emulated-signal -lwasi-emulated-process-clocks -lwasi-emulated-getpid \\
  --global-base=4096 --table-base=4096 \\
  -lc \\
  "$static/clang/lib/wasip1/libclang_rt.builtins-wasm32.a" \\
  -o "$out"
""",
        mnemonic = "SDKBundleProgram",
        progress_message = "Compiling and linking %s against its SDK bundle" % ctx.label,
    )
    return [DefaultInfo(files = depset([out]))]

sdk_bundle_program = rule(
    implementation = _sdk_bundle_program_impl,
    attrs = {
        "bundle": attr.label(allow_single_file = True, mandatory = True, doc = "A wasm_sdk_bundle."),
        "srcs": attr.label_list(allow_files = [".swift"], mandatory = True),
        "expected_modules": attr.string_list(doc = "Modules the bundle's manifest must list."),
        "platform": attr.label(mandatory = True, doc = "The bundle's platform: the wasm toolchains are resolved for it."),
        "_toolchain_files": attr.label(
            default = Label("//tools/wasm:wasm_toolchain_files"),
            cfg = _wasm_platform_transition,
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "A WASI command compiled and linked out of band against a wasm_sdk_bundle (the Playground's way).",
)
