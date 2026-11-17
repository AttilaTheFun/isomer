#!/bin/bash
# Apple apps signed on Linux, with no Mac (Logan, 2026-11-15: hermetic
# signing; rcodesign and Apple Cross's `dmg`). Every repository's CI copies
# this file and apple_profiles.py beside it byte for byte from
# AttilaTheFun/shireworks, as it does android_sign.sh.
#
#   tools/ci/apple_sign.sh [--key-from-env] [--dmg] [--ipa-kind development|production] [--variant <name>] --out <dir> <package>…
#
# --variant: each app's BuildVariant (its Info.plist's) set before it's
# signed, and a Mac app's stapled ticket taken out: how a published release
# makes its tested Alphas Production (`--variant Production`), as the signing
# service's VariantStamp does.
#
# - a Mac app's .zip (one .app at its top): signed with Developer ID
#   (hardened runtime, a timestamp), its Developer ID profile embedded and
#   its entitlements made the profile's when there's one for it, notarized
#   and stapled, zipped again into <out>/<name>.zip; with --dmg its disk image
#   beside it (<out>/<name>.dmg: the app and an Applications link, its volume
#   named after the app's CFBundleDisplayName, else CFBundleName; HFS+, UDZO),
#   signed, notarized and stapled too;
# - an iPhone app's .ipa: its extensions, then the app, each with its own
#   profile (by bundle id, all of one kind: ad hoc, enterprise or development
#   for production, the default; development alone for --ipa-kind
#   development) and its entitlements made the profile's, and every other
#   piece of code with the same identity, deepest first; into <out>/<name>.ipa.
#   Not notarized (iOS isn't).
#
# How each piece is chosen and its entitlements made is the signing
# service's (apple_profiles.py). The keys go into a folder of their own on a
# tmpfs, are used, and are removed however the script ends; none is ever
# printed or put on a command line. They come from:
# - Shireworks' secret service (a private repository's job on Shireworks'
#   runners; docs/secrets.md), with `permissions: id-token: write` and the
#   runner's SHIREWORKS_GRANT: apple-developer-id-p12 and -password,
#   apple-notary-key, -key-id and apple-notary-issuer for a Mac app (a
#   password-less .p12 keeps no -password secret);
#   apple-development-p12 and -password for an iPhone app; and
#   apple-profiles, a .tar (or .tar.gz) of the profiles (a Mac app's Developer ID one, if
#   its entitlements need one; an empty .tar when none does), for either;
# - with --key-from-env (a public repository's job on GitHub's runners),
#   the same from its GitHub environment's secrets: APPLE_DEVELOPER_ID_P12
#   (base64), APPLE_DEVELOPER_ID_PASSWORD (empty or unset for a password-less
#   .p12, as APPLE_DEVELOPMENT_PASSWORD), APPLE_NOTARY_KEY (the .p8's
#   text), APPLE_NOTARY_KEY_ID, APPLE_NOTARY_ISSUER, APPLE_DEVELOPMENT_P12
#   (base64), APPLE_DEVELOPMENT_PASSWORD, APPLE_PROFILES (the .tar or
#   .tar.gz, base64; with APPLE_PROFILES_2 … _9 beside it where one secret
#   can't hold them all, GitHub's being 48 KB at most); read once, then
#   unset.
#
# A Mac app whose entitlements Apple restricts (its keychain groups, push, a
# group.* app group…) and that has no Developer ID profile here is refused:
# macOS would kill it at launch, and notarizing doesn't catch it.
#
# A .p12 is as Keychain Access exports one (3DES): rcodesign 0.29 can't open
# OpenSSL 3's default (AES, PBKDF2), so one re-wrapped needs -legacy.
# Linux alone (the keys go to /dev/shm). Needs bash, python3, openssl,
# curl, tar, unzip, zip and sha256sum, and zstd for --dmg: any missing put in
# with apt-get where it can be (a CI job's container, as root or with sudo).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
fail() { echo "apple_sign: $*" >&2; exit 1; }
usage="usage: tools/ci/apple_sign.sh [--key-from-env] [--dmg] [--ipa-kind development|production] [--variant <name>] --out <dir> <package>…"

