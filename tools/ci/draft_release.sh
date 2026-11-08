#!/bin/bash
# The draft release a proposal makes (the Build workflow's alpha job, run by
# hand on main with `run: prerelease` or `run: release`; AttilaTheFun/reviews'
# docs/CI_POLICY.md): tag v<version>, which publishing it makes (no agent
# publishes a draft or makes a tag), on this run's commit, with the Alphas
# this run just published, and for a release this run's verify and proof.
# The same commit proposed again gets the same version from Applications
# Server, so a draft of that tag already there (a run that failed after
# publishing) is replaced by this one.
#
#   tools/ci/draft_release.sh <version> prerelease|release [<asset>…]
#
# GH_TOKEN: the job's token (its `contents: write` makes drafts). Needs curl
# and python3, no gh.
set -euo pipefail
version="${1:?usage: draft_release.sh <version> prerelease|release [<asset>…]}"
kind="${2:?usage: draft_release.sh <version> prerelease|release [<asset>…]}"
shift 2
case "$kind" in prerelease | release) ;; *) echo "draft_release.sh: prerelease or release, not $kind" >&2; exit 2 ;; esac
repo="${GITHUB_REPOSITORY:?}"
sha="${GITHUB_SHA:?}"
run="${GITHUB_RUN_ID:?}"
tag="v$version"
notes="$(mktemp)"
previous="$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD^ 2> /dev/null || true)"
{
    if [ "$kind" = release ]; then
        echo "Isomer $version, proposed for release by run $run on $sha. Its verify (the Apple tests) and its proof (the run's \`proof\` artifact) passed."
    else
        echo "Isomer $version, a pre-release made by run $run on $sha (no tests or proof)."
    fi
    echo
    echo "Alphas: the Storybook and the Playground $version for the iPhone, the Mac and Android, in Applications."
    if [ -n "$previous" ]; then
        echo
        echo "## Changes since $previous"
        echo
        git log --first-parent --format='- %s' "$previous..HEAD"
    fi
} > "$notes"
# GitHub's REST API over curl: CI's container has no gh.
api() {
    curl -fsS -H "Authorization: Bearer ${GH_TOKEN:?}" -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}
# A draft of this tag from an earlier run goes (a draft has no tag yet, so
# it is found among the releases, not by its tag).
for id in $(api "https://api.github.com/repos/$repo/releases?per_page=100" |
    python3 -c 'import json, sys; print(" ".join(str(r["id"]) for r in json.load(sys.stdin) if r["draft"] and r["tag_name"] == sys.argv[1]))' "$tag"); do
    api -X DELETE "https://api.github.com/repos/$repo/releases/$id" > /dev/null
done
release="$(python3 -c 'import json, sys
print(json.dumps({"tag_name": sys.argv[1], "target_commitish": sys.argv[2], "name": "Isomer " + sys.argv[3],
    "body": open(sys.argv[4]).read(), "draft": True, "prerelease": sys.argv[5] != "release"}))' \
    "$tag" "$sha" "$version" "$notes" "$kind")"
id="$(api -X POST "https://api.github.com/repos/$repo/releases" -d "$release" |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')"
for asset in "$@"; do
    api -X POST -H "Content-Type: application/octet-stream" --data-binary "@$asset" \
        "https://uploads.github.com/repos/$repo/releases/$id/assets?name=$(basename "$asset")" > /dev/null
done
echo "draft_release.sh: $tag drafted ($kind) on $sha"
