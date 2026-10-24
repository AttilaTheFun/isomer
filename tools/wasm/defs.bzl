"""Rules for assembling, serving, and wrapping the static wasm application."""

load("@bazel_skylib//rules:copy_file.bzl", "copy_file")
load("@rules_cc//cc:defs.bzl", "cc_library")
load("//swift_ffi/rules:swift_wasm_reactor.bzl", "HOST_ENTRIES")
load("//swift_ffi/rules:ts_swift_wasm_library.bzl", "ts_swift_wasm_library")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_python//python:defs.bzl", "py_binary", "py_test")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("@rules_swift//swift:providers.bzl", "SwiftInfo")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

def _static_site_impl(ctx):
    out = ctx.actions.declare_directory(ctx.label.name)

    commands = ["mkdir -p {out}/runtime {out}/assets".format(out = out.path)]
    commands.append("cp {src} {out}/index.html".format(src = ctx.file.index.path, out = out.path))
    commands.append("cp {src} {out}/app.wasm".format(src = ctx.file.wasm.path, out = out.path))
    for page in ctx.files.extra_pages:
        commands.append("cp {src} {out}/{name}".format(
            src = page.path,
            out = out.path,
            name = page.basename,
        ))
    for js in ctx.files.runtime_js:
        commands.append("cp {src} {out}/runtime/{name}".format(
            src = js.path,
            out = out.path,
            name = js.basename,
        ))
    for js in ctx.files.root_js:
        commands.append("cp {src} {out}/{name}".format(
            src = js.path,
            out = out.path,
            name = js.basename,
        ))
    for asset in ctx.files.assets:
        commands.append("cp {src} {out}/assets/{name}".format(
            src = asset.path,
            out = out.path,
            name = asset.basename,
        ))

    # Verify every relative ES-module import in the served JS resolves to a
    # file in the site. A broken module graph evaluates NOTHING at runtime —
    # the page renders as a silent blank — so turn the miss into a build
    # error naming the file. (Import specifiers are static strings here; a
    # simple grep is faithful.)
    commands.append(r"""
cd {out} && for js in *.js runtime/*.js; do
  [ -f "$js" ] || continue
  dir=$(dirname "$js")
  grep -oE "(from|import)[[:space:]]+['\"](\./|\.\./)[^'\"]+['\"]" "$js" 2>/dev/null \
    | grep -oE "['\"][^'\"]+['\"]" | tr -d "'\"" | while read -r spec; do
      target="$dir/$spec"
      norm=$(cd "$(dirname "$target")" 2>/dev/null && pwd)/$(basename "$target")
      rel=${{norm#"$(pwd)"/}}
      if [ ! -f "$rel" ]; then
        echo "static_site: $js imports '$spec' but the site has no such file" >&2
        exit 1
      fi
    done || exit 1
done""".format(out = out.path))

    # Cache stamping: a static host (GitHub Pages) serves with a short
    # max-age and no service worker, so a returning browser ran the OLD
    # runtime modules (bare relative imports) for minutes after a publish and
    # a Home Screen app until relaunched. Every relative module import,
    # worker and wasm reference gets `?v=<content hash of the site>`, so a
    # new publish is fetched on the next load; the file names stay.
    # (The shell is already inside the site directory from the check above.)
    commands.append(r"""V=$(cat index.html *.js runtime/*.js *.wasm | cksum | cut -d' ' -f1) && [ -n "$V" ] && \
perl -pi -e 's/((?:from|import)\s*\(?\s*["\x27])(\.{1,2}\/[^"\x27?]+?\.js)(["\x27])/$1$2?v='"$V"'$3/g; s/(new\s+Worker\s*\(\s*["\x27])(\.\/[^"\x27?]+?\.js)(["\x27])/$1$2?v='"$V"'$3/g; s/(["\x27])(\.\/[^"\x27?]+?\.wasm)(["\x27])/$1$2?v='"$V"'$3/g' index.html *.js runtime/*.js && \
perl -pi -e 's/(<script[^>]*\ssrc=")(\.\/[^"?]+?\.js)(")/$1$2?v='"$V"'$3/g' index.html
""")

    ctx.actions.run_shell(
        inputs = [ctx.file.index, ctx.file.wasm] + ctx.files.extra_pages + ctx.files.runtime_js + ctx.files.root_js + ctx.files.assets,
        outputs = [out],
        command = " && ".join(commands),
        mnemonic = "AssembleStaticSite",
        progress_message = "Assembling static site %s" % ctx.label,
    )
    return [DefaultInfo(files = depset([out]))]