from_env="" make_dmg="" out="" ipa_kind="production" variant=""
packages=()
while [ $# -gt 0 ]; do
  case "$1" in
    --key-from-env) from_env=1; shift ;;
    --dmg) make_dmg=1; shift ;;
    --ipa-kind) ipa_kind="${2:?--ipa-kind takes development or production}"; shift 2 ;;
    --variant) variant="${2:?--variant takes a build variant (Production, Alpha…)}"; shift 2 ;;
    --out) out="${2:?--out takes a folder}"; shift 2 ;;
    -*) fail "unknown option $1" ;;
    *) packages+=("$1"); shift ;;
  esac
done
[ -n "$out" ] && [ ${#packages[@]} -gt 0 ] || fail "$usage"
case "$ipa_kind" in development|production) ;; *) fail "--ipa-kind is development or production" ;; esac
[ -z "$variant" ] || [[ "$variant" =~ ^[A-Za-z][A-Za-z0-9]{0,31}$ ]] || fail "--variant is a word (Production, Alpha…)"
mac="" ios=""
for i in "${!packages[@]}"; do
  [ -f "${packages[$i]}" ] || fail "no such file: ${packages[$i]}"
  case "${packages[$i]}" in
    *.zip) mac=1 ;;
    *.ipa) ios=1 ;;
    *) fail "$(basename "${packages[$i]}") is neither a Mac app's .zip nor an .ipa" ;;
  esac
  packages[i]="$(cd "$(dirname "${packages[$i]}")" && pwd)/$(basename "${packages[$i]}")"
done
mkdir -p "$out"
out="$(cd "$out" && pwd)"

work="$(mktemp -d)"
secrets=""
cleanup() {
  [ -z "$secrets" ] || rm -rf "$secrets"
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The keys, into a tmpfs folder of their own, before anything else runs (a tool put in, a download): with
# --key-from-env, taken from the environment and unset at once, so no process this starts inherits them (NCH).
needed=()
[ -z "$mac" ] || needed+=(apple-developer-id-p12 apple-developer-id-password apple-notary-key apple-notary-key-id apple-notary-issuer)
[ -z "$ios" ] || needed+=(apple-development-p12 apple-development-password)
needed+=(apple-profiles)
if [ -n "$from_env" ]; then
  [ -d /dev/shm ] || fail "no /dev/shm here: the keys are written to a tmpfs alone"
  secrets="$(mktemp -d -p /dev/shm apple-sign-XXXXXX)"
  chmod 700 "$secrets"
  # put <file> <variable> <1: base64 (a .p12, the profiles' .tar) | 0: text>
  put() {
    local file="$1" variable="$2" encoded="$3"
    [ -n "${!variable:-}" ] || return 0
    (umask 077
     if [ "$encoded" = 1 ]; then printf '%s' "${!variable}" | base64 -d > "$secrets/$file"
     else printf '%s' "${!variable}" > "$secrets/$file"; fi) || fail "$variable isn't base64"
  }
  put apple-developer-id-p12 APPLE_DEVELOPER_ID_P12 1
  put apple-developer-id-password APPLE_DEVELOPER_ID_PASSWORD 0
  put apple-notary-key APPLE_NOTARY_KEY 0
  put apple-notary-key-id APPLE_NOTARY_KEY_ID 0
  put apple-notary-issuer APPLE_NOTARY_ISSUER 0
  put apple-development-p12 APPLE_DEVELOPMENT_P12 1
  put apple-development-password APPLE_DEVELOPMENT_PASSWORD 0
  put apple-profiles APPLE_PROFILES 1
  # A password-less .p12 (as Logan's export was) has no password secret: an empty file says so.
  for name in apple-developer-id-password apple-development-password; do
    [ -f "$secrets/$name" ] || (umask 077; : > "$secrets/$name")
  done
  for n in 2 3 4 5 6 7 8 9; do
    put "apple-profiles-$n" "APPLE_PROFILES_$n" 1
    unset "APPLE_PROFILES_$n"
  done
  unset APPLE_DEVELOPER_ID_P12 APPLE_DEVELOPER_ID_PASSWORD APPLE_NOTARY_KEY APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER \
    APPLE_DEVELOPMENT_P12 APPLE_DEVELOPMENT_PASSWORD APPLE_PROFILES
fi
# The tools it uses; in a CI job's own container (throwaway), any missing put in with apt-get, said so; else refused.
tools=(curl tar unzip zip python3 openssl sha256sum)
[ -z "$make_dmg" ] || tools+=(zstd)
missing=()
for tool in "${tools[@]}"; do
  command -v "$tool" > /dev/null || missing+=("$tool")
done
if [ ${#missing[@]} -gt 0 ]; then
  # Not `packages`: that's what's signed.
  apt_packages=()
  for tool in "${missing[@]}"; do
    case "$tool" in sha256sum) apt_packages+=(coreutils) ;; python3) apt_packages+=(python3-minimal) ;; *) apt_packages+=("$tool") ;; esac
  done
  as_root=()
  [ "$(id -u)" = 0 ] || { sudo -n true 2> /dev/null && as_root=(sudo -n); }
  if command -v apt-get > /dev/null && { [ "$(id -u)" = 0 ] || [ ${#as_root[@]} -gt 0 ]; }; then
    echo "apple_sign: putting in ${missing[*]} (apt-get)"
    if ! { "${as_root[@]}" apt-get update -qq > /dev/null \
           && "${as_root[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${apt_packages[@]}" > /dev/null; }; then
      fail "${missing[*]} couldn't be put in"
    fi
  fi
  for tool in "${missing[@]}"; do
    command -v "$tool" > /dev/null || fail "no $tool here"
  done
fi
[ -f "$HERE/apple_profiles.py" ] || fail "apple_profiles.py isn't beside this script"

# The tools, pinned: rcodesign (apple-platform-rs) and dmg (rules_applecross ported-tools).
RCODESIGN_VERSION=0.29.0
DMG_RELEASE=ported-tools-0.0.92
case "$(uname -m)" in
  aarch64|arm64)
    arch=aarch64
    rcodesign_sha=4af92c87ddf52f5f2d1258a3b4e56c7dcb8f1b2468df744976c5f139e031961f
    dmg_sha=e902f3beb581aee24796084d2e2284241e35540a95230e01f5c1899ee61c4d52 ;;
  x86_64)
    arch=x86_64
    rcodesign_sha=dbe85cedd8ee4217b64e9a0e4c2aef92ab8bcaaa41f20bde99781ff02e600002
    dmg_sha=67ee77b978b2b7b0875c9201bb9b09e5a5f716a49450bc53c804a7e2db4866b9 ;;
  *) fail "no pinned tools for $(uname -m)" ;;
