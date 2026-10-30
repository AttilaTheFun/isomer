#!/bin/bash
# Isomer's proof, from CI: its two apps (the Storybook, the Playground) on
# its six platforms, each with its one renderer (SwiftUI on iOS and the Mac,
# Compose on Android, React on the web, OpenGL on Linux, DirectX on
# Windows), pictured on machines leased from OS Server (tools/proof/proof.py),
# each picture compared with the base's, and the `proof` artifact Reviews
# reads made of them (tools/ci/proof_compare.swift).
#
#   tools/ci/proof.sh --proof <dir> [--kind quick|full]
#
# quick (each commit on main's; a branch's when run by hand): both apps
# still built on every platform, a core set of stories (and every story in
# a story file a branch touches), and the Playground's screens. full (only
# by hand): every story.
#
# The baseline is the base's pictures, never the change's own:
#   a pull request (or a branch's run): its base branch's proof, of the
#     newest commit there at or before the one the branch parted from;
#   a push to main: its parent's (the newest commit before it with one);
#   a release: the previous release's run (else its commit's on main);
#   PROOF_BASELINE_RUN: a run of this workflow whose proof to compare with
#     instead (how a second run of one commit shows it held still).
# Each is the `proof` artifact of a run of this workflow (kept 90 days),
# fetched with gh. The pictures aren't kept in the repository: a full proof
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
# The builds: proof.py's, on this runner's Mac (the Apple apps with its
# Xcode; Android's, the web's), except Linux's (packaged in a container
# leased from OS Server, as tools/ci/container_build.sh builds) and
# Windows' (on its VM). The Playground's compilers that Bazel doesn't make:
# the iPhone simulator's and Android's staged ones from OS Server's files
# (by SHA-256, as the Apple SDK archive is: `oss files add` on its Mac),
# and the in-browser one from the latest release's site.
#
#   PROOF_REF           the ref the proof is of (default: GITHUB_REF, else the branch)
#   PROOF_PYTHON        the python3 that runs proof.py, with Pillow, which crops
#                       the desktops' pictures (default: the PATH's python3)
#   PROOF_BASELINE_RUN  a run whose proof is the baseline (above)
#   OSS_FILES_HOST      the name a container reaches this Mac's OS Server by
#                       (default: this Mac's tailnet name, from Tailscale)
#   GH_TOKEN            gh's token (the job's)
#
# Every lease is released however the script ends: proof.py's own as it
# finishes, and on a cancel (the job's `exec` brings the runner's signal
# here) every lease labelled with this job.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="ghcr.io/attilathefun/visor-agent:0.41.2"
# The Playground's staged compilers, served by OS Server (`oss files list`):
# examples/playground/apple/playground_ios_application/embedded_toolchain/
# {iphonesimulator,data}, and examples/playground/android/
# playground_android_application/toolchain/.
IOS_SIMULATOR_TOOLCHAIN=4e23b747153a2f3b75fa91a0f9ca14bcd5a58d68af71c8d9be14ceea47386f05
ANDROID_TOOLCHAIN=0b52a5d3322042317f661ab762cf3b123af5e2ce52cf192c95de31e9779f52c8
PLATFORMS="ios macos android web linux windows"

usage() { echo "usage: tools/ci/proof.sh --proof <dir> [--kind quick|full]" >&2; exit 2; }
proof=""
kind="quick"
while [ $# -gt 0 ]; do
    case "$1" in
        --proof) proof="${2:?--proof takes a folder}"; shift 2 ;;
        --kind) kind="${2:?--kind takes quick or full}"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$proof" ] || usage
case "$kind" in quick | full) ;; *) usage ;; esac
mkdir -p "$proof"
proof="$(cd "$proof" && pwd)"

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

# The tools first: nothing leased if one doesn't build. proof.py's python
# with Pillow: without, its desktops' pictures go uncropped (the clocks,
# the wallpaper), which it only logs.
xcrun swiftc -O -o "$work/proof_compare" "$ROOT/tools/ci/proof_compare.swift"
python="${PROOF_PYTHON:-python3}"
"$python" -c 'import PIL' 2> /dev/null || { echo "::error::$python has no Pillow (PROOF_PYTHON names one that has)"; exit 1; }

echo "::group::The Playground's compilers"
# A staged compiler from OS Server's files, unpacked where the app's
# BUILD finds it (the checkout's gitignored folders). One staged by hand (a
# checkout of an agent's, with the device's too) is kept as it is.
stage() {
    local sha="$1" folder="$2" into="$3"
    if [ "$(cat "$folder/.sha256" 2> /dev/null)" = "$sha" ]; then return 0; fi
    if [ -d "$folder" ] && [ ! -f "$folder/.sha256" ]; then return 0; fi
    rm -rf "$folder"
    oss storage get "$sha" "$work/$sha.tar.gz" > /dev/null
    [ "$(shasum -a 256 "$work/$sha.tar.gz" | cut -d' ' -f1)" = "$sha" ] || { echo "::error::$sha's bytes don't match it"; exit 1; }
    tar -xzf "$work/$sha.tar.gz" -C "$into"
    rm "$work/$sha.tar.gz"
    echo "$sha" > "$folder/.sha256"
}
playground="$ROOT/examples/playground"
stage "$IOS_SIMULATOR_TOOLCHAIN" "$playground/apple/playground_ios_application/embedded_toolchain" \
    "$playground/apple/playground_ios_application"
