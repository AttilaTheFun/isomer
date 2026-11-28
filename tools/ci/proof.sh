#!/bin/bash
# Isomer's proof, from CI: the Storybook (the Playground's is
# AttilaTheFun/playground's since 0.47) on its tier-1 platforms (PLATFORMS
# below), each with its one renderer (SwiftUI on iOS and the Mac, Compose
# on Android, React on the web), pictured (tools/proof/proof.py), and the
# proof Reviews reads made of them in its format 2
# (tools/ci/proof_write.swift; the private AttilaTheFun/reviews'
# docs/PROOF_FORMAT.md): every picture an item under an id stable from
# release to release (ios/phone/<story>, ios/phone-isomer/<story>,
# macos/window/<story>, android/phone/<story>, web/desktop/<story>), the
# iPhone Storybook on Isomer's frameworks held to Apple's a tests item
# (tests/parity-ios). Nothing is compared across versions here: Reviews
# compares a release's proof with the release before it.
#
# In stages, as CI runs it on GitHub's own machines (free for a public
# repository): built where each platform builds, pictured where it runs,
# then written (.github/workflows/build.yml's proof jobs):
#
#   --stage build --platform <platform>[,<platform>…] --apps <dir> --review <dir>
#       each platform's apps built into <apps>/<platform>/: web in CI's
#       Linux container, ios and macos on a Mac with its Xcode (Apple's
#       SDKs aren't served to Linux: tools/ci/container_build.sh), android
#       for x86_64 on the x86_64 Ubuntu runner (in <apps>/hosted/android/,
#       for that runner's emulator)
#   --stage shoot --platform ios|macos|android|web --apps <dir> --review <dir>
#       (GitHub's runner: `xcode-27` for the iPhone and the Mac, Ubuntu for
#       Android and the web) one platform's apps pictured on that machine
#       (proof.py --here), into <review>
#   --stage compare --parts <dir> --proof <dir>
#       (CI's container) the stages' <review> folders, as subfolders of
#       <parts>, written into the proof
#
# Run only by hand (the Build workflow's workflow_dispatch), to propose a
# release or, after the fact, to bisect a regression. full: every story.
# quick: the app still built on every platform, a core set of stories
# (and every story in a story file a branch touches).
#
# The proof, in <dir>: proof.json (format 2) and its files, screens/<id>.png
# and logs/; the `proof` artifact of the run, and, zipped, the proof.zip a
# proposal's draft carries (alpha). The script fails when the apps don't
# build or a picture doesn't come back.
#
# The builds are proof.py's (--build-to), with Bazel's settings
# tools/ci/ci_bazel.sh wrote for the job. Linux's and Windows' pictures
# (tier 2) are proof.py's alone, run by hand: CI pictures tier 1.
#
#   PROOF_REF           the ref the proof is of (default: GITHUB_REF, else the branch)
#   PROOF_PYTHON        the python3 that runs proof.py, with Pillow, which crops
#                       the desktops' pictures (default: the PATH's python3)
#   PROOF_VERSION       the version the proof is of (default: the Storybook's
#                       committed MAJOR.MINOR.0)
#   GH_TOKEN            gh's token (the job's)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# gh, installed where the image lacks it.
# shellcheck source=tools/ci/gh_ready.sh
. "$ROOT/tools/ci/gh_ready.sh"
# Tier 1 only for now (2026-11-05: the runs take the time; Linux and
# Windows are still built by every CI run, in container_build.sh). proof.py
# still pictures them when named: add them back here.
PLATFORMS="${PROOF_PLATFORMS:-ios macos android web}"

usage() {
    cat >&2 << 'EOF2'
usage: tools/ci/proof.sh --stage build --platform <platform>[,<platform>…] --apps <dir> --review <dir> [--kind quick|full]
       tools/ci/proof.sh --stage shoot --platform <platform> --apps <dir> --review <dir> [--kind quick|full]
       tools/ci/proof.sh --stage compare --parts <dir> --proof <dir> [--kind quick|full]
EOF2
    exit 2
}
stage=""
proof=""
kind="quick"
apps=""
review=""
platform=""
parts=""
while [ $# -gt 0 ]; do
    case "$1" in
        --stage) stage="${2:?--stage takes build, shoot or compare}"; shift 2 ;;
        --proof) proof="${2:?--proof takes a folder}"; shift 2 ;;
        --kind) kind="${2:?--kind takes quick or full}"; shift 2 ;;
        --apps) apps="${2:?--apps takes a folder}"; shift 2 ;;
        --review) review="${2:?--review takes a folder}"; shift 2 ;;
        --platform) platform="${2:?--platform takes a platform}"; shift 2 ;;
        --parts) parts="${2:?--parts takes a folder}"; shift 2 ;;
        *) usage ;;
    esac
