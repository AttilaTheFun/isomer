#!/bin/bash
# Signs a GitHub Actions job's builds through Shireworks' signing service
# (docs/CI.md, "Signing"), in place of Applications Server: CI holds no
# signing key, no notary key and no password. Each package goes to
# Shireworks with the job's OIDC token (`shireworks.sh sign`), which its
# policy checks (the repository pinned, this workflow, main's dispatch or a
# releaser's release) before it signs, on its own Mac, with identities and
# profiles that never leave its Keychain. A Mac app is notarized there; its
# ticket is stapled on a Mac slot leased for the job, which also makes a
# production release's disk image. A Mac app or disk image the notary
# didn't accept fails the job. Each signed build is then saved into
# <dir> as its release's asset, with builds.json describing it
# (release_assets.sh), for attach_release.sh.
#
#   tools/ci/sign_from_ci.sh [--promote] [--app <app>] --download <dir> <package>…
#
# - <package>: an .ipa (an iPhone and iPad app, a device build signed ad
#   hoc) or a Mac app's .zip, as CI built it (`--config=alpha`), or, with
#   --promote, as a proposal attached it (an Alpha, signed);
# - --promote: a published release's run (its v* tag's): each app stamped
#   Production by Shireworks and signed for production, and each Mac app's
#   disk image made, signed, notarized and stapled beside it;
# - --app: the app's name across platforms, in the assets' names
#   (`<App>-<version>-<platform>.<ext>`), else each build's own.
#
# From the job's environment: `permissions: id-token: write`, and the
# runner's SHIREWORKS_GRANT (tools/ci/shireworks.sh). bash and python3.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SW="$ROOT/tools/ci/shireworks_retry.sh"
fail() { echo "sign_from_ci: $*" >&2; exit 1; }
usage="usage: tools/ci/sign_from_ci.sh [--promote] [--app <app>] --download <dir> <package>…"

promote=""
app=""
download=""
packages=()
while [ $# -gt 0 ]; do
  case "$1" in
    --promote) promote=1; shift ;;
    --app) app="${2:?--app takes the name of the app}"; shift 2 ;;
    --download) download="${2:?--download takes a folder}"; shift 2 ;;
    -*) fail "unknown option $1" ;;
    *) packages+=("$1"); shift ;;
  esac
done
[ -n "$download" ] && [ ${#packages[@]} -gt 0 ] || fail "$usage"
for package in "${packages[@]}"; do
  [ -f "$package" ] || fail "no such file: $package"
  case "$package" in *.ipa|*.zip) ;; *) fail "$(basename "$package") is neither an .ipa nor a Mac app's .zip" ;; esac
done

work="$(mktemp -d)"
chmod 700 "$work"
# shellcheck source=tools/ci/mac_slot.sh
. "$ROOT/tools/ci/mac_slot.sh"
# An end before the last line is a failure, whatever macOS's bash 3.2 says
# (publish_from_ci.sh); the slot is given back however it ends.
finished=""
cleanup() {
  local code=$?
  mac_slot_release
  rm -rf "$work"
  [ -n "$finished" ] || [ "$code" -ne 0 ] || code=1
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# shellcheck source=tools/ci/release_assets.sh
. "$ROOT/tools/ci/release_assets.sh"

# sign <file> <package kind> [<shireworks.sh options>…]: signed in place;
# what Shireworks said (its channel, bundle id, version and whether it was
# notarized) is printed, and kept in $work/answer.json.
sign() {
  local file="$1" kind="$2"
  shift 2
  "$SW" sign "$file" --package="$kind" "$@" > "$work/answer.json" || fail "$(basename "$file") was not signed"
  python3 -I -c '
import json, sys
answer = json.load(open(sys.argv[1]))
print("Signed by Shireworks: " + ", ".join(f"{key} {answer.get(key)}" for key in ("bundleID", "version", "channel", "notarized")))
' "$work/answer.json"
}
# Whether Shireworks' notary accepted it: its answer's "notarized" is
# "accepted (<submission>)", "skipped: <why>", or absent (an .ipa).
notarized() {
  python3 -I -c '
import json, sys
sys.exit(0 if str(json.load(open(sys.argv[1])).get("notarized") or "").startswith("accepted") else 1)
' "$work/answer.json"
}

# staple <file>: a notarized Mac app's .zip (its app's ticket) or disk
# image, stapled on the job's Mac slot, in place.
staple() {
  local file="$1" name
  name="staple-$(basename "$file")"
  mac_slot_lease
  mac_slot_upload "$file" "$name"
  case "$file" in
    *.zip) mac_slot_exec /bin/bash -c 'set -euo pipefail
      rm -rf staple && mkdir staple && ditto -x -k "$1" staple
      app="$(ls -d staple/*.app | head -1)"
      xcrun stapler staple -q "$app"
      rm -f "$1" && ditto -c -k --keepParent "$app" "$1" && rm -rf staple' _ "$name" ;;
    *.dmg) mac_slot_exec /bin/bash -c 'set -euo pipefail; xcrun stapler staple -q "$1"' _ "$name" ;;
  esac
  mac_slot_download "$name" "$file"
  echo "Stapled: $(basename "$file")"
}

# disk_image <zip> <volume> <dmg>: the Mac app and a link to /Applications,
# as a Mac app is handed out to people, made on the job's Mac slot as
# Applications Server made it (Signer.diskImage).
disk_image() {
  local zip="$1" volume="$2" dmg="$3"
  mac_slot_lease
  mac_slot_upload "$zip" image-app.zip
  # -anyowners: hdiutil asks for authentication when it can't keep a file's
  # owner, and nobody answers a slot's prompt (Signer.makeDiskImage).
  mac_slot_exec /bin/bash -c 'set -euo pipefail
    rm -rf image image.dmg && mkdir image && ditto -x -k image-app.zip image
    ln -s /Applications image/Applications
    hdiutil create -quiet -anyowners -volname "$1" -srcfolder image -format UDZO -fs APFS image.dmg
    rm -rf image image-app.zip' _ "$volume"
  mac_slot_download image.dmg "$dmg"
  echo "Disk image made: $(basename "$dmg")"
}

for package in "${packages[@]}"; do
  copy="$work/$(basename "$package")"
  cp "$package" "$copy"
  case "$copy" in
    *.ipa)
      sign "$copy" ipa ${promote:+--promote}
      release_asset_file "$copy" "$download" "$app" || fail "$(basename "$package") was not saved"
      ;;
    *.zip)
      sign "$copy" mac ${promote:+--promote}
      # Fail closed: a Mac app that isn't notarized is a broken download.
      notarized || fail "$(basename "$package") was signed but not notarized"
      staple "$copy"
      release_asset_file "$copy" "$download" "$app" || fail "$(basename "$package") was not saved"
      if [ -n "$promote" ]; then
        description="$(release_asset_describe "$copy")"
        bundle="$(printf '%s\n' "$description" | sed -n 1p)"
        name="$(printf '%s\n' "$description" | sed -n 2p)"
        dmg="$work/$(basename "$copy" .zip).dmg"
        disk_image "$copy" "$name" "$dmg"
        sign "$dmg" dmg --bundle-id="$bundle"
        if notarized; then staple "$dmg"; else fail "$(basename "$dmg") was not notarized: a production disk image must be"; fi
        release_asset_file "$dmg" "$download" "$app" "$copy" || fail "$(basename "$dmg") was not saved"
      fi
      ;;
  esac
done
finished=1
