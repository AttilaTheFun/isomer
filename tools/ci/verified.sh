#!/bin/bash
# Whether a commit was verified: a run of the Build workflow by hand on it
# (`run: verify` or `run: release`) whose verify and container-verify jobs
# (the tests; the drawing ones in the container) passed, and
# a public repository's apple and android jobs (the iPhone's, the Mac's and
# Android's tests on GitHub's runners),
# and its proof: proof-compare where the proof was pictured on
# GitHub's runners (a public repository), the proof job where it wasn't (a
# private one). The release job asks it before anything is promoted
# (AttilaTheFun/reviews' docs/CI_POLICY.md).
#
#   tools/ci/verified.sh <commit>
#
# GH_TOKEN: the job's token (`actions: read`). Prints the verified run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# gh, installed where the image lacks it.
# shellcheck source=tools/ci/gh_ready.sh
. "$ROOT/tools/ci/gh_ready.sh"
sha="${1:?usage: verified.sh <commit>}"
repo="${GITHUB_REPOSITORY:?}"
# Which jobs ran depends on it: a public repository's tests and proof are
# pictured on GitHub's runners (apple, android, proof-compare), a private
# one's in verify and proof alone. A job missing from a run fails it, so a
# job renamed here or in the workflow can't drop out of the check unseen; a
# matrix job (apple's parts: "apple (ios)") passes when every part did.
private="$(gh api "repos/$repo" --jq .private)"
case "$private" in true | false) ;; *) echo "verified.sh: $repo's visibility unknown" >&2; exit 1 ;; esac
for run in $(gh api "repos/$repo/actions/runs?head_sha=$sha&event=workflow_dispatch&per_page=50" \
    --jq '.workflow_runs[] | select(.name == "Build") | .id'); do
    if gh api "repos/$repo/actions/runs/$run/jobs?per_page=100" --jq "$private"' as $private
        | .jobs as $jobs
        | def result(name): ([$jobs[] | select(.name == name) | .conclusion][0] // "missing");
          def named(name): [$jobs[] | select(.name == name or (.name | startswith(name + " (")))];
          def hosted(name): named(name) as $all | ($all | length) > 0
            and ($all | all(.conclusion == (if $private then "skipped" else "success" end)));
        result("verify") == "success" and result("container-verify") == "success"
        and hosted("android") and hosted("apple")
        and (if $private then result("proof") == "success" else result("proof-compare") == "success" end)' |
        grep -qx true; then
        echo "$run"
        exit 0
    fi
done
echo "verified.sh: no run of the Build workflow verified $sha (its verify and proof passed)" >&2
exit 1
