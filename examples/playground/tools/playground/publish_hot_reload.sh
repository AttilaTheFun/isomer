#!/bin/bash
# Publishes a wasm build as a new version for a Playground "hot reloader".
#
# A hot reloader in the Playground polls a URL that returns JSON listing the
# published versions of an app (newest first) and runs the newest one full
# screen, reloading when a new version appears. This script maintains that
# JSON and copies the wasm beside it — point it at a directory served as
# static files (GitHub Pages, S3, any web server):
#
#   tools/playground/publish_hot_reload.sh <site-dir> <app.wasm> [version] [notes]
#
# produces/updates <site-dir>/versions.json and <site-dir>/<version>.wasm.
# The Playground's hot reloader URL is then https://<host>/<path>/versions.json.
#
# versions.json (the hot reloader accepts a bare array or {"versions": [...]};
# newest FIRST; `url` absolute or relative to the JSON's URL):
#   [
#     {"version": "2026-09-07T13:20:11Z", "url": "2026-09-07T13-20-11Z.wasm",
#      "notes": "chat screen keyboard fix", "published": "2026-09-07T13:20:11Z"}
#   ]
#
# The wasm must be a Isomer feature bundle (a `iso_hot` reactor —
# what `bazel build //wasm/<feature>:<name>.wasm` in the examples module
# produces, or the Playground's own builds), compiled against the same
# framework version the Playground embeds; a mismatch fails to load and the
# reloader shows the load error.
set -euo pipefail
site="${1:?site dir}"; wasm="${2:?app.wasm}"
version="${3:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
notes="${4:-}"
mkdir -p "$site"
file="$(echo "$version" | tr ':' '-').wasm"
cp "$wasm" "$site/$file"
python3 - "$site/versions.json" "$version" "$file" "$notes" <<'PY'
import json, os, sys, datetime
path, version, file, notes = sys.argv[1:5]
entries = []
if os.path.exists(path):
    data = json.load(open(path))
    entries = data["versions"] if isinstance(data, dict) else data
entries = [e for e in entries if e.get("version") != version]
entries.insert(0, {"version": version, "url": file, "notes": notes,
                   "published": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
json.dump(entries, open(path, "w"), indent=2)
print(f"{path}: {len(entries)} version(s), newest {version}")
PY