esac

# fetch <url> <sha256> <file>
fetch() {
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c --quiet - || fail "$(basename "$3") isn't the pinned $2"
}
mkdir -p "$work/tools"
fetch "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F$RCODESIGN_VERSION/apple-codesign-$RCODESIGN_VERSION-$arch-unknown-linux-musl.tar.gz" \
  "$rcodesign_sha" "$work/rcodesign.tar.gz"
tar -xzf "$work/rcodesign.tar.gz" -C "$work/tools" --strip-components=1
rcodesign="$work/tools/rcodesign"
[ -x "$rcodesign" ] || fail "rcodesign's archive isn't as expected"
if [ -n "$make_dmg" ]; then
  fetch "https://github.com/apple-cross-toolchain/rules_applecross/releases/download/$DMG_RELEASE/dmg-linux-$arch.tar.zst" \
    "$dmg_sha" "$work/dmg.tar.zst"
  zstd -dc "$work/dmg.tar.zst" | tar -x -C "$work/tools"
  dmg="$work/tools/bin/dmg"
  [ -x "$dmg" ] || fail "dmg's archive isn't as expected"
fi

if [ -z "$from_env" ]; then
  # The keys, all or nothing; then their passwords on their own, a password-less .p12 having none kept (a secret is
  # never empty): one the service doesn't hold is an empty file.
  keys=() passwords=()
  for name in "${needed[@]}"; do
    case "$name" in *-password) passwords+=("$name") ;; *) keys+=("$name") ;; esac
  done
  secrets="$("$ROOT/tools/ci/shireworks_retry.sh" secrets-fetch "${keys[@]}")"
  for name in "${passwords[@]}"; do
    folder="$(mktemp -d -p /dev/shm apple-sign-password-XXXXXX)"
    if "$ROOT/tools/ci/shireworks_retry.sh" secrets-fetch "$name" --to="$folder" > /dev/null 2> "$work/password.log"; then
      mv "$folder/$name" "$secrets/$name"
    else
      grep -q "^404\|has no secret" "$work/password.log" || { cat "$work/password.log" >&2; rm -rf "$folder"; fail "$name couldn't be fetched"; }
      (umask 077; : > "$secrets/$name")
    fi
    rm -rf "$folder"
  done
fi
for name in "${needed[@]}"; do
  case "$name" in
    *-password) [ -f "$secrets/$name" ] || fail "no $name" ;;
    *) [ -s "$secrets/$name" ] || fail "no $name" ;;
  esac
