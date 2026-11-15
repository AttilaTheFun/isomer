#!/bin/bash
# A signed build, saved as a GitHub release's asset (docs/RELEASE_ASSETS.md):
# sourced by sign_from_ci.sh (Applications Server's publish and promote
# scripts are gone with it, 2026-11-15: `release_asset`, for a build a
# server answered, stays for a repository still copying them), which calls
# `release_asset_file` with each package Shireworks signed (or, an .apk,
# checked, with what Shireworks answered for it). The job then
# attaches the folder to its release (attach_release.sh). bash, curl and
# openssl; sha256sum or shasum.
#
#   release_asset_file <package> <dir> [<app>] [<described by>]
#
# - <package>: a signed .ipa, Mac app's .zip or .dmg, or an .apk, copied
#   into <dir>;
# - <app>: the app's name across platforms, else its Info.plist's (an
#   .apk's label);
# - <described by>: the package whose Info.plist describes it, else itself
#   (a .dmg's: its app's .zip, as a disk image isn't read here); or, ending
#   in .json, what Shireworks answered for it (`shireworks.sh sign`'s
#   output): an .apk's, as python can't read AndroidManifest.xml's binary
#   XML (release_asset_answer_describe).
#
#   release_asset <build JSON> <dir> <server> <ca.pem> <file>
#
# - <build JSON>: one build as the server lists it (its keys sorted), on
#   one line;
# - <file>: what to download of it: app.ipa, app.zip, app.apk or app.dmg.
#
# It downloads the file as <App>-<version>-<platform>.<ext>, and adds its
# line to <dir>/builds.json, which it writes again whole each time: the
# builds of every call into the folder, one a line, with the app's link
# schemes as the server read them ("urlSchemes"). A Mac app's .zip gives
# the app's icon too, <App>-<version>-icon.png (the largest PNG in the .icns
# its Info.plist names), named in its line as "icon": what Applications
# shows for the app. An icon that can't be read is left out, never failing
# the release. python3, for the icon.

release_asset_field() {
  printf '%s' "$1" | sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p"
}

# A JSON string's inside: backslashes and quotes escaped (the server's
# values have no control characters).
release_asset_json() {
  printf '%s' "$1" | sed 's/[\\"]/\\&/g'
}

# A Mac app's icon, from its .zip: the largest PNG rendition in the .icns
# its Info.plist names (CFBundleIconFile), else the first .icns in its
# Resources, written to <png>.
#
#   release_asset_icon <zip> <png>
release_asset_icon() {
  python3 -I - "$1" "$2" << 'PY'
import plistlib, struct, sys, zipfile
archive = zipfile.ZipFile(sys.argv[1])
names = archive.namelist()
infos = [n for n in names if n.count("/") == 2 and n.endswith(".app/Contents/Info.plist")]
if not infos:
    sys.exit("no app in the zip")
resources = infos[0][: -len("Info.plist")] + "Resources/"
named = plistlib.loads(archive.read(infos[0])).get("CFBundleIconFile", "")
wanted = resources + (named if named.endswith(".icns") else named + ".icns") if named else None
icns = wanted if wanted in names else next((n for n in names if n.startswith(resources) and n.endswith(".icns")), None)
if not icns:
    sys.exit("no .icns")
data = archive.read(icns)
best, width, at = None, 0, 8
while at + 8 <= len(data):
    size = struct.unpack(">I", data[at + 4:at + 8])[0]
    body = data[at + 8:at + size]
    if body[:8] == b"\x89PNG\r\n\x1a\n" and body[12:16] == b"IHDR":
        found = struct.unpack(">I", body[16:20])[0]
        if found > width:
            best, width = body, found
    if size < 8:
        break
    at += size
if not best:
    sys.exit("no PNG in the .icns")
open(sys.argv[2], "wb").write(best)
PY
}

