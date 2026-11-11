#!/bin/bash
# A one-off: every published release of a repository with a proof.zip and
# no proof-diff.json gets its comparison with the release before it
# (docs/PROOF_FORMAT.md, "Releases made before it"), oldest first, made by
# tools/ci/proof_diff.py and uploaded beside its proof.zip. GitHub lets an
# asset be added to a published release.
#
#   GH_TOKEN=… tools/ci/backfill_proof_diff.sh <owner/repo> [--dry-run]
#
# GH_TOKEN: a token with contents: write on the repository (New Container
# Helper's, or a workflow_dispatch job's), never one copied by hand.
# --dry-run: each manifest made and its counts said, nothing uploaded.
set -euo pipefail
repository="${1:?usage: tools/ci/backfill_proof_diff.sh <owner/repo> [--dry-run]}"
shift
[ -n "${GH_TOKEN:-}" ] || { echo "backfill_proof_diff: GH_TOKEN is the repository's token" >&2; exit 1; }
GITHUB_REPOSITORY="$repository" exec python3 -I "$(dirname "$0")/proof_diff.py" backfill "$@"