static_site = rule(
    implementation = _static_site_impl,
    attrs = {
        "index": attr.label(allow_single_file = [".html"], mandatory = True),
        "wasm": attr.label(allow_single_file = [".wasm"], mandatory = True),
        # Extra root-level pages and scripts (a page's workers / ES modules).
        # Pages and scripts at the site's root, and reactors the page runs
        # beside its own (the Isomer app's gallery.wasm).
        "extra_pages": attr.label_list(allow_files = [".html", ".js", ".wasm"]),
        "runtime_js": attr.label_list(allow_files = [".js"]),
        "root_js": attr.label_list(allow_files = [".js"]),
        "assets": attr.label_list(allow_files = True),
    },
    doc = "Assembles index.html + app.wasm + JS runtime + assets into one directory.",
)

def web_server(name, site, port = "8080", query = "", **kwargs):
    """`bazel run`-able dev server for a static_site target.

    Serves on localhost and opens the default browser (append `-- --no-open`
    to suppress). `query` is appended to the opened URL (e.g.
    "renderer=react" selects the layered renderer binding).
    """
    py_binary(
        name = name,
        srcs = [Label("//tools/wasm:serve.py")],
        main = Label("//tools/wasm:serve.py"),
        args = ["$(rootpath %s)" % site, port, query],
        data = [site],
        **kwargs
    )

def _windows_electron_package_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".zip")

    # The win64 repo root is two levels above any file in it (e.g.
    # resources/default_app.asar); locate it from the first file.
    electron_files = ctx.attr._electron_win.files.to_list()
    electron_root = None
    for f in electron_files:
        if f.basename == "electron.exe":
            electron_root = f.dirname
            break
    if electron_root == None:
        fail("electron.exe not found in @electron_win64")

    site = ctx.attr.site.files.to_list()[0]

    command = """
set -euo pipefail
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/{app_name}"
cp -R {electron_root}/. "$STAGE/{app_name}/"
chmod -R u+w "$STAGE/{app_name}"
rm -f "$STAGE/{app_name}/BUILD.bazel" "$STAGE/{app_name}/REPO.bazel" \\
    "$STAGE/{app_name}/WORKSPACE" "$STAGE/{app_name}/MODULE.bazel"
mv "$STAGE/{app_name}/electron.exe" "$STAGE/{app_name}/{app_name}.exe"
mkdir -p "$STAGE/{app_name}/resources/app"
cp {main_js} "$STAGE/{app_name}/resources/app/main.js"
cp {package_json} "$STAGE/{app_name}/resources/app/package.json"
cp -R {site} "$STAGE/{app_name}/resources/app/site"
"{jar}" cMf "$PWD/{out}" -C "$STAGE" {app_name}
""".format(
        app_name = ctx.attr.app_name,
        electron_root = electron_root,
        main_js = ctx.file.main_js.path,
        package_json = ctx.file.package_json.path,
        site = site.path,
        jar = ctx.file._jar.path,
        out = out.path,
    )

    ctx.actions.run_shell(
        command = command,
        inputs = depset(
            [ctx.file.main_js, ctx.file.package_json, site],
            transitive = [ctx.attr._electron_win.files, ctx.attr._jdk_files.files],
        ),
        outputs = [out],
        mnemonic = "WindowsElectronPackage",
        progress_message = "Packaging %s for Windows x64" % ctx.attr.app_name,
    )
    return [DefaultInfo(files = depset([out]))]