release_asset() {
  local build="$1" dir="$2" server="$3" ca="$4" file="$5"
  local id key name app version build_number platform bundle variant channel commit uuid ext asset status icon schemes
  id="$(release_asset_field "$build" id)"
  key="$(release_asset_field "$build" downloadKey)"
  name="$(release_asset_field "$build" name)"
  app="$(release_asset_field "$build" app)"
  version="$(release_asset_field "$build" version)"
  build_number="$(release_asset_field "$build" buildNumber)"
  platform="$(release_asset_field "$build" platform)"
  bundle="$(release_asset_field "$build" bundleID)"
  variant="$(release_asset_field "$build" buildVariant)"
  channel="$(release_asset_field "$build" channel)"
  commit="$(release_asset_field "$build" commit)"
  uuid="$(release_asset_field "$build" executableUUID)"
  # The app's link schemes, as the server read them (a JSON array, kept as
  # it is): how Applications on an iPhone asks iOS whether it's installed.
  schemes="$(printf '%s' "$build" | sed -n 's/.*"urlSchemes":\(\[[^]]*\]\).*/\1/p')"
  [ -n "$id" ] && [ -n "$key" ] && [ -n "$version" ] && [ -n "$platform" ] && [ -n "$bundle" ] ||
    { echo "release_asset: the server's answer names no build" >&2; return 1; }
  [ -n "$variant" ] || variant="$([ "$channel" = production ] && echo Production || echo Alpha)"
  [ -n "$commit" ] || commit="${APPLICATIONS_COMMIT:-${GITHUB_SHA:-}}"
  ext="${file##*.}"
  # The app's name across platforms, else the build's own: no spaces or
  # slashes in a file name.
  asset="$(printf '%s' "${app:-$name}" | tr ' /' '--')-$version-$platform.$ext"

  mkdir -p "$dir"
  status="$(curl -sS --cacert "$ca" --connect-timeout 10 --max-time 1800 -o "$dir/$asset" -w '%{http_code}' \
    "$server/builds/$id/$key/$file")" || { rm -f "$dir/$asset"; echo "release_asset: $asset was not downloaded" >&2; return 1; }
  [ "$status" = 200 ] || { rm -f "$dir/$asset"; echo "release_asset: $asset was not downloaded ($status)" >&2; return 1; }
  icon=""
  if [ "$ext" = zip ] && [ "$platform" = macos ]; then
    icon="$(printf '%s' "${app:-$name}" | tr ' /' '--')-$version-icon.png"
    release_asset_icon "$dir/$asset" "$dir/$icon" || { rm -f "$dir/$icon"; icon=""; }
  fi

  release_asset_record "$dir" "$asset" "$bundle" "${app:-$name}" "$platform" "$version" "$build_number" "$variant" "$commit" "$uuid" "$icon" "$schemes"
}

# One line of builds.json for a file in <dir>, replacing the line of a file
# of the same name, and builds.json written again whole.
#
#   release_asset_record <dir> <file> <bundle id> <app> <platform> <version> <build number> <variant> <commit> <uuid> <icon> <schemes JSON>
release_asset_record() {
  local dir="$1" asset="$2" bundle="$3" app="$4" platform="$5" version="$6" build_number="$7" variant="$8" commit="$9"
  local uuid="${10}" icon="${11}" schemes="${12}" digest size
  if command -v sha256sum > /dev/null; then digest="$(sha256sum "$dir/$asset" | cut -d' ' -f1)"
  else digest="$(shasum -a 256 "$dir/$asset" | cut -d' ' -f1)"; fi
  size="$(wc -c < "$dir/$asset" | tr -d ' ')"
  touch "$dir/builds.lines"
  grep -v "\"file\":\"$(release_asset_json "$asset")\"" "$dir/builds.lines" > "$dir/builds.lines.new" || true
  printf '{"file":"%s","bundleID":"%s","app":"%s","platform":"%s","version":"%s","buildNumber":"%s","variant":"%s","commit":"%s","executableUUID":"%s","size":%s,"sha256":"%s"%s}\n' \
    "$(release_asset_json "$asset")" "$(release_asset_json "$bundle")" "$(release_asset_json "$app")" \
    "$platform" "$(release_asset_json "$version")" "$(release_asset_json "$build_number")" "$variant" "$commit" "$uuid" \
    "$size" "$digest" "${icon:+,\"icon\":\"$(release_asset_json "$icon")\"}${schemes:+,\"urlSchemes\":$schemes}" >> "$dir/builds.lines.new"
  mv "$dir/builds.lines.new" "$dir/builds.lines"
  { echo '['; sed '$!s/$/,/' "$dir/builds.lines"; echo ']'; } > "$dir/builds.json"
  # Fail closed: a builds.json Applications can't read would hide the
  # release (a scheme or an icon's name the lines above didn't expect).
  python3 -I -m json.tool "$dir/builds.json" > /dev/null || { echo "release_asset: builds.json isn't JSON" >&2; return 1; }
  echo "Saved for the release: $asset"
}

