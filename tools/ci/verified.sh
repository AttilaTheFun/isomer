#!/bin/bash
# Whether a commit was verified: a run of the Build workflow by hand on it
# (`run: verify` or `run: release`) whose every test passed, on GitHub's own
# runners: each platform's build and its tests there (verify,
# verify-android, verify-apple), the tests that draw in a container
# (container-verify), the iPhone's, the Mac's and Android's tests (apple,
# android: a matrix job passes when every part did), and its proof
# (proof-compare). The release job asks it before anything is signed
# (AttilaTheFun/reviews' docs/CI_POLICY.md). A job missing from a run fails
# it, so a job renamed here or in the workflow can't drop out of the check
# unseen.
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
for run in $(gh api "repos/$repo/actions/runs?head_sha=$sha&event=workflow_dispatch&per_page=50" \
    --jq '.workflow_runs[] | select(.name == "Build") | .id'); do
    if gh api "repos/$repo/actions/runs/$run/jobs?per_page=100" --jq '.jobs as $jobs
        | def named(name): [$jobs[] | select(.name == name or (.name | startswith(name + " (")))];
          def passed(name): named(name) as $all | ($all | length) > 0 and ($all | all(.conclusion == "success"));
        passed("verify") and passed("verify-android") and passed("verify-apple") and passed("container-verify")
        and passed("apple") and passed("android") and passed("proof-compare")' |
        grep -qx true; then
        echo "$run"
        exit 0
    fi
done
echo "verified.sh: no run of the Build workflow verified $sha (its verify and proof passed)" >&2
exit 1
