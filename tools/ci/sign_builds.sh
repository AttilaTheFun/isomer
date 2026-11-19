#!/bin/bash
# A publishing job's builds signed and saved as a release's assets, on
# GitHub's own Linux runner, with nothing of the project's own servers: each
# package signed in the job itself by AttilaTheFun/build_tools' `sign`
# (third_party/swift_packages, pinned exact), its keys from the job's GitHub
# environment (`release`: main and v* tags), then its builds.json line
# written from the signed package (tools/ci/release_assets.sh's
# release_asset_file), as Applications and Reviews read a release (the
# private AttilaTheFun/applications' docs/RELEASE_ASSETS.md):
# <App>-<version>-<platform>.<ext> and builds.json, in <out>, for
# tools/ci/attach_release.sh.
#
#   tools/ci/sign_builds.sh --variant Alpha|Production --app <app> --out <dir>
#       [--ipa-kind development|production] [--dmg]
#       [--android-key <name> --android-pin <sha256>] <package>…
#   tools/ci/sign_builds.sh --unsigned --app <app> --out <dir> <package>…
#
# The tools are built before: a step of the job's own with no secret in its
# environment builds //tools/ci_tools:all in the examples' module and writes
# each one's path into the job's environment (BUILD_TOOLS_SIGN,
# BUILD_TOOLS_RCODESIGN, BUILD_TOOLS_DMG, BUILD_TOOLS_JAVA,
# BUILD_TOOLS_APKSIGNER, BUILD_TOOLS_AAPT2), so no Bazel runs here, where
# the keys are (build_tools' README: Bazel's server and its build events
# see its client's environment). `sign` is run directly, never `bazel run`.
#
# - .ipa (the iPhone and iPad app): `sign apple --ipa-kind development`,
#   with APPLE_DEVELOPMENT_P12, APPLE_DEVELOPMENT_PASSWORD (empty or unset:
#   a .p12 with no password) and APPLE_PROFILES. An Alpha's and a release's
#   alike (--ipa-kind production is kept for the workflows' calls): the
#   environment has the development identity alone, and the order the copied
#   apple_sign.sh tried for production (ad hoc, else enterprise, else
#   development) found only development profiles naming it;
# - .zip (a Mac app): `sign apple`, Developer ID, notarized and stapled,
#   with --dmg its disk image too (rules_applecross's dmg), with
#   APPLE_DEVELOPER_ID_P12, APPLE_DEVELOPER_ID_PASSWORD (empty or unset: no
#   password), APPLE_NOTARY_KEY, APPLE_NOTARY_KEY_ID, APPLE_NOTARY_ISSUER and
#   APPLE_PROFILES (an empty one when unset: a Mac app with no profile of its
#   own needs none);
# - .apk: `sign android` with the release key --android-key names, its
#   certificate pinned (--android-pin), with ANDROID_SIGNING_KEYSTORE and
#   ANDROID_SIGNING_PASSWORD; the JDK and apksigner.jar the examples' Bazel
#   pins (@hermetic_jdk, @android_build_tools), and its builds.json line read
#   with that build-tools' aapt2. On an x86_64 Linux alone: the JDK and build
#   tools Bazel has for Linux are x86_64.
#
# Production (a release's promotion): each Apple package's BuildVariant made
# Production by `sign apple --variant` as it is signed again (a Mac app's
# stapled ticket dropped first, as Shireworks' signing service's promotion
# does); an .apk is the release's own production build (--config=prod), its
# line Production.
# APPLE_PROFILES may be a gzipped .tar (GitHub caps a secret at 48 KB), as
# `sign apple` reads it.
#
# A platform whose secrets aren't all set is skipped, with a warning in the
# log and the job's summary, never failing the job: a fork, or a
# repository whose keys aren't all in yet, still proposes with what it can
# sign. Nothing unsigned is saved. --unsigned (an experiment's, which no
# environment's keys reach from a branch) saves the packages as built.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI="$ROOT/tools/ci"
fail() { echo "sign_builds: $*" >&2; exit 1; }
usage="usage: tools/ci/sign_builds.sh --variant Alpha|Production --app <app> --out <dir> [--ipa-kind development|production] [--dmg] [--android-key <name> --android-pin <sha256>] <package>…"

variant="" app="" out="" ipa_kind="development" dmg="" android_key="" android_pin="" unsigned=""
packages=()
while [ $# -gt 0 ]; do
    case "$1" in
        --variant) variant="${2:?}"; shift 2 ;;
        --app) app="${2:?}"; shift 2 ;;
        --out) out="${2:?}"; shift 2 ;;
        --ipa-kind) ipa_kind="${2:?}"; shift 2 ;;
        --dmg) dmg=1; shift ;;
        --android-key) android_key="${2:?}"; shift 2 ;;
        --android-pin) android_pin="${2:?}"; shift 2 ;;
        --unsigned) unsigned=1; shift ;;
        -*) fail "unknown option $1; $usage" ;;
        *) packages+=("$1"); shift ;;
    esac