done
mkdir -p "$secrets/profiles"
# A .tar or a .tar.gz (GNU tar tells them apart), and the more of them beside it.
for archive in "$secrets"/apple-profiles "$secrets"/apple-profiles-[2-9]; do
  [ -s "$archive" ] || continue
  tar -xf "$archive" -C "$secrets/profiles" --no-same-owner || fail "$(basename "$archive") isn't a .tar or .tar.gz"
done

# certificate <p12> <password file>: the identity's certificate's SHA-1. An empty password file is a password-less
# .p12's: openssl can't read an empty file, so it's given the empty password itself.
certificate() {
  local legacy="" passin="file:$2"
  openssl pkcs12 -help 2>&1 | grep -q -- '-legacy' && legacy="-legacy"
  [ -s "$2" ] || passin="pass:"
  # shellcheck disable=SC2086 # -legacy, or nothing
  openssl pkcs12 $legacy -in "$1" -passin "$passin" -nokeys -clcerts 2> /dev/null \
    | openssl x509 -noout -fingerprint -sha1 2> /dev/null | sed 's/.*=//; s/://g'
}

# p12 <p12> <password file>: rcodesign's arguments for an identity; a password-less one's empty password said as
# such (rcodesign refuses an empty password file), never a password on a command line.
p12() {
  if [ -s "$2" ]; then p12_arguments=(--p12-file "$1" --p12-password-file "$2")
  else p12_arguments=(--p12-file "$1" --p12-password ""); fi
}

if [ -n "$mac" ]; then
  # rcodesign's API key file (what `encode-app-store-connect-api-key` writes), made here from the three files so the
  # key's id and issuer are never on a command line. Its private_key is the key's DER, base64: the .p8's PEM body with
  # its lines joined, as rcodesign makes it of the PEM.
  python3 -I -c '
import json, os, sys
folder = sys.argv[1]
def read(name):
    with open(os.path.join(folder, name)) as file:
        return file.read().strip()
pem = [line.strip() for line in read("apple-notary-key").splitlines()]
body = "".join(line for line in pem if line and not line.startswith("-----"))
if not (pem and pem[0] == "-----BEGIN PRIVATE KEY-----" and body):
    sys.exit("apple_sign: apple-notary-key is not a .p8 (BEGIN PRIVATE KEY)")