windows_electron_package = rule(
    implementation = _windows_electron_package_impl,
    attrs = {
        "app_name": attr.string(mandatory = True),
        "main_js": attr.label(allow_single_file = True, mandatory = True),
        "package_json": attr.label(allow_single_file = True, mandatory = True),
        "site": attr.label(mandatory = True),
        "_electron_win": attr.label(default = Label("@electron_win64//:all")),
        "_jar": attr.label(
            default = Label("@hermetic_jdk//:Contents/Home/bin/jar"),
            allow_single_file = True,
        ),
        "_jdk_files": attr.label(default = Label("@hermetic_jdk//:all")),
    },
    doc = "Zips the wasm app with the Windows x64 Electron runtime: unzip " +
          "on any 64-bit Windows machine and run <app_name>.exe.",
)

def electron_application(name, site, main_js, package_json, env = {}, extra_files = [], **kwargs):
    """`bazel run`-able Electron shell around a static_site target.

    Launches the hermetically downloaded Electron with the package directory
    (main.js + package.json); the site location is passed via ISO_SITE_DIR.
    """
    script_name = name + "_run.sh"
    write_file(
        name = name + "_script",
        out = script_name,
        content = [
            "#!/bin/bash",
            "set -euo pipefail",
            'RUNFILES_ROOT="$PWD/.."',
            'ELECTRON="$(cat "$RUNFILES_ROOT/$1")"',
            'APP_DIR="$RUNFILES_ROOT/$(dirname "$2")"',
            'export ISO_SITE_DIR="$RUNFILES_ROOT/$3"',
        ] + [
            'export {}="{}"'.format(key, value)
            for key, value in env.items()
        ] + [
            'exec "$ELECTRON" "$APP_DIR"',
        ],
        is_executable = True,
    )
    sh_binary(
        name = name,
        srcs = [script_name],
        args = [
            "$(rlocationpath %s)" % Label("@electron//:electron_path.txt") + "",
            "$(rlocationpath %s)" % package_json,
            "$(rlocationpath %s)" % site,
        ],
        data = [
            main_js,
            package_json,
            site,
            Label("@electron//:electron_path.txt"),
        ] + extra_files,
        **kwargs
    )


# --- Isomer adoption-level macros (docs/adoption_levels.md) ----------

# The runtime's browser-ready ES modules, served raw under runtime/;
# boot.js resolves this app's bindings at ../app_bridge.js (site root).
_ISO_RUNTIME_JS = [
    Label("//wasm/libraries/swift_ui:runtime/boot.js"),
    Label("//wasm/libraries/swift_ui:runtime/bundle_provider.js"),
    Label("//wasm/libraries/swift_ui:runtime/flat_tree.js"),
    Label("//wasm/libraries/swift_ui:runtime/react_renderer.js"),
    Label("//wasm/libraries/swift_ui:runtime/react_embed.js"),
    Label("//wasm/libraries/swift_ui:runtime/raster.js"),
    Label("//wasm/libraries/swift_ui:runtime/symbols.js"),
    Label("//wasm/libraries/swift_ui:runtime/platform_services.js"),
    Label("//wasm/libraries/swift_ui:runtime/imported_files.js"),
    # The app's files over WASI, kept in IndexedDB (boot.js, hot_host.js
    # and imported_files.js import it).
    Label("//wasm/libraries/swift_ui:runtime/file_system.js"),
    # URLSession's transports over fetch and WebSocket (boot.js and
    # hot_host.js import it).
    Label("//wasm/libraries/swift_ui:runtime/network.js"),
    # `.sensoryFeedback`'s vibrations (boot.js and hot_host.js import it).
    Label("//wasm/libraries/swift_ui:runtime/haptics.js"),
    # Isomer's Metal executor: the only navigator.gpu code.
    Label("//metal/runtime:runtime_js"),
]

