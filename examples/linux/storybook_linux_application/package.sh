#!/usr/bin/env bash
# Packages the Linux Storybook as one directory a Linux desktop runs (its
# Swift runtime included): run in the Linux build container after building,
# from the examples module (isomer's tools/linux/build.sh --module examples
# --after 'linux/storybook_linux_application/package.sh <out> <flags>' --out
# <path> <dir> <targets>). It lands in the container's home; build.sh's --out
# brings it out.
#
#   <out>/storybook             the app
#   <out>/storybook.runfiles/   its images (the renderer looks for an
#                               imageset beside the executable, under
#                               <executable>.runfiles)
#   <out>/lib/                  the Swift runtime (LD_LIBRARY_PATH)
#   <out>/run.sh                runs the app
#
#   package.sh [<out> [<the build's bazel flags…>]]   e.g. package.sh /root/storybook-linux -c opt
set -euo pipefail
out="${1:-/root/storybook-linux}"
[ $# -gt 0 ] && shift
rm -rf "$out" && mkdir -p "$out/lib" "$out/storybook.runfiles/assets"
# The outputs of the build that ran: the same flags name its configuration.
# cquery names them under the execution root (an external repository's
# files under external/).
execution_root="$(bazel info execution_root 2>/dev/null)"
files() { bazel cquery "$@" --output=files 2>/dev/null | sed "s|^|$execution_root/|"; }
output_base="$(bazel info output_base 2>/dev/null)"
flags=("$@")
cp -L "$(files "${flags[@]}" //linux/storybook_linux_application:storybook_linux_application_bin)" "$out/storybook"
for image in $(files "${flags[@]}" //shared/example_application:assets); do
  directory="$out/storybook.runfiles/assets/$(basename "$(dirname "$image")")"
  mkdir -p "$directory"
  cp -L "$image" "$directory/"
done
core="$(find "$output_base/external" -name libswiftCore.so -path '*linux*' | head -n1)"
cp -L "$(dirname "$core")"/*.so "$out/lib/"
cat > "$out/run.sh" <<'RUN'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd)"
export LD_LIBRARY_PATH="$here/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$here/storybook" "$@"
RUN
chmod +x "$out/run.sh"
du -sh "$out"