# A signed package's Info.plist, as release_asset_file needs it: one value a
# line (bundle id, name, version, build number, variant, executable UUID,
# platform), then its link schemes as a JSON array. python3: the .ipa's
# Payload/<Name>.app/Info.plist, or the Mac app's
# <Name>.app/Contents/Info.plist, binary or XML; the UUID the linker gave
# its executable (LC_UUID: the arm64 slice of a fat one, else the first),
# as Applications reads its own.
#
#   release_asset_describe <package>
release_asset_describe() {
  python3 -I - "$1" << 'PY'
import json, plistlib, struct, sys, uuid, zipfile
archive = zipfile.ZipFile(sys.argv[1])
names = archive.namelist()
def parts(name):
    return name.split("/")
ios = [n for n in names if len(parts(n)) == 3 and parts(n)[0] == "Payload" and parts(n)[1].endswith(".app") and parts(n)[2] == "Info.plist"]
mac = [n for n in names if len(parts(n)) == 3 and parts(n)[0].endswith(".app") and parts(n)[1:] == ["Contents", "Info.plist"]]
if ios:
    plist, platform = ios[0], "ios"
    executables = plist[: -len("Info.plist")]
elif mac:
    plist, platform = mac[0], "macos"
    executables = plist[: -len("Info.plist")] + "MacOS/"
else:
    sys.exit("no app in it")
info = plistlib.loads(archive.read(plist))
bundle = info.get("CFBundleIdentifier")
if not bundle:
    sys.exit("its Info.plist names no bundle id")

def thin(data, start):
    if start + 28 > len(data):
        return ""
    magic = struct.unpack_from("<I", data, start)[0]
    header = {0xFEEDFACF: 32, 0xFEEDFACE: 28}.get(magic)
    if not header:
        return ""
    cursor = start + header
    for _ in range(struct.unpack_from("<I", data, start + 16)[0]):
        if cursor + 8 > len(data):
            return ""
        command, size = struct.unpack_from("<II", data, cursor)
        if command == 0x1B:
            return str(uuid.UUID(bytes=bytes(data[cursor + 8:cursor + 24]))).upper()
        if size <= 0:
            return ""
        cursor += size
    return ""

def executable_uuid(data):
    if len(data) < 8:
        return ""
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        wide = magic == 0xCAFEBABF
        entry, first = (32 if wide else 20), None
        for index in range(struct.unpack_from(">I", data, 4)[0]):
            base = 8 + index * entry
            if base + entry > len(data):
                break
            cpu = struct.unpack_from(">I", data, base)[0]
            offset = struct.unpack_from(">Q" if wide else ">I", data, base + 8)[0]
            if cpu == 0x0100000C:
                return thin(data, offset)
            if first is None:
                first = offset
        return thin(data, first) if first is not None else ""
    return thin(data, 0)

executable = executables + info.get("CFBundleExecutable", "")
found = executable_uuid(archive.read(executable)) if info.get("CFBundleExecutable") and executable in names else ""
schemes = [scheme for kind in info.get("CFBundleURLTypes", []) for scheme in kind.get("CFBundleURLSchemes", [])]
for value in (bundle, info.get("CFBundleDisplayName") or info.get("CFBundleName") or bundle,
              info.get("CFBundleShortVersionString", ""), info.get("CFBundleVersion", ""), info.get("BuildVariant", ""), found, platform):
    if "\n" in str(value):
        sys.exit("a value in its Info.plist has a line break")
    print(value)
print(json.dumps(schemes, separators=(",", ":")) if schemes else "")
PY
}

# What Shireworks' signing answered for a package (`shireworks.sh sign`'s
# output: its bundle id, channel and "build"), as release_asset_describe
# prints a package's. An .apk's, as Applications Server's lines had it: it
# carries no BuildVariant, so Shireworks names it by the channel its policy
# decided (a releaser's release: Production; main's: Alpha), and so does
# this if an answer has none; no executable UUID; its link schemes always
# an array, "[]".
#
#   release_asset_answer_describe <answer.json>
release_asset_answer_describe() {
  python3 -I - "$1" << 'PY'
import json, sys
answer = json.load(open(sys.argv[1]))
build = answer.get("build")
if not isinstance(build, dict):
    sys.exit("Shireworks' answer describes no build")
bundle = answer.get("bundleID")
if not bundle:
    sys.exit("Shireworks' answer names no bundle id")
platform = build.get("platform") or ""
variant = build.get("variant") or ("Production" if answer.get("channel") == "production" else "Alpha")
schemes = build.get("urlSchemes") or []
for value in (bundle, build.get("name") or bundle, build.get("version") or "", build.get("buildNumber") or "", variant,
              build.get("executableUUID") or "", platform):
    if "\n" in str(value):
        sys.exit("a value in Shireworks' answer has a line break")
    print(value)
print(json.dumps(schemes, separators=(",", ":")) if schemes or platform == "android" else "")
PY
}

release_asset_file() {
  local package="$1" dir="$2" app="${3:-}" described="${4:-$1}"
  local description bundle name version build_number variant uuid platform schemes ext asset icon
  case "$described" in
    *.json) description="$(release_asset_answer_describe "$described")" ;;
    *) description="$(release_asset_describe "$described")" ;;
  esac || { echo "release_asset_file: $(basename "$described") was not read" >&2; return 1; }
  { read -r bundle; read -r name; read -r version; read -r build_number; read -r variant; read -r uuid; read -r platform; read -r schemes; } \
    <<< "$description" || true
  [ -n "$bundle" ] && [ -n "$version" ] && [ -n "$platform" ] || { echo "release_asset_file: $(basename "$described") names no build" >&2; return 1; }
  [ -n "$variant" ] || variant=Alpha
  ext="${package##*.}"
  app="${app:-$name}"
  asset="$(printf '%s' "$app" | tr ' /' '--')-$version-$platform.$ext"
  mkdir -p "$dir"
  cp "$package" "$dir/$asset"
  icon=""
  if [ "$ext" = zip ] && [ "$platform" = macos ]; then
    icon="$(printf '%s' "$app" | tr ' /' '--')-$version-icon.png"
    release_asset_icon "$dir/$asset" "$dir/$icon" || { rm -f "$dir/$icon"; icon=""; }
  fi
  release_asset_record "$dir" "$asset" "$bundle" "$app" "$platform" "$version" "$build_number" "$variant" "${GITHUB_SHA:-}" "$uuid" "$icon" "$schemes"
}