# What Isomer's hosts look up in a reactor by name: swift_ffi's entries and
# the iso_hot bridge (WasmView's, Android's, the web's feature bundles).
ISOMER_HOST_ENTRIES = HOST_ENTRIES + ["iso_hot_*"]

# What a shipped reactor leaves out of ICU's data (icu_data_library), by
# item (without the package's prefix):
#   - the converters of legacy character sets (5.7 MB): converting from or
#     to one (Shift JIS, a Windows code page) fails; Unicode's forms, ASCII
#     and Latin-1 need no data;
#   - the dictionaries for finding words in Chinese, Japanese, Thai, Lao,
#     Khmer and Burmese text (3 MB): there words are then found
#     character by character.
# Nothing a locale formats or sorts with: every locale's data stays.
ICU_DROP = [
    "*.cnv",
    "brkitr/*.dict",
]

def icu_data_library(name, wasm, drop = ICU_DROP, locales = None, visibility = None):
    """ICU's data for a reactor, less `drop` (fnmatch patterns over its items'
    names; ICU_DROP by default): a cc_library (`<name>`, whole) defining the
    same symbol as the SDK's ICU archive, whose member is then never
    loaded. `wasm` is the reactor linked with every symbol exported (the
    data is read from it: tools/wasm/icu_data.py). Add it to the deps of the
    shipped link only. A reactor without ICU gets a library defining
    nothing. `locales` (language codes) keeps only those languages' locale
    data (tools/wasm/icu_data.py).

    The full Foundation links all of ICU's data: 34 MB of Visor's 60 MB
    reactor, 13 MB of its 21 MB compressed.
    """
    native.genrule(
        name = name + "_object",
        srcs = [wasm],
        outs = [name + ".o"],
        cmd = "$(location %s) $< $@ %s > /dev/null" % (
            Label("//tools/wasm:icu_data"),
            " ".join(["'%s'" % pattern for pattern in drop] +
                     (["locales=%s" % ",".join(locales)] if locales else [])),
        ),
        tools = [Label("//tools/wasm:icu_data")],
        tags = ["manual"],
    )
    cc_library(
        name = name,
        srcs = [":" + name + "_object"],
        alwayslink = True,
        tags = ["manual"],
        visibility = visibility,
    )

