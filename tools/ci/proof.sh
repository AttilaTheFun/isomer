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
#   tools/ci/proof.sh --proof <dir> [--kind quick|full]
#
# Or in stages, as a public repository's CI runs it: built in CI's own
# Linux container, pictured on GitHub's own machines (free for a public
# repository), then written (.github/workflows/build.yml's proof jobs):
#
#   --stage build --apps <dir> --review <dir>
#       (CI's container) every app built into <apps>/<platform>/ (the
#       Android Storybook for x86_64, in <apps>/hosted/android/, for the
#       Ubuntu runner's emulator)
#   --stage prebuild --apps <dir> --review <dir>
#       (main's populate) the same builds, nothing pictured: so a release's
#       proof finds its actions in Bazel's cache
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
# The builds: proof.py's, in CI's own Linux container (the isomer-jit
# runners: the Apple apps with rules_applecross, the SDK archive from Shireworks'
#  files; Android's, the web's, its pictures in Chrome for Testing
# there), or on a Mac with its Xcode and Chrome when run by hand there.
# Linux's (when PROOF_PLATFORMS names it) are packaged in the same container;
# Windows' are built on its VM.
#
#   PROOF_REF           the ref the proof is of (default: GITHUB_REF, else the branch)
#   PROOF_PYTHON        the python3 that runs proof.py, with Pillow, which crops
#                       the desktops' pictures (default: the PATH's python3)
#   PROOF_VERSION       the version the proof is of (default: the Storybook's
#                       committed MAJOR.MINOR.0)
#   PROOF_MAC           vm: the Mac's pictures on a macOS VM of their own, as
#                       before 2026-11-03 (default: a slot of Shireworks' primary)
#   SHIREWORKS_FILES_HOST  the name Shireworks' files are reached by (default:
#                       the server tools/ci/shireworks.sh files-url names)
#   GH_TOKEN            gh's token (the job's)
#
# Every lease is released however the script ends: proof.py's own as it
# finishes, and on a cancel (the job's `exec` brings the runner's signal
# here) every lease labelled with this job.
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
usage: tools/ci/proof.sh --proof <dir> [--kind quick|full]
       tools/ci/proof.sh --stage build --apps <dir> --review <dir> [--kind quick|full]
       tools/ci/proof.sh --stage prebuild --apps <dir> --review <dir>
       tools/ci/proof.sh --stage shoot --platform <platform> --apps <dir> --review <dir> [--kind quick|full]
       tools/ci/proof.sh --stage compare --parts <dir> --proof <dir> [--kind quick|full]
EOF2
    exit 2
}
stage="all"
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
    all) [ -n "$proof" ] || usage ;;
    build | prebuild) [ -n "$apps" ] && [ -n "$review" ] || usage ;;
    shoot) [ -n "$platform" ] && [ -n "$apps" ] && [ -n "$review" ] || usage ;;
    compare) [ -n "$parts" ] && [ -n "$proof" ] || usage ;;
    *) usage ;;