done
case "$kind" in quick | full) ;; *) usage ;; esac
absolute() { mkdir -p "$1" && (cd "$1" && pwd); }
case "$stage" in
    build) [ -n "$platform" ] && [ -n "$apps" ] && [ -n "$review" ] || usage ;;
    shoot) [ -n "$platform" ] && [ -n "$apps" ] && [ -n "$review" ] || usage ;;
    compare) [ -n "$parts" ] && [ -n "$proof" ] || usage ;;
    *) usage ;;
esac
[ -z "$proof" ] || proof="$(absolute "$proof")"
[ -z "$apps" ] || apps="$(absolute "$apps")"
[ -z "$review" ] || review="$(absolute "$review")"
[ -z "$parts" ] || parts="$(absolute "$parts")"
# Whether this stage runs a step: `stages build compare && …`.
stages() { case " $* " in *" $stage "*) return 0 ;; esac; return 1; }

cd "$ROOT"
commit="$(git rev-parse HEAD)"
ref="${PROOF_REF:-${GITHUB_REF:-refs/heads/$(git branch --show-current)}}"
repo="${GITHUB_REPOSITORY:-AttilaTheFun/isomer}"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/isomer-proof.XXXXXX")"
started=$SECONDS
phase() { echo "proof.sh: $1 ($((SECONDS - started)) s in)"; }

# What runs long runs in the background, waited for, so a signal's trap
# runs at once (bash runs it only when a foreground command returns).
children=""
background() {
    "$@" &
    local pid=$!
    children="$children $pid"
    wait "$pid"
}
kill_tree() {
    local child
    for child in $(pgrep -P "$1" 2> /dev/null); do kill_tree "$child"; done
    kill "$1" 2> /dev/null || true
}
cleanup() {
    local status=$?
    # The exit's status stands: nothing here may end it otherwise.
    set +e
    for pid in $children; do kill_tree "$pid"; done
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 143' TERM INT

# --- The steps the stages share or have alone (run below as the stage says)

# The review folders under the given roots, each platform's checked for
# pictures, written into the proof (format 2).
compare() {
    local platform
    for platform in $PLATFORMS; do
        if ! find "$@" -maxdepth 2 -type d -name "review-$platform-storybook" 2> /dev/null | grep -q .; then
            echo "::error::no picture of $platform's Storybook"
            status=1
        fi
    done
    "$work/proof_write" "$proof" --app Storybook --version "$version" --repository "$repo" --commit "$commit" \
        ${GITHUB_RUN_ID:+--run "$GITHUB_RUN_ID"} "$@" | tee "$work/summary.md"
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || cat "$work/summary.md" >> "$GITHUB_STEP_SUMMARY"
    phase "done: $(find "$proof/screens" -name '*.png' | wc -l | tr -d ' ') pictures"
}

# --stage build: the platforms' apps built for the stage that pictures
# them. Only ever in a run by hand or a release's (the owner: no proof on
# a push or a pull request), so main's populate never builds them.
build() {
    local here=() wanted
    for wanted in ${platform//,/ }; do
        case "$wanted" in
            ios | macos | web) here+=("$wanted") ;;
            android) ;;
            *) usage ;;
        esac
    done
    echo "::group::The apps, built (tools/proof/proof.py --build-to)"
    if [ ${#here[@]} -gt 0 ]; then
        background "$python" -u "$ROOT/tools/proof/proof.py" "${here[@]}" --build-to "$apps" --review "$review" \
            --commit "$commit" || { echo "::error::the apps didn't build"; exit 1; }
    fi
    if [[ ",$platform," == *",android,"* ]]; then
        background "$python" -u "$ROOT/tools/proof/proof.py" android --android-abi x86_64 \
            --build-to "$apps/hosted" --review "$review" --commit "$commit" ||
            { echo "::error::the Android Storybook (x86_64) didn't build"; exit 1; }
    fi
    echo "::endgroup::"
    phase "built"
}

# --stage shoot, before anything else: what the platform's machine needs.
# Python with Pillow (the machine's own where it has it, as a Nimbus
# runner's image does, else in a venv of the run's), Xcode 27.2 or
# agent-sim's `xcrun simctl` for the simulator, the Mac's screen made the
# proof's 1920 by 1200 (its own is 1024 by 768), an emulator booted on the
# Ubuntu runner's KVM, its Chrome.
shoot_setup() {
    echo "::group::This machine, for $platform's pictures"
    if python3 -c 'import PIL' 2> /dev/null; then
        shoot_python="$(command -v python3)"
    else
        python3 -m venv "$work/venv"
        "$work/venv/bin/pip" install -q pillow
        shoot_python="$work/venv/bin/python3"
    fi
    case "$platform" in
        ios)
            if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode_27.2.app ]; then
                export DEVELOPER_DIR=/Applications/Xcode_27.2.app/Contents/Developer
            fi
            xcrun simctl list runtimes ;;
        macos)
            brew install displayplacer > /dev/null 2>&1 || true
            local screen
            screen="$(displayplacer list 2> /dev/null | sed -n 's/^Persistent screen id: //p' | head -1 || true)"
            # The screen the proof's Mac pictures have always had (1920 by
            # 1200 at 1x), so the apps open their windows at the sizes they
            # always have; else the nearest the runner's display has.
            if [ -z "$screen" ] || ! { displayplacer "id:$screen res:1920x1200 scaling:off origin:(0,0) degree:0" > /dev/null 2>&1 ||
                displayplacer "id:$screen res:1920x1080 scaling:off origin:(0,0) degree:0" > /dev/null 2>&1; }; then
                echo "::warning::the runner's screen stayed as it was (displayplacer)"
            fi
            osascript -l JavaScript -e 'ObjC.import("AppKit"); const f = $.NSScreen.mainScreen.frame; `screen ${f.size.width}x${f.size.height}`' ;;
        android)
            export PROOF_ADB="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}/platform-tools/adb"
            "$ROOT/tools/ci/hosted_android_emulator.sh" "$review/emulator.log" "$work/serial" < /dev/null
            PROOF_ANDROID_SERIAL="$(cat "$work/serial")"
            export PROOF_ANDROID_SERIAL ;;
        web)
            CDP_CHROME="$(command -v google-chrome || command -v google-chrome-stable || command -v chromium || true)"
            [ -n "$CDP_CHROME" ] || { echo "::error::no Chrome on this runner"; exit 1; }
            # Ubuntu 24.04's AppArmor keeps Chrome's sandbox from its user
            # namespaces.
            export CDP_CHROME CDP_CHROME_FLAGS="--no-sandbox ${CDP_CHROME_FLAGS:-}" ;;
        *) usage ;;
    esac
    echo "::endgroup::"
}

