#!/bin/bash
# An Apple app's BuildVariant (its Info.plist's, //tools/variant in the
# examples) changed in its package, in place: an .ipa's app, or a Mac app's
# .zip. How a release makes its tested Alphas production (the owner,
# 2026-11-02: a release is the Alpha that was tested, promoted, never
# rebuilt): the package stamped Production, then signed again
# (tools/ci/sign_builds.sh), as Shireworks' signing service's promotion
# does (its AppleSigning VariantStamp) and Applications Server's did. Its
# signature no longer holds, so it must be signed after: a Mac app's
# stapled ticket (Contents/CodeResources) is taken out with it.
#
#   tools/ci/stamp_variant.sh <variant> <package>…
#
# <variant>: Alpha, Beta, Production or AdHoc. Every other entry of the
# zip is kept as it was (its symbolic links too); the Info.plist keeps its
# format, binary or XML. python3 alone.
set -euo pipefail
variant="${1:?usage: tools/ci/stamp_variant.sh <variant> <package>…}"
shift
case "$variant" in Alpha | Beta | Production | AdHoc) ;; *) echo "stamp_variant: no variant $variant" >&2; exit 2 ;; esac
[ $# -gt 0 ] || { echo "usage: tools/ci/stamp_variant.sh <variant> <package>…" >&2; exit 2; }
for package in "$@"; do
    [ -f "$package" ] || { echo "stamp_variant: no such file: $package" >&2; exit 1; }
    python3 -I - "$package" "$variant" << 'PY'
import os, plistlib, sys, tempfile, zipfile
path, variant = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(path) as archive:
    entries = archive.infolist()
    names = [entry.filename for entry in entries]
    parts = [name.split("/") for name in names]
    ios = [n for n, p in zip(names, parts) if len(p) == 3 and p[0] == "Payload" and p[1].endswith(".app") and p[2] == "Info.plist"]
    mac = [n for n, p in zip(names, parts) if len(p) == 3 and p[0].endswith(".app") and p[1:] == ["Contents", "Info.plist"]]
    if len(ios) + len(mac) != 1:
        sys.exit(f"stamp_variant: {os.path.basename(path)} holds {len(ios) + len(mac)} apps, not one")
    plist = (ios or mac)[0]
    # A Mac app's stapled ticket goes with its signature.
    dropped = {plist[: -len("Info.plist")] + "CodeResources"} if mac else set()
    data = archive.read(plist)
    form = plistlib.FMT_BINARY if data.startswith(b"bplist") else plistlib.FMT_XML
    info = plistlib.loads(data)
    if not isinstance(info, dict):
        sys.exit(f"stamp_variant: {plist} is not a dictionary")
    was = info.get("BuildVariant")
    info["BuildVariant"] = variant
    stamped = plistlib.dumps(info, fmt=form)
    folder = os.path.dirname(os.path.abspath(path))
    handle, temporary = tempfile.mkstemp(dir=folder, suffix=".zip")
    os.close(handle)
    try:
        with zipfile.ZipFile(temporary, "w") as out:
            for entry in entries:
                if entry.filename in dropped:
                    continue
                body = stamped if entry.filename == plist else archive.read(entry)
                # The entry's own ZipInfo: its mode (a link's too) and compression kept.
                out.writestr(entry, body)
        os.replace(temporary, path)
    except BaseException:
        os.remove(temporary)
        raise
print(f"stamp_variant: {os.path.basename(path)}: BuildVariant {was or '(none)'} -> {variant}")
PY
done