esac
[ -z "$proof" ] || proof="$(absolute "$proof")"
[ -z "$apps" ] || apps="$(absolute "$apps")"
[ -z "$review" ] || review="$(absolute "$review")"
[ -z "$parts" ] || parts="$(absolute "$parts")"
# Whether this stage runs a step: `stages all build && …`.
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
release_ours() {
    # This job's leases, by the label Shireworks gives a CI job's ("… #<run> · <job>").
    [ -n "${GITHUB_RUN_ID:-}" ] && [ -n "${GITHUB_JOB:-}" ] || return 0
    # None where there is no Shireworks (GitHub's own machines).
    [ -n "${SHIREWORKS_GRANT:-}${SHIREWORKS_SERVERS:-}" ] || return 0
    { "$ROOT/tools/ci/shireworks.sh" list --label=" #$GITHUB_RUN_ID · $GITHUB_JOB" 2> /dev/null || true; } | cut -d' ' -f1 | while read -r id; do
        [ -n "$id" ] || continue
        "$ROOT/tools/ci/shireworks.sh" release "$id" > /dev/null 2>&1 && echo "proof.sh: released $id" || true
    done
}
cleanup() {
    local status=$?
    # The exit's status stands: nothing here may end it otherwise.
    set +e
    for pid in $children; do kill_tree "$pid"; done
    # A lease asked for as it was stopped may land a moment later.
    release_ours
    sleep 3
    release_ours
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

# --stage build (and prebuild): every app built for the stages that
# picture them elsewhere.
build() {
    echo "::group::The apps, built (tools/proof/proof.py --build-to)"
    background "$python" -u "$ROOT/tools/proof/proof.py" ios macos web --build-to "$apps" --review "$review" \
        --commit "$commit" || { echo "::error::the apps didn't build"; exit 1; }
    background "$python" -u "$ROOT/tools/proof/proof.py" android --android-abi x86_64 \
        --build-to "$apps/hosted" --review "$review" --commit "$commit" ||
        { echo "::error::the Android Storybook (x86_64) didn't build"; exit 1; }
    echo "::endgroup::"
    phase "built"
}

# --stage shoot, before anything else: what the platform's machine needs.
# GitHub's runners: Python's own (Pillow in a venv of the run's), Xcode
# 27.2 for the simulator, the Mac's screen made Shireworks' slots' (its own
# is 1024 by 768), an emulator booted on the Ubuntu runner's KVM, its Chrome.
shoot_setup() {
    echo "::group::This machine, for $platform's pictures"
    python3 -m venv "$work/venv"
    "$work/venv/bin/pip" install -q pillow
    shoot_python="$work/venv/bin/python3"
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
            # Shireworks' mac slots' screen (1920 by 1200 at 1x), so the
            # apps open their windows at the sizes they open there; else
            # the nearest the runner's display has.
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

# The tools first: nothing leased if one doesn't build. proof.py's python
# with Pillow: without, its desktops' pictures go uncropped (the clocks,
# the wallpaper), which it only logs.
# In CI the job's own container (the isomer-jit runners: Shireworks'
# single-use Linux containers) builds and pictures, in place; on a Mac
# (Shireworks' own) it builds with the Mac's Xcode.
inside=""
[ "$(uname -s)" = Darwin ] || inside=1
stages shoot && inside=""
if stages shoot; then
    shoot_setup
elif [ -n "$inside" ]; then
    # Where Shireworks' files are: the URL shireworks.sh gives a file (its
    # server and port), or SHIREWORKS_FILES_HOST's port 7490.
    sdk="$(sed -n 's/^SDK_SHA256="\(.*\)"/\1/p' "$ROOT/tools/ci/container_build.sh")"
    if [ -n "${SHIREWORKS_FILES_HOST:-}" ]; then
        files="http://$SHIREWORKS_FILES_HOST:7490/files/sha256"
    else
        files="$("$ROOT/tools/ci/shireworks.sh" files-url "$sdk")" ||
            { echo "::error::no Shireworks to take files from: set SHIREWORKS_FILES_HOST (or SHIREWORKS_GRANT or SHIREWORKS_SERVERS)"; exit 1; }
        files="${files%/*}"
    fi
    echo "::group::The container's tools"
    root_do() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
    # gh; Python with Pillow for proof.py;
    # what Chrome for Testing loads; unzip.
    packages=(gh git python3 python3-pil unzip libnss3 libasound2t64 libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2
              libpango-1.0-0 libcairo2 libcups2t64 libdrm2 libgbm1 fonts-dejavu-core)
    root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${packages[@]}" > /dev/null ||
        { root_do apt-get update -qq > /dev/null &&
          root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${packages[@]}" > /dev/null; }
    # The Apple targets' toolchains and SDK archive (Shireworks' files),
    # for every Bazel command in the examples (proof.py's).
    cat > "$work/downloader.cfg" <<EOF2
rewrite apple-sdks\.invalid/.* $files/$sdk
rewrite ported-tools\.invalid/sha256/(.*) $files/\$1
rewrite windows-sdks\.invalid/sha256/(.*) $files/\$1
EOF2
    printf 'build --config=apple_on_linux\ncommon --downloader_config=%s\n' "$work/downloader.cfg" > "$ROOT/examples/.bazelrc.user"
    # The web's pictures in Chrome for Testing (MODULE.bazel), for cdp.py,
    # when they are taken here (the stages take them on GitHub's runner).
    if stages all; then
        case "$(uname -m)" in aarch64 | arm64) chrome=chrome_linux_arm64 ;; *) chrome=chrome_linux_x86_64 ;; esac
        (cd "$ROOT/examples" && bazel build "@$chrome//:files" > /dev/null)
        export CDP_CHROME="$(cd "$ROOT/examples" && echo "$(bazel info output_base)/$(bazel cquery --output=files "@$chrome//:chrome" 2> /dev/null)")"
        [ -x "$CDP_CHROME" ] || { echo "::error::no Chrome for Testing at $CDP_CHROME"; exit 1; }
        # A container has no user namespaces for Chrome's own sandbox.
        export CDP_CHROME_FLAGS="--no-sandbox ${CDP_CHROME_FLAGS:-}"
    fi
    echo "::endgroup::"
    swiftc -O -o "$work/proof_write" "$ROOT/tools/ci/proof_write.swift"
else
    xcrun swiftc -O -o "$work/proof_write" "$ROOT/tools/ci/proof_write.swift"
fi
python="${PROOF_PYTHON:-${shoot_python:-python3}}"
"$python" -c 'import PIL' 2> /dev/null || { echo "::error::$python has no Pillow (PROOF_PYTHON names one that has)"; exit 1; }

quick=()
if [ "$kind" = quick ]; then quick=(--quick --base "origin/${GITHUB_BASE_REF:-main}"); fi
if stages shoot; then
    shoot
    exit 0
fi

if stages build prebuild; then
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

echo "::group::The Linux apps, packaged"
# In the job's own Linux container (the packages come out under .ci/).
linux_packages=()
if [[ " $PLATFORMS " == *" linux "* ]]; then
    [ -n "$inside" ] || { echo "::error::the Linux apps are packaged in a Linux container (CI's): not on a Mac"; exit 1; }
    linux="$ROOT/.ci/proof-linux"
    rm -rf "$linux" && mkdir -p "$linux"
    steps='
    set -e
    root=$1 out=$2
    cd "$root/examples"
    bazel build -c opt --experimental_convenience_symlinks=ignore \
        //linux/storybook_linux_application:storybook_linux_application_bin
    linux/storybook_linux_application/package.sh /root/storybook-linux -c opt
    tar -czf "$out/storybook-linux.tgz" -C /root storybook-linux
    '
    background bash -c "$steps" proof "$ROOT" "$linux" || { echo "::error::the Linux apps didn't build"; exit 1; }
    echo "::endgroup::"
    phase "Linux packaged"
    linux_packages=(--linux-packages "$linux")
fi

echo "::group::The apps on every platform (tools/proof/proof.py)"
status=0
# shellcheck disable=SC2086
background "$python" -u "$ROOT/tools/proof/proof.py" $PLATFORMS --review "$work/review" --commit "$commit" \
    ${linux_packages[@]+"${linux_packages[@]}"} ${quick[@]+"${quick[@]}"} \
    || { echo "::error::tools/proof/proof.py: a build failed or a picture didn't come back"; status=1; }
echo "::endgroup::"
phase "pictured"

compare "$work/review"
exit "$status"
