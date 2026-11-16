#!/bin/bash
# An Android app's release APK signed with its private release key, in the
# CI job's own container (docs/secrets.md; Logan, 2026-11-15: signing is
# hermetic, keys from Shireworks' secret service, one per package, pinned).
# Every repository's CI copies this file byte for byte from
# AttilaTheFun/shireworks, as it does shireworks.sh.
#
#   tools/ci/android_sign.sh --app <app> --pin <sha256> --java <java> --apksigner <apksigner.jar> [--key-from-env] <in.apk> <out.apk>
#
# - --app: the key's name: its secrets are android-<app>-keystore (PKCS12,
#   its alias <app>) and android-<app>-password, released to this job when
#   the repository's .github/shireworks-secrets.json declares them for it;
# - --pin: the release certificate's SHA-256 (hex, colons or not), from the
#   workflow (code-owned): the signed APK's certificate must be it, so a key
#   swapped in the store signs nothing;
# - --java, --apksigner: the repository's own pinned tools (Isomer's
#   hermetic JDK and @android_build_tools' lib/apksigner.jar), never the
#   image's;
# - <in.apk>: the release build, zipaligned (its build's own signature, a
#   debug key's, is replaced); <out.apk>: the same, signed with APK Signature
#   Schemes v2 and v3 (v1 as the APK's minSdkVersion wants it).
#
# The key and its password go into a folder of their own on a tmpfs, are
# used, and are removed however the script ends; neither is ever printed.
# They come from:
# - Shireworks' secret service (a private repository's job on Shireworks'
#   runners: `shireworks.sh secrets-fetch`), with `permissions: id-token:
#   write` and the runner's SHIREWORKS_GRANT; or,
# - with --key-from-env (a public repository's job on GitHub's runners,
#   Logan 2026-11-15), ANDROID_SIGNING_KEYSTORE (the PKCS12, base64) and
#   ANDROID_SIGNING_PASSWORD, from its GitHub environment's secrets; read
#   once, then unset.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "android_sign: $*" >&2; exit 1; }
usage="usage: tools/ci/android_sign.sh --app <app> --pin <sha256> --java <java> --apksigner <apksigner.jar> [--key-from-env] <in.apk> <out.apk>"

app="" pin="" java="" apksigner="" from_env=""
files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --app) app="${2:?--app takes the name of the key}"; shift 2 ;;
    --pin) pin="${2:?--pin takes the SHA-256 of the certificate}"; shift 2 ;;
    --java) java="${2:?--java takes the java of a JDK}"; shift 2 ;;
    --apksigner) apksigner="${2:?--apksigner takes apksigner.jar}"; shift 2 ;;
    --key-from-env) from_env=1; shift ;;
    -*) fail "unknown option $1" ;;
    *) files+=("$1"); shift ;;
  esac
done
[ -n "$app" ] && [ -n "$pin" ] && [ -n "$java" ] && [ -n "$apksigner" ] && [ ${#files[@]} -eq 2 ] || fail "$usage"
input="${files[0]}" output="${files[1]}"
[[ "$app" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || fail "--app is the key's name: lowercase letters, digits and -"
pin="$(printf '%s' "$pin" | tr -d ': ' | tr 'A-F' 'a-f')"
[[ "$pin" =~ ^[0-9a-f]{64}$ ]] || fail "--pin is a SHA-256: 64 hex digits"
[ -f "$input" ] || fail "no such APK: $input"
[ -x "$java" ] || fail "no java at $java"
[ -f "$apksigner" ] || fail "no apksigner.jar at $apksigner"

secrets=""
work="$(mktemp -d)"
cleanup() {
  [ -z "$secrets" ] || rm -rf "$secrets"
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "$from_env" ]; then
  [ -n "${ANDROID_SIGNING_KEYSTORE:-}" ] && [ -n "${ANDROID_SIGNING_PASSWORD:-}" ] \
    || fail "--key-from-env: ANDROID_SIGNING_KEYSTORE and ANDROID_SIGNING_PASSWORD aren't both set"
  [ -d /dev/shm ] || fail "no /dev/shm here: the key is written to a tmpfs alone"
  secrets="$(mktemp -d -p /dev/shm android-sign-XXXXXX)"
  chmod 700 "$secrets"
  (umask 077
   printf '%s' "$ANDROID_SIGNING_KEYSTORE" | base64 -d > "$secrets/android-$app-keystore"
   printf '%s' "$ANDROID_SIGNING_PASSWORD" > "$secrets/android-$app-password") \
    || fail "ANDROID_SIGNING_KEYSTORE isn't base64"
  unset ANDROID_SIGNING_KEYSTORE ANDROID_SIGNING_PASSWORD
else
  secrets="$("$ROOT/tools/ci/shireworks_retry.sh" secrets-fetch "android-$app-keystore" "android-$app-password")"
fi
[ -s "$secrets/android-$app-keystore" ] && [ -f "$secrets/android-$app-password" ] || fail "no key for $app"

# apksigner reads the password from its file (`file:`, the whole first line), never the command line.
"$java" -jar "$apksigner" sign \
  --ks "$secrets/android-$app-keystore" --ks-type PKCS12 --ks-key-alias "$app" \
  --ks-pass "file:$secrets/android-$app-password" \
  --v2-signing-enabled true --v3-signing-enabled true \
  --out "$work/signed.apk" "$input"
rm -rf "$secrets"
secrets=""

# Checked as Android checks it, and against the pin.
"$java" -jar "$apksigner" verify --verbose --print-certs "$work/signed.apk" > "$work/verify.txt" \
  || { cat "$work/verify.txt" >&2; fail "apksigner doesn't verify the signed APK"; }
grep -q '^Verified using v3 scheme (APK Signature Scheme v3): true' "$work/verify.txt" || fail "the signed APK has no v3 signature"
# Android 9 and later verify v3 alone, so the v2 block is read as Android 7 and 8 would (the build's own minSdkVersion aside).
"$java" -jar "$apksigner" verify --verbose --min-sdk-version 24 --max-sdk-version 27 "$work/signed.apk" > "$work/verify-v2.txt" \
  || { cat "$work/verify-v2.txt" >&2; fail "apksigner doesn't verify the signed APK's v2 signature"; }
grep -q '^Verified using v2 scheme (APK Signature Scheme v2): true' "$work/verify-v2.txt" || fail "the signed APK has no v2 signature"
signers="$(grep -c '^Signer #[0-9]* certificate SHA-256 digest:' "$work/verify.txt" || true)"
[ "$signers" = "1" ] || fail "the signed APK has $signers signers, not one"
digest="$(sed -n 's/^Signer #1 certificate SHA-256 digest: *//p' "$work/verify.txt" | tr -d ': ' | tr 'A-F' 'a-f')"
[ "$digest" = "$pin" ] || fail "the signing key isn't $app's: its certificate is $digest, not the pinned $pin"

mkdir -p "$(dirname "$output")"
mv "$work/signed.apk" "$output"
echo "Signed: $(basename "$output") ($app's release key, certificate $digest)"
