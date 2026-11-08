#!/bin/bash
# Isomer's proof, from CI: its two apps (the Storybook, the Playground) on
# its tier-1 platforms (PLATFORMS below), each with its one renderer (SwiftUI
# on iOS and the Mac, Compose on Android, React on the web), pictured on machines leased from OS Server (tools/proof/proof.py),
# each picture compared with the base's, and the `proof` artifact Reviews
# reads made of them (tools/ci/proof_compare.swift).
#
#   tools/ci/proof.sh --proof <dir> [--kind quick|full]
#
# Or in stages, as a public repository's CI runs it: built in CI's own
# Linux container, pictured on GitHub's own machines (free for a public
# repository), then compared (.github/workflows/build.yml's proof jobs):
#
#   --stage build --apps <dir> --review <dir>
#       (CI's container) every app built into <apps>/<platform>/ (the
#       Android Storybook for x86_64, in <apps>/hosted/android/, for the
#       Ubuntu runner's emulator), and the Android Playground pictured here,
#       on an emulator leased from OS Server, into <review>: its compiler,
#       built into the app, is arm64's alone
#   --stage shoot --platform ios|macos|android|web --apps <dir> --review <dir>
#       (GitHub's runner: `xcode-27` for the iPhone and the Mac, Ubuntu for
#       Android and the web) one platform's apps pictured on that machine
#       (proof.py --here), into <review>
#   --stage compare --parts <dir> --proof <dir>
#       (CI's container) the stages' <review> folders, as subfolders of
#       <parts>, compared with the baseline into the proof
#
# Run only by hand (the Build workflow's workflow_dispatch), to propose a
# release or, after the fact, to bisect a regression. full: every story.
# quick: both apps still built on every platform, a core set of stories
# (and every story in a story file a branch touches), and the Playground's
# screens.
#
# The baseline is the base's pictures, never the change's own:
#   a commit on main (run on main, or on a branch pushed at a commit of
#     main's, to prove it after the fact): the previous release's (the
#     newest release tag before it), else the newest commit before it with
#     one;
#   a branch's own commits: its base branch's proof, of the newest commit
#     there at or before the one the branch parted from;
#   a release: the previous release's run (else its commit's on main);
#   PROOF_BASELINE_RUN: a run of this workflow whose proof to compare with
#     instead (how a second run of one commit shows it held still).
# Each is a release's proof.tar.gz asset (tools/ci/release_assets.sh) when
# the base is a release that has one, else the `proof` artifact of a run of
# this workflow (kept 90 days), fetched with gh. The pictures aren't kept in the repository: a full proof
# is about 720 of them, some 300 MB, and every visible change would rewrite
# some. A screen the baseline has no picture of is new, and changed.
#
# The proof, in <dir>:
#   screens/<name>.png  every picture: <platform>-<app>-<screen>
#                       (ios-storybook-navigation.links, web-playground-pokedex)
#   before/<name>.png   the baseline's picture of each that changed
#   diffs/<name>.png    each that changed, its changed pixels red
#   proof.json          {"commit", "ref", "kind", "run", "base": {"ref", "commit"},
#                        "screens": [{"name", "changed", "changedPixels"}]}
# A pixel counts as changed by more than 24 in a channel, and never in a
# region tools/ci/proof_ignore.txt names (what a platform draws differently
# from run to run however it's held, with why). The script fails when the
# apps don't build or a picture doesn't come back; pictures that changed
# are for review, not failures.
#
# The builds: proof.py's, in CI's own Linux container (the isomer-jit
# runners: the Apple apps with rules_applecross, the SDK archive from OS
# Server's files; Android's, the web's, its pictures in Chrome for Testing
# there), or on a Mac with its Xcode and Chrome when run by hand there.
# Linux's (when PROOF_PLATFORMS names it) are packaged in a container leased
# from OS Server; Windows' are built on its VM. The Playground's compilers that Bazel doesn't make:
# the iPhone simulator's, Android's, the Mac's and the browser's, staged
# from OS Server's files (tools/ci/stage_playground_compilers.sh).
#
#   PROOF_REF           the ref the proof is of (default: GITHUB_REF, else the branch)
#   PROOF_PYTHON        the python3 that runs proof.py, with Pillow, which crops
#                       the desktops' pictures (default: the PATH's python3)
#   PROOF_BASELINE_RUN  a run whose proof is the baseline (above)
#   PROOF_MAC           vm: the Mac's pictures on a macOS VM of their own, as
#                       before 2026-11-03 (default: a slot of OS Server's primary)
#   OSS_FILES_HOST      the name OS Server's files are reached by (default: the
#                       first of OSS_SERVERS, else this Mac's tailnet name)
#   GH_TOKEN            gh's token (the job's)
#
# Every lease is released however the script ends: proof.py's own as it
# finishes, and on a cancel (the job's `exec` brings the runner's signal
# here) every lease labelled with this job.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="$(cat "$ROOT/tools/ci/agent_image")"
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
    # This job's leases, by the label OS Server gives a CI job's ("… #<run> · <job>").
    [ -n "${GITHUB_RUN_ID:-}" ] && [ -n "${GITHUB_JOB:-}" ] || return 0
    { oss machine list 2> /dev/null | grep -F " #$GITHUB_RUN_ID · $GITHUB_JOB" || true; } | awk '{ print $1 }' | while read -r id; do
        oss machine release "$id" > /dev/null 2>&1 && echo "proof.sh: released $id" || true
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

