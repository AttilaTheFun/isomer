#!/usr/bin/env bash
# Packages the Linux app as one directory a Linux desktop runs (its Swift
# runtime included): run in the Linux build container after building, from
# the playground module (isomer's tools/linux/build.sh --module playground
# --after linux/isomer_linux_application/package.sh <targets>). The
# container's home is a folder on the Mac (oss), so the package is there too.
#
#   <out>/isomer              the app      <out>/isomer_wasm_loader
#   <out>/gallery.wasm        the Gallery's reactor
#   <out>/lib/                the Swift runtime (LD_LIBRARY_PATH)
#   <out>/runfiles/           the Gallery's images (RUNFILES_DIR)
#   <out>/run.sh              runs the app
set -euo pipefail
out="${1:-/root/isomer-linux}"
rm -rf "$out" && mkdir -p "$out/lib" "$out/runfiles/_main"
files() { bazel cquery --output=files "$1" 2>/dev/null; }
output_base="$(bazel info output_base 2>/dev/null)"
cp -L "$(files //linux/isomer_linux_application:isomer_linux_application_bin)" "$out/isomer"
cp -L "$(files //linux/isomer_linux_application:isomer_wasm_loader)" "$out/isomer_wasm_loader"
cp -L "$(files //shared/gallery_reactor:gallery.wasm)" "$out/gallery.wasm"
cp -RL "$output_base/external/isomer+/gallery/assets" "$out/runfiles/_main/gallery_assets"
core="$(find "$output_base/external" -name libswiftCore.so -path '*linux*' | head -n1)"
cp -L "$(dirname "$core")"/*.so "$out/lib/"
cat > "$out/run.sh" <<'RUN'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd)"
export LD_LIBRARY_PATH="$here/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export RUNFILES_DIR="$here/runfiles"
exec "$here/isomer" "$@"
RUN
chmod +x "$out/run.sh"
du -sh "$out"
