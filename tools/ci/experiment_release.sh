#!/bin/bash
# An experiment's draft release (docs/EXPERIMENTS.md): its builds, as
# publish_from_ci.sh --download saved them signed, attached to a new draft
# named `adhoc-<slug>-<n>` (the next n for the slug) on the run's commit,
# each builds.json line given the experiment's purpose. Applications lists
# it in its Ad hoc section, apart from the apps, until the owner deletes it
# there. A draft, so it makes no tag and tells no one who watches the
# repository; deleted, it leaves nothing behind.
#
#   tools/ci/experiment_release.sh <slug> <purpose> <dir> [<notes.md>]
#
# <slug>: lowercase letters, digits and dashes (`visor-wasm`). <purpose>: one
# line, what it is for. <dir>: publish_from_ci.sh --download's folder.
# <notes.md>: the release's notes (else the purpose).
#
# From the job's environment: GH_TOKEN, the job's, with `contents: write`;
# GITHUB_REPOSITORY and GITHUB_SHA. bash, python3, curl and gh (gh_ready.sh,
# and attach_release.sh, beside this file, which a repository copies too).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
usage="usage: tools/ci/experiment_release.sh <slug> <purpose> <dir> [<notes.md>]"
slug="${1:?$usage}"
purpose="${2:?$usage}"
dir="${3:?$usage}"
notes="${4:-}"
repo="${GITHUB_REPOSITORY:?}"
commit="${GITHUB_SHA:?}"
fail() { echo "experiment_release: $*" >&2; exit 1; }
printf '%s' "$slug" | grep -q -E '^[a-z0-9]+(-[a-z0-9]+)*$' || fail "$slug is not a slug: lowercase letters, digits and dashes"
case "$purpose" in *$'\n'*) fail "the purpose is one line" ;; esac
[ -f "$dir/builds.json" ] || fail "$dir has no builds.json (publish_from_ci.sh --download <dir>)"
[ -z "$notes" ] || [ -f "$notes" ] || fail "no such file: $notes"
: "${GH_TOKEN:?GH_TOKEN, the job token with contents: write}"
# shellcheck source=tools/ci/gh_ready.sh
. "$ROOT/tools/ci/gh_ready.sh"

# Every line an experiment's (AdHoc, under the experiments' prefix), given
# the purpose; refused otherwise, before anything is made.
python3 -I - "$dir/builds.json" "$purpose" <<'EOF'
import json, sys
path, purpose = sys.argv[1], sys.argv[2]
prefix = "com.LoganShire.Experiments."
with open(path) as f:
    lines = json.load(f)
for line in lines:
    bundle = line.get("bundleID", "")
    if line.get("variant") != "AdHoc" or not bundle.startswith(prefix) or len(bundle) == len(prefix):
        sys.exit(f"experiment_release: {line.get('file')} is {bundle} ({line.get('variant')}), not an experiment's: "
                 f"an AdHoc build under {prefix}")
    line["purpose"] = purpose
with open(path, "w") as f:
    json.dump(lines, f, indent=2)
    f.write("\n")
EOF

# The next number for the slug, among the releases and drafts there.
last="$(gh api "repos/$repo/releases?per_page=100" --paginate --jq ".[].tag_name" |
    sed -n "s/^adhoc-$slug-\([0-9][0-9]*\)\$/\1/p" | sort -n | tail -1)"
tag="adhoc-$slug-$(( ${last:-0} + 1 ))"
app="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[0]["app"])' "$dir/builds.json")"
body="$( { [ -n "$notes" ] && cat "$notes"; } || printf '%s\n' "$purpose")"
gh api -X POST "repos/$repo/releases" -f tag_name="$tag" -f target_commitish="$commit" -f name="$app ($tag)" \
    -F draft=true -F prerelease=true -f body="$body" > /dev/null
echo "experiment_release: $tag drafted ($commit)"
"$ROOT/tools/ci/attach_release.sh" "$tag" "$dir"
echo "experiment_release: $tag is in Applications' Ad hoc section"