def isomer_web_app(
        name,
        swift_library,
        index,
        assets = [],
        extra_pages = [],
        query = "renderer=react",
        icu_locales = None,
        site_visibility = None,
        check_site_imports = True,
        visibility = None):
    """A Isomer web application: generates the wasm reactor + TS
    bindings from `swift_library` (the app's SwiftUI code, alwayslink, deps
    on //wasm/libraries/swift_ui), transpiles the bindings, assembles the
    static site around `index`, and declares a `bazel run` dev server.
    `icu_locales` (language codes) keeps only those languages' ICU locale
    data in an app that has ICU.

    Declares:
      <name>       `bazel run` dev server opening `index` with `query`
      <name>_site  the static site directory (for Electron wrappers etc.)
    """
    # The bridge compiles to real ES modules: app_bridge.js (the bindings,
    # named so boot.js's `../app_bridge.js` import resolves at the site
    # root), swift_ffi_runtime.js (the shared runtime it imports), and the
    # app_bridge.wasm reactor.
    ts_swift_wasm_library(
        name = "app_bridge",
        # Shipped exporting only what the page calls (swift_ffi's entries),
        # read from a link exporting everything: exported whole, a module
        # kept every function and value in the program (Visor's: 83 MB, of
        # which 10 MB of export names), where the page calls some sixty.
        exports = "host",
        export_entries = ISOMER_HOST_ENTRIES,
        # ICU's data, less what ICU_DROP leaves out (an app with the full
        # Foundation; nothing for one without).
        reactor_deps = [":app_bridge_icu"],
        linkopts = [
            # wasm-ld defaults the linear stack to ~1 MiB, which Swift's deeply
            # recursive view-tree / generic-metadata instantiation overflows.
            "-Xlinker",
            "-z",
            "-Xlinker",
            "stack-size=16777216",
        ] + select({
            # Optimized, without its function names (9.6 MB of Visor's): a
            # build to debug keeps them for the browser's stack traces.
            Label("//tools/wasm:opt"): ["-Xlinker", "--strip-all"],
            "//conditions:default": [],
        }),
        module_name = "SwiftUI",
        swift = swift_library,
    )

    icu_data_library(
        name = "app_bridge_icu",
        wasm = ":app_bridge_all.wasm",
        # With ICU (the full Foundation, or Isomer's with
        # //foundation:internationalization): only these languages' locale
        # data, when given.
        locales = icu_locales,
    )

    static_site(
        name = name + "_site",
        assets = assets,
        extra_pages = extra_pages,
        index = index,
        # The generic iso_hot host sits at the site root beside the ffi
        # runtime it imports (it runs feature bundles compiled outside bazel —
        # the web Playground's user builds).
        root_js = [":app_bridge", Label("//wasm/libraries/swift_ui:runtime/hot_host.js")],
        runtime_js = _ISO_RUNTIME_JS + [
            Label("@react_dom_umd//:umd/react-dom.production.min.js"),
            Label("@react_umd//:umd/react.production.min.js"),
        ],
        visibility = site_visibility,
        wasm = ":app_bridge.wasm",
    )

    # Every module the site's pages import is in it (a missing one leaves
    # the page blank). A site that is whole only once combined with another
    # (`combine_sites`) opts out and declares the test on the combination.
    if check_site_imports:
        site_imports_test(
            name = name + "_site_imports_test",
            site = ":%s_site" % name,
        )

    web_server(
        name = name,
        query = query,
        site = ":%s_site" % name,
        visibility = visibility,
    )

def reactor_artifact(name, wasm, visibility = None):
    """The reactor a host bundles: an alias `<name>` to `wasm`, the reactor's
    `transition_binary` (its output is `<x>.wasm`).

    Apps put `:<name>` in their resources/assets, named after the resource the
    host looks up (e.g. `example_full`). Until 0.38 `--config=release` swapped
    in a wamrc-lowered native `.aot` here; WasmKit, the engine on every host
    since, interprets the `.wasm` itself.
    """
    native.alias(
        name = name,
        actual = wasm,
        visibility = visibility,
    )

def _assemble_directory_impl(ctx):
    out = ctx.actions.declare_directory(ctx.label.name)
    commands = []
    inputs = []
    for target, dest in ctx.attr.spec.items():
        files = target[DefaultInfo].files.to_list()
        if len(files) != 1:
            fail("assemble_directory: %s must yield exactly one file" % target.label)
        inputs.append(files[0])
        commands.append("mkdir -p $(dirname %s/%s)" % (out.path, dest))
        commands.append("cp %s %s/%s" % (files[0].path, out.path, dest))
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [out],
        command = " && ".join(commands),
        mnemonic = "AssembleDirectory",
        progress_message = "Assembling %s" % ctx.label,
    )
    return [DefaultInfo(files = depset([out]))]

assemble_directory = rule(
    implementation = _assemble_directory_impl,
    attrs = {
        "spec": attr.label_keyed_string_dict(
            allow_files = True,
            mandatory = True,
            doc = "file label -> destination path inside the directory",
        ),
    },
    doc = "Copies each labeled file to its destination path inside one tree artifact.",
)