# --stage shoot: the platform's apps pictured on this machine.
shoot() {
    local from="$apps"
    # Android's for x86_64, the runner's.
    [ "$platform" != android ] || from="$apps/hosted"
    echo "::group::$platform's apps, pictured here (tools/proof/proof.py --here)"
    background "$python" -u "$ROOT/tools/proof/proof.py" "$platform" --here --from "$from" \
        --review "$review" --commit "$commit" ${quick[@]+"${quick[@]}"} ||
        { echo "::error::$platform: a picture didn't come back"; exit 1; }
    echo "::endgroup::"
    phase "$platform pictured"
}

# What each stage needs on its machine. proof.py's python with Pillow:
# without, its desktops' pictures go uncropped (the clocks, the wallpaper),
# which it only logs.
if stages shoot; then
    shoot_setup
elif [ "$(uname -s)" = Darwin ]; then
    # A Mac building the Apple apps: Pillow in a venv of the run's.
    python3 -m venv "$work/venv"
    "$work/venv/bin/pip" install -q pillow
    shoot_python="$work/venv/bin/python3"
else
    # A Linux container: gh, git, Python with Pillow, unzip.
    echo "::group::The container's tools"
    root_do() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
    packages=(gh git python3 python3-pil unzip)
    root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${packages[@]}" > /dev/null ||
        { root_do apt-get update -qq > /dev/null &&
          root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${packages[@]}" > /dev/null; }
    echo "::endgroup::"
fi
# The proof's writer, for the stage that writes it (a Linux container's).
if stages compare; then
    swiftc -O -o "$work/proof_write" "$ROOT/tools/ci/proof_write.swift"
fi
python="${PROOF_PYTHON:-${shoot_python:-python3}}"
"$python" -c 'import PIL' 2> /dev/null || { echo "::error::$python has no Pillow (PROOF_PYTHON names one that has)"; exit 1; }

quick=()
if [ "$kind" = quick ]; then quick=(--quick --base "origin/${GITHUB_BASE_REF:-main}"); fi
if stages shoot; then
    shoot
    exit 0
fi

if stages build; then
    build
    exit 0
fi

# What the proof is of: the version (the Storybook's committed line's, or
# PROOF_VERSION, a proposal's own).
version="${PROOF_VERSION:-$(sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$ROOT/examples/apple/storybook_ios_application/Info.plist")}"

if stages compare; then
    status=0
    compare "$parts" "$parts"/*
    exit "$status"
fi

usage
