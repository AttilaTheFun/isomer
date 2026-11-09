#!/bin/bash
# A signed build, saved as a GitHub release's asset (the private AttilaTheFun/applications' docs/RELEASE_ASSETS.md):
# sourced by publish_from_ci.sh and promote_from_ci.sh, which call
# `release_asset` with each build the server answered, for their
# `--download <dir>`. The job then attaches the folder to its release
# (attach_release.sh). bash, curl and openssl; sha256sum or shasum.
#
#   release_asset <build JSON> <dir> <server> <ca.pem> <file>
#
# - <build JSON>: one build as the server lists it (its keys sorted), on
#   one line;
# - <file>: what to download of it: app.ipa, app.zip, app.apk or app.dmg.
#
# It downloads the file as <App>-<version>-<platform>.<ext>, and adds its
# line to <dir>/builds.json, which it writes again whole each time: the
# builds of every call into the folder, one a line.

release_asset_field() {
  printf '%s' "$1" | sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p"
}

# A JSON string's inside: backslashes and quotes escaped (the server's
# values have no control characters).
release_asset_json() {
  printf '%s' "$1" | sed 's/[\\"]/\\&/g'
}

release_asset() {
  local build="$1" dir="$2" server="$3" ca="$4" file="$5"
  local id key name app version build_number platform bundle variant channel commit uuid ext asset status digest size
  id="$(release_asset_field "$build" id)"
  key="$(release_asset_field "$build" downloadKey)"
  name="$(release_asset_field "$build" name)"
  app="$(release_asset_field "$build" app)"
  version="$(release_asset_field "$build" version)"
  build_number="$(release_asset_field "$build" buildNumber)"
  platform="$(release_asset_field "$build" platform)"
  bundle="$(release_asset_field "$build" bundleID)"
  variant="$(release_asset_field "$build" buildVariant)"
  channel="$(release_asset_field "$build" channel)"
  commit="$(release_asset_field "$build" commit)"
  uuid="$(release_asset_field "$build" executableUUID)"
  [ -n "$id" ] && [ -n "$key" ] && [ -n "$version" ] && [ -n "$platform" ] && [ -n "$bundle" ] ||
    { echo "release_asset: the server's answer names no build" >&2; return 1; }
  [ -n "$variant" ] || variant="$([ "$channel" = production ] && echo Production || echo Alpha)"
  [ -n "$commit" ] || commit="${APPLICATIONS_COMMIT:-${GITHUB_SHA:-}}"
  ext="${file##*.}"
  # The app's name across platforms, else the build's own: no spaces or
  # slashes in a file name.
  asset="$(printf '%s' "${app:-$name}" | tr ' /' '--')-$version-$platform.$ext"

  mkdir -p "$dir"
  status="$(curl -sS --cacert "$ca" --connect-timeout 10 --max-time 1800 -o "$dir/$asset" -w '%{http_code}' \
    "$server/builds/$id/$key/$file")" || { rm -f "$dir/$asset"; echo "release_asset: $asset was not downloaded" >&2; return 1; }
  [ "$status" = 200 ] || { rm -f "$dir/$asset"; echo "release_asset: $asset was not downloaded ($status)" >&2; return 1; }
  if command -v sha256sum > /dev/null; then digest="$(sha256sum "$dir/$asset" | cut -d' ' -f1)"
  else digest="$(shasum -a 256 "$dir/$asset" | cut -d' ' -f1)"; fi
  size="$(wc -c < "$dir/$asset" | tr -d ' ')"

  # One line a file, the same file named again replacing its line.
  touch "$dir/builds.lines"
  grep -v "\"file\":\"$(release_asset_json "$asset")\"" "$dir/builds.lines" > "$dir/builds.lines.new" || true
  printf '{"file":"%s","bundleID":"%s","app":"%s","platform":"%s","version":"%s","buildNumber":"%s","variant":"%s","commit":"%s","executableUUID":"%s","size":%s,"sha256":"%s"}\n' \
    "$(release_asset_json "$asset")" "$(release_asset_json "$bundle")" "$(release_asset_json "${app:-$name}")" \
    "$platform" "$(release_asset_json "$version")" "$(release_asset_json "$build_number")" "$variant" "$commit" "$uuid" \
    "$size" "$digest" >> "$dir/builds.lines.new"
  mv "$dir/builds.lines.new" "$dir/builds.lines"
  { echo '['; sed '$!s/$/,/' "$dir/builds.lines"; echo ']'; } > "$dir/builds.json"
  echo "Saved for the release: $asset"
}