done
[ -n "$app" ] && [ -n "$out" ] && [ ${#packages[@]} -gt 0 ] || fail "$usage"

# The keys, taken out of the environment before anything else runs: each
# value kept in an unexported variable of this shell (secret_<NAME>) and its
# NAME unset, so no child (Bazel and its repository rules, Python, aapt2,
# curl) ever has them. A signer gets the keys it needs alone, exported in a
# subshell of its own by `export`, a builtin (with_secrets): no value is ever
# a process's argument (/proc/<pid>/cmdline), and nothing here prints one or
# runs under `set -x`.
SECRETS=(ANDROID_SIGNING_KEYSTORE ANDROID_SIGNING_PASSWORD APPLE_DEVELOPER_ID_P12 APPLE_DEVELOPER_ID_PASSWORD
         APPLE_NOTARY_KEY APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER APPLE_DEVELOPMENT_P12 APPLE_DEVELOPMENT_PASSWORD
         APPLE_PROFILES APPLE_PROFILES_2 APPLE_PROFILES_3 APPLE_PROFILES_4 APPLE_PROFILES_5 APPLE_PROFILES_6
         APPLE_PROFILES_7 APPLE_PROFILES_8 APPLE_PROFILES_9)
set +x
for name in "${SECRETS[@]}"; do
    printf -v "secret_$name" '%s' "${!name:-}"
    unset "$name"
done
[ -n "$unsigned" ] || case "$variant" in Alpha | Production) ;; *) fail "--variant is Alpha or Production" ;; esac
case "$ipa_kind" in development | production) ;; *) fail "--ipa-kind is development or production" ;; esac
mkdir -p "$out"
out="$(cd "$out" && pwd)"
# A tool built before this step (above), by its BUILD_TOOLS_<NAME>.
built() {
    local name="BUILD_TOOLS_$1"
    [ -n "${!name:-}" ] && [ -e "${!name}" ] || fail "no $1: $name names none (the workflow's step building //tools/ci_tools)"
    printf '%s' "${!name}"
}
# shellcheck source=tools/ci/release_assets.sh
. "$CI/release_assets.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ipas=() zips=() apks=()
for package in "${packages[@]}"; do
    [ -f "$package" ] || fail "no such file: $package"
    package="$(cd "$(dirname "$package")" && pwd)/$(basename "$package")"
    case "$package" in
        *.ipa) ipas+=("$package") ;;
        *.zip) zips+=("$package") ;;
        *.apk) apks+=("$package") ;;
        *) fail "$(basename "$package") is not an .ipa, a Mac app's .zip or an .apk" ;;
    esac
done

skipped=()
skip() {
    echo "::warning::sign_builds: $1 not signed: $2 not set in the job's environment"
    skipped+=("$1 ($2)")
}
# Whether every named key was set, else the first that wasn't.
missing() {
    local name kept
    for name in "$@"; do
        kept="secret_$name"
        [ -n "${!kept}" ] || { echo "$name"; return 0; }
    done
    return 1
}
# A signer run with the named keys alone in its environment:
#   with_secrets <NAME>… -- <command>…
# In a subshell, each named key exported from its kept value by `export`
# (a builtin, so no value is an argument of any process), then the command
# exec'd in its place. The other keys were never in the environment.
with_secrets() {
    local keep=()
    while [ "$1" != -- ]; do keep+=("$1"); shift; done
    shift
    (
        for name in "${keep[@]}"; do
            kept="secret_$name"
            [ -z "${!kept}" ] || export "$name=${!kept}"
        done
        exec "$@"
    )
}