# Every picture of the review folders under the given roots, named for its
# platform, app and screen (review-ios-storybook/navigation.links.png is
# ios-storybook-navigation.links; the iPhone's compiled Storybook's
# references and diffs against Apple's are its own review's, not screens),
# then compared with the baseline into the proof.
compare() {
    local root folder cell picture platform app
    mkdir -p "$work/pictures"
    for root in "$@"; do
        for folder in "$root"/review-*; do
            [ -d "$folder" ] || continue
            cell="$(basename "$folder")"
            for picture in "$folder"/*.png; do
                [ -e "$picture" ] || continue
                case "$picture" in *.reference.png | *.diff.png) continue ;; esac
                cp "$picture" "$work/pictures/${cell#review-}-$(basename "$picture")"
            done
        done
    done
    for platform in $PLATFORMS; do
        for app in storybook playground; do
            if ! ls "$work/pictures/$platform-$app-"*.png > /dev/null 2>&1; then
                echo "::error::no picture of $platform's $app"
                status=1
            fi
        done
    done
    "$work/proof_compare" "$work/pictures" "$baseline" "$proof" --commit "$commit" --ref "$ref" --kind "$kind" \
        ${GITHUB_RUN_ID:+--run "$GITHUB_RUN_ID"} ${base_ref:+--base-ref "$base_ref"} ${base_commit:+--base-commit "$base_commit"} \
        --ignore "$ROOT/tools/ci/proof_ignore.txt" > "$work/summary.md"
    cat "$work/summary.md"
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || cat "$work/summary.md" >> "$GITHUB_STEP_SUMMARY"
    phase "done: $(ls "$proof/screens" | wc -l | tr -d ' ') pictures"
}

# --stage build: every app built for the stages that picture them
# elsewhere, and the Android Playground pictured here (its compiler, built
# into the app, is arm64's alone, and GitHub's runners with KVM are x86_64).
build_apps() {
    echo "::group::The apps, built (tools/proof/proof.py --build-to)"
    background "$python" -u "$ROOT/tools/proof/proof.py" ios macos web --build-to "$apps" --review "$review" \
        --commit "$commit" --web-toolchain "$web_toolchain" || { echo "::error::the apps didn't build"; exit 1; }
    background "$python" -u "$ROOT/tools/proof/proof.py" android --apps storybook --android-abi x86_64 \
        --build-to "$apps/hosted" --review "$review" --commit "$commit" ||
        { echo "::error::the Android Storybook (x86_64) didn't build"; exit 1; }
    echo "::endgroup::"
    phase "built"
}

build() {
    build_apps
    echo "::group::The Android Playground, on an emulator leased from OS Server"
    background "$python" -u "$ROOT/tools/proof/proof.py" android --apps playground --review "$review" --commit "$commit" \
        ${quick[@]+"${quick[@]}"} || { echo "::error::the Android Playground: a build failed or a picture didn't come back"; exit 1; }
    echo "::endgroup::"
    phase "the Android Playground pictured"
}

# --stage shoot, before anything else: what the platform's machine needs.
# GitHub's runners: Python's own (Pillow in a venv of the run's), Xcode
# 27.2 for the simulator, the Mac's screen made OS Server's slots' (its own
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
            # OS Server's mac slots' screen (1920 by 1200 at 1x), so the
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
    local from="$apps" only=()
    # The Android Storybook alone (x86_64): its Playground was pictured in
    # the build stage.
    if [ "$platform" = android ]; then from="$apps/hosted"; only=(--apps storybook); fi
    echo "::group::$platform's apps, pictured here (tools/proof/proof.py --here)"
    background "$python" -u "$ROOT/tools/proof/proof.py" "$platform" --here --from "$from" ${only[@]+"${only[@]}"} \
        --review "$review" --commit "$commit" ${quick[@]+"${quick[@]}"} ||
        { echo "::error::$platform: a picture didn't come back"; exit 1; }
    echo "::endgroup::"
    phase "$platform pictured"
}

# The tools first: nothing leased if one doesn't build. proof.py's python
# with Pillow: without, its desktops' pictures go uncropped (the clocks,
# the wallpaper), which it only logs.
# In CI the job's own container (the isomer-jit runners: OS Server's
# single-use Linux containers) builds and pictures, in place; on a Mac
# (OS Server's own) it builds with the Mac's Xcode.
inside=""
[ "$(uname -s)" = Darwin ] || inside=1
stages shoot && inside=""
host="${OSS_FILES_HOST:-}"
if [ -z "$host" ] && [ -n "${OSS_SERVERS:-}" ]; then
    # The first of the servers' addresses (a URL, or host:port).
    host="${OSS_SERVERS%%[ ,]*}"
    host="${host#*://}"
    host="${host%%[:/]*}"
fi
if [ -z "$host" ] && [ -z "$inside" ] && ! stages shoot; then
    host="$(/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json | plutil -extract Self.DNSName raw -o - -)"
    host="${host%.}"
fi
if stages shoot; then
    shoot_setup
elif [ -n "$inside" ]; then
    [ -n "$host" ] || { echo "::error::no host for OS Server's files: set OSS_FILES_HOST (or OSS_SERVERS)"; exit 1; }
    echo "::group::The container's tools"
    root_do() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
    # gh (the baseline, the release site); Python with Pillow for proof.py;
    # what Chrome for Testing loads; unzip.
    packages=(gh git python3 python3-pil unzip libnss3 libasound2t64 libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2
              libpango-1.0-0 libcairo2 libcups2t64 libdrm2 libgbm1 fonts-dejavu-core)
    root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${packages[@]}" > /dev/null ||
        { root_do apt-get update -qq > /dev/null &&
          root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${packages[@]}" > /dev/null; }
    # The Apple targets' toolchains and SDK archive (OS Server's files),
    # for every Bazel command in the examples (proof.py's, package_site.sh's).
    sdk="$(sed -n 's/^SDK_SHA256="\(.*\)"/\1/p' "$ROOT/tools/ci/container_build.sh")"
    cat > "$work/downloader.cfg" <<EOF2
rewrite apple-sdks\.invalid/.* http://$host:7490/files/sha256/$sdk
rewrite ported-tools\.invalid/sha256/(.*) http://$host:7490/files/sha256/\$1
rewrite windows-sdks\.invalid/sha256/(.*) http://$host:7490/files/sha256/\$1
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
    swiftc -O -o "$work/proof_compare" "$ROOT/tools/ci/proof_compare.swift"
else
    xcrun swiftc -O -o "$work/proof_compare" "$ROOT/tools/ci/proof_compare.swift"
fi
python="${PROOF_PYTHON:-${shoot_python:-python3}}"
"$python" -c 'import PIL' 2> /dev/null || { echo "::error::$python has no Pillow (PROOF_PYTHON names one that has)"; exit 1; }

quick=()
if [ "$kind" = quick ]; then quick=(--quick --base "origin/${GITHUB_BASE_REF:-main}"); fi
if stages shoot; then
    shoot
    exit 0
fi

if stages all build prebuild; then
echo "::group::The Playground's compilers"
# The staged compilers from OS Server's files, unpacked where the apps'
# BUILD files find them (the checkout's gitignored folders).
"$ROOT/tools/ci/stage_playground_compilers.sh" ios-simulator android macos web
web_toolchain="$ROOT/examples/playground/web/playground_web_application/staged_toolchain"
[ -f "$web_toolchain/manifest.json" ] || { echo "::error::no browser compiler staged at $web_toolchain"; exit 1; }
echo "::endgroup::"
phase "compilers staged"
fi

if stages build; then
    build
    exit 0
fi
# --stage prebuild (main's populate): the apps built as the build stage builds
# them, and nothing pictured or leased, so a release's proof finds its
# actions in the cache.
if stages prebuild; then
    build_apps
    exit 0
fi

echo "::group::The baseline"
# Every kept proof: "<commit> <run> <branch>", newest run first.
gh api --paginate "repos/$repo/actions/artifacts?name=proof&per_page=100" \
    --jq '.artifacts[] | select(.expired | not) | "\(.workflow_run.head_sha) \(.workflow_run.id) \(.workflow_run.head_branch)"' \
    | sort -k2,2nr > "$work/artifacts" || { echo "::warning::the kept proofs couldn't be listed"; : > "$work/artifacts"; }
# The run of the newest commit on the first-parent line from <start> with a
# proof. By commit, whatever branch it ran on: a commit proved after the
# fact ran on a branch pushed at it.
newest_on() {
    local start="$1" sha run
    for sha in $(git rev-list --first-parent -n 300 "$start" 2> /dev/null); do
        run="$(awk -v sha="$sha" '$1 == sha { print $2; exit }' "$work/artifacts")"
        if [ -n "$run" ]; then echo "$sha $run"; return 0; fi
    done
    return 1
}
base_ref=""
found=""
if [ -n "${PROOF_BASELINE_RUN:-}" ]; then
    found="$(gh run view "$PROOF_BASELINE_RUN" --repo "$repo" --json headSha --jq .headSha) $PROOF_BASELINE_RUN"
    base_ref="$(gh run view "$PROOF_BASELINE_RUN" --repo "$repo" --json headBranch --jq '"refs/heads/" + .headBranch')"
elif [ "${GITHUB_EVENT_NAME:-}" = release ]; then
    tag="${GITHUB_REF_NAME:-${ref#refs/tags/}}"
    previous="$(gh release list --repo "$repo" --exclude-drafts --limit 50 --json tagName,publishedAt \
        --jq "sort_by(.publishedAt) | reverse | map(.tagName) | map(select(. != \"$tag\")) | .[0] // empty")"
    if [ -n "$previous" ]; then
        base_ref="refs/tags/$previous"
        run="$(awk -v branch="$previous" '$3 == branch { print $2; exit }' "$work/artifacts")"
        sha="$(git rev-list -n 1 "$previous" 2> /dev/null || true)"
        if [ -n "$run" ]; then found="$sha $run"; elif [ -n "$sha" ]; then found="$(newest_on "$sha" || true)"; fi
    fi
elif [ "$ref" = refs/heads/main ] || { [ -z "${GITHUB_BASE_REF:-}" ] && git merge-base --is-ancestor HEAD origin/main 2> /dev/null; }; then
    # The previous release's proof: what this commit would replace.
    previous="$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD^ 2> /dev/null || true)"
    if [ -n "$previous" ]; then
        base_ref="refs/tags/$previous"
        found="$(newest_on "$(git rev-list -n 1 "$previous")" || true)"
    fi
    if [ -z "$found" ]; then
        base_ref=refs/heads/main
        found="$(newest_on HEAD^ || true)"
    fi
else
    branch="${GITHUB_BASE_REF:-main}"
    base_ref="refs/heads/$branch"
    found="$(newest_on "$(git merge-base HEAD "origin/$branch")" || true)"
fi
baseline="-"
base_commit=""
# A release's own: the proof.tar.gz asset its release job attached
# (tools/ci/release_assets.sh), which outlives the artifact's 90 days.
if [[ $base_ref == refs/tags/* ]] &&
    gh release download "${base_ref#refs/tags/}" --repo "$repo" --pattern proof.tar.gz --dir "$work/release-proof" 2> /dev/null &&
    mkdir -p "$work/baseline" && tar -xzf "$work/release-proof/proof.tar.gz" -C "$work/baseline" &&
    [ -d "$work/baseline/screens" ]; then
    baseline="$work/baseline/screens"
    base_commit="$(git rev-list -n 1 "${base_ref#refs/tags/}" 2> /dev/null || true)"
    found=""
    echo "Baseline: $base_ref's proof.tar.gz, $(ls "$baseline" | wc -l | tr -d ' ') pictures"
fi
if [ -n "$found" ]; then
    base_commit="${found%% *}"
    if gh run download "${found##* }" --repo "$repo" --name proof --dir "$work/baseline" && [ -d "$work/baseline/screens" ]; then
        baseline="$work/baseline/screens"
        echo "Baseline: $base_ref at $base_commit (run ${found##* }), $(ls "$baseline" | wc -l | tr -d ' ') pictures"
    else
        echo "::warning::the baseline's proof (run ${found##* }) couldn't be fetched: every screen is new"
        base_commit=""
    fi
elif [ "$baseline" = - ]; then
    echo "No proof of $base_ref to compare with: every screen is new"
fi
echo "::endgroup::"

if stages compare; then
    status=0
    compare "$parts" "$parts"/*
    exit "$status"
fi

echo "::group::The Linux apps, packaged in a container"
# Bazel's tree in a volume of the lease's, the checkout mounted (the
# packages come out under .ci/, in it).
linux_packages=()
if [[ " $PLATFORMS " == *" linux "* ]]; then
    linux="$ROOT/.ci/proof-linux"
    rm -rf "$linux" && mkdir -p "$linux"
    steps='
    set -e
    root=$1 out=$2
    cd "$root/examples"
    bazel build -c opt --experimental_convenience_symlinks=ignore \
        //linux/storybook_linux_application:storybook_linux_application_bin \
        //playground/linux/playground_linux_application:playground_linux_application_bin \
        //playground/linux/playground_linux_application:playground_wasm_loader \
        //playground/shared/compiler:toolchain //playground/apple/playground_ios_application:playground_sdk
    linux/storybook_linux_application/package.sh /root/storybook-linux -c opt
    playground/linux/playground_linux_application/package.sh /root/playground-linux -c opt
    tar -czf "$out/storybook-linux.tgz" -C /root storybook-linux
    tar -czf "$out/playground-linux.tgz" -C /root playground-linux
    '
    background oss machine run container --image="$IMAGE" --cpus=6 --memory=16 \
        --mount="$ROOT:$ROOT" --volume="isomer-proof-${GITHUB_RUN_ID:-$$}:/var/cache/bazel:128" --inside --cache="$host" -- \
        bash -c "$steps" proof "$ROOT" "$linux" || { echo "::error::the Linux apps didn't build"; exit 1; }
    echo "::endgroup::"
    phase "Linux packaged"
    linux_packages=(--linux-packages "$linux")
fi

echo "::group::The apps on every platform (tools/proof/proof.py)"
status=0
# shellcheck disable=SC2086
background "$python" -u "$ROOT/tools/proof/proof.py" $PLATFORMS --review "$work/review" --commit "$commit" \
    --web-toolchain "$web_toolchain" ${linux_packages[@]+"${linux_packages[@]}"} ${quick[@]+"${quick[@]}"} \
    || { echo "::error::tools/proof/proof.py: a build failed or a picture didn't come back"; status=1; }
echo "::endgroup::"
phase "pictured"

compare "$work/review"
exit "$status"
