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
# GH_TOKEN: the job's token (its `contents: write` makes drafts).
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
if [ "$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft 2> /dev/null || true)" = true ]; then
    gh release delete "$tag" --repo "$repo" --yes
fi
flags=()
[ "$kind" = release ] || flags=(--prerelease)
gh release create "$tag" --repo "$repo" --draft --target "$sha" --title "Isomer $version" --notes-file "$notes" \
    ${flags[@]+"${flags[@]}"} "$@"
echo "draft_release.sh: $tag drafted ($kind) on $sha"