key = {"issuer_id": read("apple-notary-issuer"), "key_id": read("apple-notary-key-id"), "private_key": body}
descriptor = os.open(os.path.join(folder, "notary.json"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w") as file:
    json.dump(key, file)' "$secrets"
  developer_id="$(certificate "$secrets/apple-developer-id-p12" "$secrets/apple-developer-id-password")"
  [ -n "$developer_id" ] || fail "apple-developer-id-p12 doesn't open with its password"
fi
if [ -n "$ios" ]; then
  development="$(certificate "$secrets/apple-development-p12" "$secrets/apple-development-password")"
  [ -n "$development" ] || fail "apple-development-p12 doesn't open with its password"
fi
notarize() { "$rcodesign" notary-submit --api-key-file "$secrets/notary.json" --wait --staple "$1"; }

# sign_bundle <app> <mac|ios>: each step apple_profiles.py plans, the deepest code first.
sign_bundle() {
  local app="$1" platform="$2" p12 password sha extra=()
  if [ "$platform" = mac ]; then
    p12="$secrets/apple-developer-id-p12" password="$secrets/apple-developer-id-password" sha="$developer_id"
    extra=(--for-notarization)
  else
    p12="$secrets/apple-development-p12" password="$secrets/apple-development-password" sha="$development"
  fi
  local plan="$work/plan.json"
  rm -rf "$work/entitlements" && mkdir -p "$work/entitlements"
  python3 -I "$HERE/apple_profiles.py" --bundle "$app" --platform "$platform" --profiles "$secrets/profiles" \
    --certificate "$sha" --kind "$ipa_kind" --rcodesign "$rcodesign" --work "$work/entitlements" > "$plan"
  local count index
  count="$(python3 -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))))' "$plan")"
  for ((index = 0; index < count; index++)); do
    local step=()
    mapfile -t step < <(python3 -I -c '
import json, sys
step = json.load(open(sys.argv[1]))[int(sys.argv[2])]
for key in ("path", "bundle", "entitlements", "profile", "embed"):
    value = step[key]
    print("1" if value is True else "" if value in (None, False) else value)' "$plan" "$index")
    local path="${step[0]}" bundle="${step[1]}" entitlements="${step[2]}" profile="${step[3]}" embed="${step[4]}"
    [ -z "$profile" ] || cp "$profile" "$embed"
    p12 "$p12" "$password"
    local arguments=(sign "${p12_arguments[@]}" "${extra[@]}")
    [ -z "$bundle" ] || arguments+=(--shallow)
    [ -z "$entitlements" ] || arguments+=(--entitlements-xml-file "$entitlements")
    "$rcodesign" "${arguments[@]}" "$path" > "$work/sign.log" 2>&1 \
      || { cat "$work/sign.log" >&2; fail "rcodesign couldn't sign ${path#"$work"/}"; }
  done
}

# stamped <app> <Info.plist>: BuildVariant set, the plist's format kept (VariantStamp); a Mac app's stapled ticket
# (Contents/CodeResources) taken out, its signature being made again.
stamped() {
  [ -n "$variant" ] || return 0
  python3 -I -c '
import plistlib, sys
path, variant = sys.argv[1], sys.argv[2]
with open(path, "rb") as file:
    data = file.read()
info = plistlib.loads(data)
info["BuildVariant"] = variant
with open(path, "wb") as file:
    plistlib.dump(info, file, fmt=plistlib.FMT_BINARY if data.startswith(b"bplist00") else plistlib.FMT_XML)' "$2" "$variant"
  rm -f "$1/Contents/CodeResources"
  echo "   BuildVariant: $variant"
}

# unpacked <package> <folder>: unzipped, a ditto zip's AppleDouble files dropped (on a Mac they go back into
# attributes; here they'd be files the signature seals, and a Mac unzipping the result would break it).
unpacked() {
  rm -rf "$2" && mkdir -p "$2"
  (cd "$2" && unzip -q "$1")
  rm -rf "$2/__MACOSX"
  find "$2" -name '._*' -delete
}

for package in "${packages[@]}"; do
  base="$(basename "$package")"
  base="${base%.*}"
  folder="$work/unpacked-$base"
  unpacked "$package" "$folder"
  case "$package" in
    *.ipa)
      apps=("$folder"/Payload/*.app)
      [ ${#apps[@]} -eq 1 ] && [ -d "${apps[0]}" ] || fail "$base.ipa holds ${#apps[@]} apps in its Payload, not one"
      echo "== $base.ipa: signed ($ipa_kind)"
      stamped "${apps[0]}" "${apps[0]}/Info.plist"
      sign_bundle "${apps[0]}" ios
      rm -f "$out/$base.ipa"
      (cd "$folder" && zip -qry -X "$out/$base.ipa" .)
      ;;
    *.zip)
      apps=("$folder"/*.app)
      [ ${#apps[@]} -eq 1 ] && [ -d "${apps[0]}" ] || fail "$base.zip holds ${#apps[@]} apps at its top, not one"
      app="${apps[0]}"
      echo "== $(basename "$app"): signed, notarized, stapled"
      stamped "$app" "$app/Contents/Info.plist"
      sign_bundle "$app" mac
      notarize "$app"
      # Zipped again as ditto would: the app at the top, its links kept (-y).
      rm -f "$out/$base.zip"
      (cd "$folder" && zip -qry -X "$out/$base.zip" "$(basename "$app")")
      if [ -n "$make_dmg" ]; then
        name="$(python3 -I -c '
import plistlib, sys
info = plistlib.load(open(sys.argv[1], "rb"))
print(info.get("CFBundleDisplayName") or info.get("CFBundleName"))' "$app/Contents/Info.plist")"
        image="$work/image-$base"
        mkdir -p "$image"
        mv "$app" "$image/"
        ln -s /Applications "$image/Applications"
        echo "== $base.dmg: made by dmg, signed, notarized, stapled"
        "$dmg" create --volname "$name" --srcfolder "$image" --format UDZO "$out/$base.dmg"
        p12 "$secrets/apple-developer-id-p12" "$secrets/apple-developer-id-password"
        "$rcodesign" sign "${p12_arguments[@]}" --for-notarization "$out/$base.dmg"
        notarize "$out/$base.dmg"
      fi
      ;;
  esac
done
rm -rf "$secrets"
secrets=""
echo "Signed into $out:" && find "$out" -maxdepth 1 -type f -print | sort