def site_imports_test(name, site, entries = ["index.html"], optional = [], **kwargs):
    """Fails when a site's directory lacks a module its pages import.

    A browser drops a page's whole module graph over one missing file, so the
    page is blank and only the console says why. Declare this beside every
    site assembled from a list of files (`assemble_directory`): when the
    runtime gains an import, the test names the file the list has to gain.

    `site` is the directory target; `entries` the pages or modules to walk
    from, relative to it; `optional` the modules a page imports dynamically
    and this site deliberately leaves out.
    """
    py_test(
        name = name,
        srcs = [Label("//tools/wasm:site_imports_test.py")],
        main = Label("//tools/wasm:site_imports_test.py"),
        size = "small",
        args = ["$(rootpath %s)" % site] + entries + (["--optional"] + optional if optional else []),
        data = [site],
        **kwargs
    )

def _wasm_platform_transition_impl(_settings, attr):
    return {"//command_line_option:platforms": [attr.platform]}

_wasm_platform_transition = transition(
    implementation = _wasm_platform_transition_impl,
    inputs = ["//command_line_option:platforms"],
    outputs = ["//command_line_option:platforms"],
)

def _wasm_sdk_bundle_impl(ctx):
    # The transitive .swiftmodules (what user code compiles AGAINST) and the
    # transitive static archives (what the user's object links WITH), in
    # topological order, under the wasm32 transition.
    modules = {}
    # Clang modules the Swift modules import (e.g. swift_ffi's `SwiftABI` C
    # ABI header): shipped as include/<Name>/{headers, module.modulemap} so
    # the out-of-band compile can resolve them (-fmodule-map-file).
    clang_modules = {}
    for dep in ctx.attr.deps:
        for module in dep[SwiftInfo].transitive_modules.to_list():
            if module.swift and module.swift.swiftmodule:
                modules[module.name] = module.swift.swiftmodule
            elif module.clang:
                cc = module.clang.compilation_context or module.compilation_context
                if cc:
                    headers = list(cc.direct_public_headers) or cc.headers.to_list()
                    if headers:
                        # The module's own map when it has one beside its
                        # headers (a map Bazel generates names them by paths
                        # from where it was written): it knows which headers
                        # are textual (_FoundationCShims' unguarded .inc.h,
                        # included twice as a `header`).
                        own_map = module.clang.module_map if type(module.clang.module_map) == "File" else None
                        if own_map and any([h.dirname != own_map.dirname for h in headers]):
                            own_map = None
                        clang_modules[module.name] = struct(headers = headers, module_map = own_map)
    archives = []
    seen = {}
    for dep in ctx.attr.deps:
        for linker_input in dep[CcInfo].linking_context.linker_inputs.to_list():
            for lib in linker_input.libraries:
                file = lib.static_library or lib.pic_static_library
                if file and file.path not in seen:
                    seen[file.path] = True
                    archives.append(file)

    out = ctx.actions.declare_directory(ctx.label.name)
    manifest = struct(
        modules = [
            struct(name = name, path = "modules/%s.swiftmodule" % name)
            for name in sorted(modules.keys())
        ],
        # Indexed to keep link order while avoiding basename collisions.
        archives = [
            "lib/%d_%s" % (i, f.basename)
            for i, f in enumerate(archives)
        ],
        clang_modules = [
            struct(name = name, modulemap = "include/%s/module.modulemap" % name, include = "include/%s" % name)
            for name in sorted(clang_modules.keys())
        ],
    )
    commands = ["mkdir -p {out}/modules {out}/lib".format(out = out.path)]
    for name in sorted(clang_modules.keys()):
        commands.append("mkdir -p {out}/include/{name}".format(out = out.path, name = name))
        for h in clang_modules[name].headers:
            commands.append("cp %s %s/include/%s/%s" % (h.path, out.path, name, h.basename))
        if clang_modules[name].module_map:
            commands.append("cp %s %s/include/%s/module.modulemap" % (clang_modules[name].module_map.path, out.path, name))
            continue
        # printf, not a heredoc: this runs mid-chain (" && "), where a
        # heredoc terminator would never match and swallow the rest.
        lines = ["module %s {" % name] + [
            "  header \"%s\"" % h.basename
            for h in clang_modules[name].headers
        ] + ["  export *", "}"]
        commands.append("printf '%s\\n' {lines} > {out}/include/{name}/module.modulemap".format(
            lines = " ".join(["'%s'" % line for line in lines]),
            out = out.path,
            name = name,
        ))
    for name in sorted(modules.keys()):
        commands.append("cp {src} {out}/modules/{name}.swiftmodule".format(
            src = modules[name].path,
            out = out.path,
            name = name,
        ))
    for i, f in enumerate(archives):
        commands.append("cp %s %s/lib/%d_%s" % (f.path, out.path, i, f.basename))
    # The manifest, with the host's entries ("exports") added: a link with
    # them and --gc-sections keeps what the hosts reach, not every function
    # of every archive.
    base_manifest = ctx.actions.declare_file(ctx.label.name + "_manifest.json")
    ctx.actions.write(base_manifest, json.encode_indent(manifest))
    commands.append("{tool} {base} {out}/manifest.json {archives} -- {patterns}".format(
        tool = ctx.executable._sdk_exports.path,
        base = base_manifest.path,
        out = out.path,
        archives = " ".join(["%s/lib/%d_%s" % (out.path, i, f.basename) for i, f in enumerate(archives)]),
        patterns = " ".join(["'%s'" % p for p in ISOMER_HOST_ENTRIES]),
    ))
    header_inputs = []
    for clang_module in clang_modules.values():
        header_inputs.extend(clang_module.headers)
        if clang_module.module_map:
            header_inputs.append(clang_module.module_map)
    ctx.actions.run_shell(
        inputs = list(modules.values()) + archives + header_inputs + [base_manifest],
        tools = [ctx.executable._sdk_exports],
        outputs = [out],
        command = " && ".join(commands),
        mnemonic = "WasmSdkBundle",
        progress_message = "Bundling wasm SDK %s" % ctx.label,
    )
    return [DefaultInfo(files = depset([out]))]

