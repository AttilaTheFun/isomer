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
#   <out>/playground_toolchain/   the compiler (swift-frontend, wasm-ld, the wasm SDK)
#   <out>/playground_sdk/         what a project compiles against
#   <out>/lib/                    the Swift runtime (LD_LIBRARY_PATH; the compiler's too)
#   <out>/run.sh                  runs the app
#
#   package.sh [<out> [<the build's bazel flags…>]]   e.g. package.sh /root/playground-linux -c opt
set -euo pipefail
out="${1:-/root/playground-linux}"
[ $# -gt 0 ] && shift
rm -rf "$out" && mkdir -p "$out/lib"
# The outputs of the build that ran: the same flags name its configuration.
# cquery names them under the execution root (the workspace's bazel-out
# link isn't there in a checkout mounted into the container).
execution_root="$(bazel info execution_root 2>/dev/null)"
files() { bazel cquery "$@" --output=files 2>/dev/null | sed "s|^|$execution_root/|"; }
output_base="$(bazel info output_base 2>/dev/null)"
flags=("$@")
cp -L "$(files "${flags[@]}" //playground/linux/playground_linux_application:playground_linux_application_bin)" "$out/playground"
cp -L "$(files "${flags[@]}" //playground/linux/playground_linux_application:playground_wasm_loader)" "$out/playground_wasm_loader"
cp -RL "$(files "${flags[@]}" //playground/shared/compiler:toolchain)/playground_toolchain" "$out/playground_toolchain"
cp -RL "$(files "${flags[@]}" //playground/apple/playground_ios_application:playground_sdk)" "$out/playground_sdk"
# Bazel's outputs are read-only; the copies are the package's own.
chmod -R u+w "$out/playground_toolchain" "$out/playground_sdk"
# The swift.org toolchain is Ubuntu 24.04's: its lld loads libxml2.so.2 (and
# ICU 74 under it), which newer releases have under other names. They go in
# lib/ with the Swift runtime (run.sh puts it on LD_LIBRARY_PATH, which the
# compiler's processes inherit).
for tool in wasm-ld swift-frontend; do
  ldd "$out/playground_toolchain/usr/bin/$tool" | awk '/libxml2|libicu/ {print $3}' | while read -r library; do
    cp -L "$library" "$out/lib/"
  done
done
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