if [ -n "$unsigned" ]; then
    for package in ${ipas[@]+"${ipas[@]}"} ${zips[@]+"${zips[@]}"}; do
        release_asset_file "$package" "$out" "$app"
    done
    [ ${#apks[@]} -eq 0 ] || fail "--unsigned takes Apple packages alone"
    exit 0
fi

# A release's Apple packages made Production as they are signed.
promote=()
[ "$variant" != Production ] || promote=(--variant Production)
# APPLE_PROFILES as `sign apple` reads it (a .tar or .tar.gz, base64;
# APPLE_PROFILES_2 … _9 beside it, where they are set): an empty .tar when
# unset, which a Mac app with no profile of its own signs with.
profiles_or_empty() {
    if [ -z "$secret_APPLE_PROFILES" ]; then
        tar -cf "$work/profiles.tar" -T /dev/null
        secret_APPLE_PROFILES="$(base64 < "$work/profiles.tar" | tr -d '\n')"
    fi
}
PROFILES=(APPLE_PROFILES APPLE_PROFILES_2 APPLE_PROFILES_3 APPLE_PROFILES_4 APPLE_PROFILES_5 APPLE_PROFILES_6
          APPLE_PROFILES_7 APPLE_PROFILES_8 APPLE_PROFILES_9)

if [ ${#ipas[@]} -gt 0 ]; then
    # Its .p12's password may be empty (a .p12 exported with none), passed
    # on as unset, which `sign apple` takes for no password.
    if name="$(missing APPLE_DEVELOPMENT_P12 APPLE_PROFILES)"; then
        skip "the iPhone app" "$name"
    else
        sign="$(built SIGN)" rcodesign="$(built RCODESIGN)"
        # Development, whichever was asked (above).
        with_secrets APPLE_DEVELOPMENT_P12 APPLE_DEVELOPMENT_PASSWORD "${PROFILES[@]}" -- \
            "$sign" apple --key-from-env --rcodesign "$rcodesign" --ipa-kind development \
            ${promote[@]+"${promote[@]}"} --out "$work/signed-ios" "${ipas[@]}"
        for package in "${ipas[@]}"; do
            release_asset_file "$work/signed-ios/$(basename "$package")" "$out" "$app"
        done
    fi
fi

if [ ${#zips[@]} -gt 0 ]; then
    if name="$(missing APPLE_DEVELOPER_ID_P12 APPLE_NOTARY_KEY APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER)"; then
        skip "the Mac app" "$name"
    else
        profiles_or_empty
        sign="$(built SIGN)" rcodesign="$(built RCODESIGN)"
        disk_image=()
        if [ -n "$dmg" ]; then
            dmg_tool="$(built DMG)"
            disk_image=(--dmg "$dmg_tool")
        fi
        with_secrets APPLE_DEVELOPER_ID_P12 APPLE_DEVELOPER_ID_PASSWORD APPLE_NOTARY_KEY \
            APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER "${PROFILES[@]}" -- \
            "$sign" apple --key-from-env --rcodesign "$rcodesign" ${disk_image[@]+"${disk_image[@]}"} \
            ${promote[@]+"${promote[@]}"} --out "$work/signed-mac" "${zips[@]}"
        for package in "${zips[@]}"; do
            signed="$work/signed-mac/$(basename "$package")"
            release_asset_file "$signed" "$out" "$app"
            # The disk image, described by its app's .zip.
            [ -z "$dmg" ] || release_asset_file "${signed%.zip}.dmg" "$out" "$app" "$signed"
        done
    fi
fi

if [ ${#apks[@]} -gt 0 ]; then
    if name="$(missing ANDROID_SIGNING_KEYSTORE ANDROID_SIGNING_PASSWORD)"; then
        skip "the Android app" "$name"
    else
        [ -n "$android_key" ] && [ -n "$android_pin" ] || fail "an .apk takes --android-key and --android-pin"
        # The examples' pinned JDK and build tools, built before (above).
        sign="$(built SIGN)" java="$(built JAVA)" apksigner="$(built APKSIGNER)" aapt2="$(built AAPT2)"
        for package in "${apks[@]}"; do
            signed="$work/signed-android/$(basename "$package")"
            mkdir -p "$work/signed-android"
            with_secrets ANDROID_SIGNING_KEYSTORE ANDROID_SIGNING_PASSWORD -- \
                "$sign" android --key-from-env --app "$android_key" --pin "$android_pin" \
                --java "$java" --apksigner "$apksigner" "$package" "$signed"
            # Its line as Shireworks' signing service answered for an APK
            # (release_asset_answer_describe): the package, its version and
            # versionCode and its label, from its manifest (aapt2), the
            # variant the job's.
            "$aapt2" dump badging "$signed" > "$work/badging.txt" || fail "aapt2 doesn't read $(basename "$signed")"
            python3 -I - "$work/badging.txt" "$variant" > "$work/answer.json" << 'PY'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
def field(pattern):
    found = re.search(pattern, text, re.M)
    return found.group(1) if found else ""
package = field(r"^package: name='([^']*)'")
if not package:
    sys.exit("sign_builds: aapt2 names no package")
build = {"platform": "android", "name": field(r"^application-label:'([^']*)'") or package,
         "version": field(r"versionName='([^']*)'"), "buildNumber": field(r"versionCode='([^']*)'"),
         "variant": sys.argv[2], "urlSchemes": []}
json.dump({"bundleID": package, "channel": "production" if sys.argv[2] == "Production" else "beta", "build": build}, sys.stdout)
PY
            release_asset_file "$signed" "$out" "$app" "$work/answer.json"
        done
    fi
fi

# A builds.json however little was signed, so the draft is made and says so.
[ -f "$out/builds.json" ] || echo '[]' > "$out/builds.json"
if [ ${#skipped[@]} -gt 0 ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### Builds not signed"
        echo
        for line in "${skipped[@]}"; do echo "- $line"; done
    } >> "$GITHUB_STEP_SUMMARY"
fi
echo "sign_builds: into $out:"
ls -l "$out"