wasm_sdk_bundle = rule(
    implementation = _wasm_sdk_bundle_impl,
    attrs = {
        "deps": attr.label_list(
            cfg = _wasm_platform_transition,
            providers = [SwiftInfo, CcInfo],
            mandatory = True,
        ),
        "platform": attr.label(mandatory = True),
        "_sdk_exports": attr.label(
            default = Label("//tools/wasm:sdk_exports"),
            executable = True,
            cfg = "exec",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Collects `deps`' transitive wasm32 .swiftmodules + static archives " +
          "into one directory with a manifest.json — the compile-against/" +
          "link-with SDK an out-of-band toolchain (the Playground app) uses " +
          "to build user Swift code into a `iso_hot` reactor without bazel.",
)

def _combine_sites_impl(ctx):
    out = ctx.actions.declare_directory(ctx.label.name)
    commands = ["mkdir -p " + out.path]
    inputs = []
    for target, dest in ctx.attr.sites.items():
        files = target.files.to_list()
        if len(files) != 1:
            fail("combine_sites: %s must produce exactly one site directory" % target.label)
        inputs.append(files[0])
        sub = out.path if dest in ("", ".") else out.path + "/" + dest
        commands.append("mkdir -p %s && cp -R %s/. %s/ && chmod -R u+w %s" % (sub, files[0].path, sub, sub))
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [out],
        command = " && ".join(commands),
        mnemonic = "CombineSites",
        progress_message = "Combining static sites into %s" % ctx.label.name,
    )
    return [DefaultInfo(files = depset([out]))]

combine_sites = rule(
    implementation = _combine_sites_impl,
    attrs = {
        "sites": attr.label_keyed_string_dict(
            allow_files = True,
            doc = "static_site directories → the subdirectory each lands in ('.' = the root).",
        ),
    },
    doc = "One static site out of several: e.g. a front page at the root and an app under a subdirectory.",
)
