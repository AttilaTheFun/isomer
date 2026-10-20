#!/usr/bin/env python3
"""Dev server for the web Playground: serves the built static site AND a
`/compile` endpoint that turns App.swift into a iso_hot reactor with the HOST
toolchain — the two invocations the iOS Playground's ToolchainCompiler runs —
so the page's loop (agent → compile → run) can be developed before the
in-browser toolchain (tools/browser_toolchain) exists. Never for the
published site: there the compiler worker uses swift-frontend.wasm.

    bazel build //web/playground_web_application:playground_web_application_site \\
                //apple/playground_ios_application:playground_sdk
    tools/playground/dev_compile_server.py \\
        --site bazel-bin/web/playground_web_application/playground_web_application_site \\
        --sdk  bazel-bin/apple/playground_ios_application/playground_sdk \\
        --output-base "$(bazel info output_base)" [--port 8090]

POST /compile (text/plain body = App.swift) → 200 + app.wasm, 422 + diagnostics.
"""
import argparse, http.server, json, mimetypes, os, shutil, subprocess, sys, tempfile, threading


def find_toolchain(output_base):
    ext = os.path.join(output_base, "external")
    swiftc = os.path.join(ext, "rules_swift++swift+swift_toolchain_xcode", "usr", "bin", "swiftc")
    clang = os.path.join(ext, "rules_swift++swift+swift_toolchain_xcode", "usr", "bin", "clang")
    sdk_root = os.path.join(ext, "rules_swift++swift+swift_toolchain_wasm_sdk_xcode")
    bundle = next((d for d in os.listdir(sdk_root) if d.endswith(".artifactbundle")), None) if os.path.isdir(sdk_root) else None
    if not bundle:
        sys.exit("wasm SDK bundle not found under " + sdk_root)
    slice_dir = None
    for root, dirs, _ in os.walk(os.path.join(sdk_root, bundle)):
        if "wasm32-unknown-wasip1" in dirs:
            slice_dir = os.path.join(root, "wasm32-unknown-wasip1")
            break
    if not slice_dir:
        sys.exit("wasm32-unknown-wasip1 slice not found in " + bundle)
    return {
        "swiftc": swiftc, "clang": clang,
        "wasi_sdk": os.path.join(slice_dir, "WASI.sdk"),
        "swift_static": os.path.join(slice_dir, "swift.xctoolchain", "usr", "lib", "swift_static"),
    }


LINK_LIBRARIES = [
    "-lswiftCore", "-lswiftSwiftOnoneSupport", "-lswiftWASILibc",
    "-lswift_Concurrency", "-lswift_RegexParser", "-lswift_StringProcessing",
    "-lswiftObservation", "-lswiftSynchronization",
    "-lc++", "-lc++abi", "-ldl", "-lm",
    "-lwasi-emulated-mman", "-lwasi-emulated-signal", "-lwasi-emulated-process-clocks", "-lwasi-emulated-getpid",
]


def compile_source(source, toolchain, sdk_dir):
    manifest = json.load(open(os.path.join(sdk_dir, "manifest.json")))
    work = tempfile.mkdtemp(prefix="playground-web-")
    try:
        main = os.path.join(work, "App.swift")
        open(main, "w").write(source)
        obj, wasm = os.path.join(work, "UserApp.o"), os.path.join(work, "UserApp.wasm")
        clang_args = []
        for entry in manifest.get("clang_modules", []):
            if entry.get("modulemap"): clang_args += ["-Xcc", "-fmodule-map-file=" + os.path.join(sdk_dir, entry["modulemap"])]
            if entry.get("include"): clang_args += ["-Xcc", "-I", "-Xcc", os.path.join(sdk_dir, entry["include"])]
        compile_cmd = [toolchain["swiftc"],
            "-target", "wasm32-unknown-wasip1", "-Xcc", "--target=wasm32-unknown-wasip1",
            "-sdk", toolchain["wasi_sdk"], "-resource-dir", toolchain["swift_static"],
            "-static-stdlib", "-static", "-parse-as-library", "-module-name", "UserApp",
            "-swift-version", "5", "-Onone", "-whole-module-optimization",
            "-I", os.path.join(sdk_dir, "modules")] + clang_args + [
            "-module-cache-path", os.path.join(work, "module-cache"), "-emit-object", "-o", obj, main]
        env = dict(os.environ, HOME=work)
        result = subprocess.run(compile_cmd, capture_output=True, text=True, env=env)
        if result.returncode != 0:
            return None, (result.stderr + result.stdout).replace(work + "/", "")
        link_cmd = [toolchain["clang"], "--target=wasm32-unknown-wasip1", "--sysroot=" + toolchain["wasi_sdk"],
            "-resource-dir", os.path.join(toolchain["swift_static"], "clang"), obj]
        for archive in manifest["archives"]:
            link_cmd += ["-Wl,--whole-archive", os.path.join(sdk_dir, archive), "-Wl,--no-whole-archive"]
        # The hosts' entries the SDK lists (its manifest's "exports"), the
        # rest dead-stripped, as the app's own compilers link; an SDK without
        # the list keeps everything.
        if manifest.get("exports"):
            link_cmd += ["-Xlinker", "--gc-sections"]
            for name in manifest["exports"]:
                link_cmd += ["-Xlinker", "--export-if-defined=" + name]
        else:
            link_cmd += ["-Xlinker", "--export-all", "-Xlinker", "--no-gc-sections"]
        link_cmd += ["-Xlinker", "-z", "-Xlinker", "stack-size=16777216", "-mexec-model=reactor",
            os.path.join(toolchain["swift_static"], "wasi", "wasm32", "swiftrt.o"),
            "-L", os.path.join(toolchain["swift_static"], "wasi")] + LINK_LIBRARIES + [
            "-Wl,--global-base=4096", "-Wl,--table-base=4096", "-o", wasm]
        result = subprocess.run(link_cmd, capture_output=True, text=True, env=env)
        if result.returncode != 0:
            return None, (result.stderr + result.stdout).replace(work + "/", "")
        return open(wasm, "rb").read(), None
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--site", required=True)
    parser.add_argument("--sdk", required=True)
    parser.add_argument("--output-base", required=True)
    parser.add_argument("--port", type=int, default=8090)
    args = parser.parse_args()
    site = os.path.abspath(args.site)
    sdk_dir = os.path.abspath(args.sdk)
    toolchain = find_toolchain(args.output_base)
    lock = threading.Lock()
    mimetypes.add_type("application/wasm", ".wasm")
    mimetypes.add_type("text/javascript", ".js")

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **k):
            super().__init__(*a, directory=site, **k)

        def do_OPTIONS(self):
            self.send_response(200 if self.path == "/compile" else 404)
            self.end_headers()

        def do_POST(self):
            if self.path != "/compile":
                self.send_error(404); return
            length = int(self.headers.get("Content-Length", "0"))
            source = self.rfile.read(length).decode("utf-8", "replace")
            with lock:
                wasm, diagnostics = compile_source(source, toolchain, sdk_dir)
            if wasm is None:
                body = diagnostics.encode()
                self.send_response(422); self.send_header("Content-Type", "text/plain; charset=utf-8")
            else:
                body = wasm
                self.send_response(200); self.send_header("Content-Type", "application/wasm")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

        def log_message(self, fmt, *a):
            if "/compile" in (str(a[0]) if a else ""): super().log_message(fmt, *a)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Serving {site} with /compile on http://127.0.0.1:{args.port}/?renderer=react  (Ctrl-C to stop)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
