#!/bin/bash
# See BUILD.bazel. Compiles each template with dev_compile_server.py's
# compile_source (compile + link, as the apps do) and fails on the first
# diagnostics.
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"  # python3 (bazel scrubs PATH)
SERVER="$1"; SDK="$2"; shift 2
# <output_base>/execroot/... when run by `bazel test`.
OUTPUT_BASE="${ISO_OUTPUT_BASE:-${PWD%%/execroot/*}}"
python3 - "$SERVER" "$SDK" "$OUTPUT_BASE" "$@" <<'PY'
import importlib.util, os, sys, time
server, sdk, output_base, templates = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
spec = importlib.util.spec_from_file_location("dev_compile_server", server)
dev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dev)
toolchain = dev.find_toolchain(output_base)
failed = []
for template in templates:
    started = time.time()
    wasm, diagnostics = dev.compile_source(open(template).read(), toolchain, os.path.abspath(sdk))
    name = os.path.basename(template)
    if wasm:
        print("ok    %-18s %5.1f s, %d KB" % (name, time.time() - started, len(wasm) // 1024))
    else:
        print("FAIL  %s\n%s" % (name, diagnostics[:4000]))
        failed.append(name)
print("FAILED: " + ", ".join(failed) if failed else "all %d templates compile" % len(templates))
sys.exit(1 if failed else 0)
PY
