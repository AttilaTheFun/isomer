#!/usr/bin/env bash
# Packages the Linux Playground as one directory a Linux desktop runs (its
# Swift runtime included): run in the Linux build container after building,
# from the playground module (isomer's tools/linux/build.sh --module
# playground --after 'linux/playground_linux_application/package.sh <out>
# <flags>' --out <path> <dir> <targets>). It lands in the container's home;
# build.sh's --out brings it out.
#
#   <out>/playground              the app
#   <out>/playground_wasm_loader  a build's window
#   <out>/lib/                    the Swift runtime (LD_LIBRARY_PATH)
#   <out>/run.sh                  runs the app
#
#   package.sh [<out> [<the build's bazel flags…>]]   e.g. package.sh /root/playground-linux -c opt
set -euo pipefail
out="${1:-/root/playground-linux}"
[ $# -gt 0 ] && shift
rm -rf "$out" && mkdir -p "$out/lib"
# The outputs of the build that ran: the same flags name its configuration.
files() { bazel cquery "$@" --output=files 2>/dev/null; }
output_base="$(bazel info output_base 2>/dev/null)"
flags=("$@")
cp -L "$(files "${flags[@]}" //linux/playground_linux_application:playground_linux_application_bin)" "$out/playground"
cp -L "$(files "${flags[@]}" //linux/playground_linux_application:playground_wasm_loader)" "$out/playground_wasm_loader"
core="$(find "$output_base/external" -name libswiftCore.so -path '*linux*' | head -n1)"
cp -L "$(dirname "$core")"/*.so "$out/lib/"
cat > "$out/run.sh" <<'RUN'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd)"
export LD_LIBRARY_PATH="$here/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$here/playground" "$@"
RUN
chmod +x "$out/run.sh"
du -sh "$out"
