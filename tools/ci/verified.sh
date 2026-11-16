#!/bin/bash
# Whether a commit was verified: a run of the Build workflow by hand on it
# whose every test passed, on GitHub's own runners: each platform's build
# and its tests there (verify: the web, Linux and Android together;
# verify-apple), the tests that
# draw in a container (container-verify), the iPhone's, the Mac's and
# Android's tests (apple, android: a matrix job passes when every part did),
# and its screenshot proof (proof-compare). Only `run: release` runs both
# the tests and the proof (`run: verify` has no proof, `run: proof` no
# tests: the owner, 2026-11-15), and it is the run that proposed the
# release, so a release's own proposal is what this finds. The release job
# asks it before anything is signed
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
        passed("verify") and passed("verify-apple") and passed("container-verify")
        and passed("apple") and passed("android") and passed("proof-compare")' |
        grep -qx true; then
        echo "$run"
        exit 0
    fi
done
echo "verified.sh: no run of the Build workflow verified $sha (its verify and proof passed)" >&2
exit 1
