#!/bin/bash
# The web Storybook drawn by two renderers, story by story: each story's
# page pictured with `?renderer=<base>` and with `?renderer=<candidate>`, at
# desktop width (1280×800, the Mac's look) and a phone's (390×844, iOS's),
# with its DOM (browser_check's --dom), and each candidate picture compared
# with its base's (--reference). Made for the DOM renderer replacing React's
# (0.48): a story whose pictures or DOM differ is one still to port.
#
#   tools/testing/renderer_compare.sh <site dir> <out dir> [<base> <candidate>] [<story>…]
#
# <base> and <candidate> are renderer names (react and dom by default; react
# and react measures the noise of a story that moves on its own). The
# stories are the Storybook's (examples/storybook), all of them unless
# named. CHROME names Chrome; BROWSER_CHECK the browser_check binary (else
# bazel builds it). Writes <out>/<width>/<renderer>/<story>.png, its
# .dom.txt and (the candidate) .diff.txt, and <out>/summary.txt: a line a
# story and width, the pixels that differ and whether the DOM does.
#
# BASELINE=<an earlier run's out dir> compares the candidate with that run's
# <base> pictures instead of shooting <base> again: a change to one renderer
# held to its pictures before (react against react, before and after).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
site="$(cd "${1:?usage: renderer_compare.sh <site dir> <out dir> [<base> <candidate>] [<story>…]}" && pwd)"
mkdir -p "${2:?<out dir>}"
out="$(cd "$2" && pwd)"
shift 2
base=react
candidate=dom
if [ $# -ge 2 ] && [[ "$1" != *.* ]] && [[ "$2" != *.* ]]; then
    base="$1" candidate="$2"
    shift 2
fi
check="${BROWSER_CHECK:-}"
if [ -z "$check" ]; then
    (cd "$ROOT" && bazel build //tools/testing/browser_check > /dev/null 2>&1) || { echo "renderer_compare: browser_check didn't build" >&2; exit 1; }
    check="$ROOT/$(cd "$ROOT" && bazel cquery --output=files //tools/testing/browser_check 2> /dev/null | head -1)"
fi

# The stories in the sidebar's order: the areas as Story.swift lists them,
# each area's stories as its file does (tools/proof/proof.py's stories()).
stories=("$@")
if [ ${#stories[@]} -eq 0 ]; then
    storybook="$ROOT/examples/storybook"
    areas="$(tr '\n' ' ' < "$storybook/Story.swift" | sed -n 's/.*areas: \[StoryArea\] = \[\([^]]*\)\].*/\1/p' | tr ',' '\n' | tr -d ' ')"
    for area in $areas; do
        file="$(grep -l "static let $area = StoryArea(" "$storybook"/stories/*.swift | head -1)"
        while read -r story; do stories+=("$story"); done < <(sed -n 's/^[[:space:]]*"\([a-z]*\.[a-z]*\)", "[^"]*".*/\1/p' "$file")
    done
fi
[ ${#stories[@]} -gt 0 ] || { echo "renderer_compare: no stories" >&2; exit 1; }

# One browser_check run a renderer and size, every story a page.
shoot() {
    local renderer="$1" width="$2" height="$3" reference="$4" pages=() story
    mkdir -p "$out/${width}x$height/$renderer"
    for story in "${stories[@]}"; do
        pages+=(--page "?renderer=$renderer&ISO_STORYBOOK_STORY=$story=$out/${width}x$height/$renderer/$story.png")
    done
    "$check" --site "$site" --width "$width" --height "$height" --until 'window.__isoLastTree' --settle 1 \
        --allow-errors --dom ${reference:+--reference "$reference"} "${pages[@]}" > "$out/${width}x$height/$renderer.log" 2>&1
}

: > "$out/summary.txt"
for size in 1280x800 390x844; do
    width="${size%x*}" height="${size#*x}"
    reference="${BASELINE:-$out}/$size/$base"
    [ -n "${BASELINE:-}" ] || shoot "$base" "$width" "$height" ""
    shoot "$candidate" "$width" "$height" "$reference"
    for story in "${stories[@]}"; do
        a="$reference/$story.png" b="$out/$size/$candidate/$story.png"
        pixels="$(cat "$b.diff.txt" 2> /dev/null || echo "?")"
        dom=same
        cmp -s "$a.dom.txt" "$b.dom.txt" || dom=differs
        printf '%s %s %s pixels, DOM %s\n' "$size" "$story" "${pixels//[$'\n']/}" "$dom" >> "$out/summary.txt"
    done
done
same="$(grep -c ' 0 pixels, DOM same$' "$out/summary.txt")"
echo "renderer_compare: $base vs $candidate, $same of $(wc -l < "$out/summary.txt" | tr -d ' ') pictures the same ($out/summary.txt)"