stage "$ANDROID_TOOLCHAIN" "$playground/android/playground_android_application/toolchain" \
    "$playground/android/playground_android_application"
# The browser's: the latest release's site's.
mkdir -p "$work/site"
gh release download --repo "$repo" --pattern isomer-site.tar.gz --dir "$work/site"
tar -xzf "$work/site/isomer-site.tar.gz" -C "$work/site"
web_toolchain="$(find "$work/site" -type d -path '*/playground/toolchain' | head -1)"
[ -n "$web_toolchain" ] || { echo "::error::the latest release's site has no playground/toolchain"; exit 1; }
echo "::endgroup::"
phase "compilers staged"

echo "::group::The baseline"
# Every kept proof: "<commit> <run> <branch>", newest run first.
gh api --paginate "repos/$repo/actions/artifacts?name=proof&per_page=100" \
    --jq '.artifacts[] | select(.expired | not) | "\(.workflow_run.head_sha) \(.workflow_run.id) \(.workflow_run.head_branch)"' \
    | sort -k2,2nr > "$work/artifacts" || { echo "::warning::the kept proofs couldn't be listed"; : > "$work/artifacts"; }
# The run of the newest commit on <branch>'s first-parent line from <start> with a proof.
newest_on() {
    local branch="$1" start="$2" sha run
    for sha in $(git rev-list --first-parent -n 300 "$start" 2> /dev/null); do
        run="$(awk -v sha="$sha" -v branch="$branch" '$1 == sha && $3 == branch { print $2; exit }' "$work/artifacts")"
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
        if [ -n "$run" ]; then found="$sha $run"; elif [ -n "$sha" ]; then found="$(newest_on main "$sha" || true)"; fi
    fi
elif [ "$ref" = refs/heads/main ]; then
    base_ref=refs/heads/main
    found="$(newest_on main HEAD^ || true)"
else
    branch="${GITHUB_BASE_REF:-main}"
    base_ref="refs/heads/$branch"
    found="$(newest_on "$branch" "$(git merge-base HEAD "origin/$branch")" || true)"
fi
baseline="-"
base_commit=""
if [ -n "$found" ]; then
    base_commit="${found%% *}"
    if gh run download "${found##* }" --repo "$repo" --name proof --dir "$work/baseline" && [ -d "$work/baseline/screens" ]; then
        baseline="$work/baseline/screens"
        echo "Baseline: $base_ref at $base_commit (run ${found##* }), $(ls "$baseline" | wc -l | tr -d ' ') pictures"
    else
        echo "::warning::the baseline's proof (run ${found##* }) couldn't be fetched: every screen is new"
        base_commit=""
    fi
else
    echo "No proof of $base_ref to compare with: every screen is new"
fi
echo "::endgroup::"

echo "::group::The Linux apps, packaged in a container"
# Bazel's tree in a volume of the lease's, the checkout mounted (the
# packages come out under .ci/, in it).
host="${OSS_FILES_HOST:-}"
if [ -z "$host" ]; then
    host="$(/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json | plutil -extract Self.DNSName raw -o - -)"
    host="${host%.}"
fi
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

echo "::group::The apps on every platform (tools/proof/proof.py)"
quick=()
if [ "$kind" = quick ]; then quick=(--quick --base "origin/${GITHUB_BASE_REF:-main}"); fi
status=0
# shellcheck disable=SC2086
background "$python" -u "$ROOT/tools/proof/proof.py" $PLATFORMS --review "$work/review" --commit "$commit" \
    --web-toolchain "$web_toolchain" --linux-packages "$linux" ${quick[@]+"${quick[@]}"} \
    || { echo "::error::tools/proof/proof.py: a build failed or a picture didn't come back"; status=1; }
echo "::endgroup::"
phase "pictured"

# Every picture, named for its platform, app and screen: review-ios-storybook/
# navigation.links.png is ios-storybook-navigation.links (the iPhone's
# compiled Storybook's references and diffs against Apple's are its own
# review's, not screens).
mkdir -p "$work/pictures"
for folder in "$work/review"/review-*; do
    [ -d "$folder" ] || continue
    cell="$(basename "$folder")"
    for picture in "$folder"/*.png; do
        [ -e "$picture" ] || continue
        case "$picture" in *.reference.png | *.diff.png) continue ;; esac
        cp "$picture" "$work/pictures/${cell#review-}-$(basename "$picture")"
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
exit "$status"
