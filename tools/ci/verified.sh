#!/bin/bash
# Whether a commit was verified: a run of the Build workflow by hand on it
# (`run: verify` or `run: release`) whose verify job (the Apple tests)
# passed, and its proof: proof-compare where the proof was pictured on
# GitHub's runners (a public repository), the proof job where it wasn't (a
# private one). The release job asks it before anything is promoted
# (AttilaTheFun/reviews' docs/CI_POLICY.md).
#
#   tools/ci/verified.sh <commit>
#
# GH_TOKEN: the job's token (`actions: read`). Prints the verified run.
set -euo pipefail
sha="${1:?usage: verified.sh <commit>}"
repo="${GITHUB_REPOSITORY:?}"
for run in $(gh api "repos/$repo/actions/runs?head_sha=$sha&event=workflow_dispatch&per_page=50" \
    --jq '.workflow_runs[] | select(.name == "Build") | .id'); do
    if gh api "repos/$repo/actions/runs/$run/jobs?per_page=100" --jq '
        .jobs as $jobs
        | def result(name): ([$jobs[] | select(.name == name) | .conclusion][0] // "skipped");
        result("verify") == "success"
        and (result("proof-compare") == "success"
             or (result("proof-compare") == "skipped" and result("proof") == "success"))' | grep -qx true; then
        echo "$run"
        exit 0
    fi
done
echo "verified.sh: no run of the Build workflow verified $sha (its verify and proof passed)" >&2
exit 1
