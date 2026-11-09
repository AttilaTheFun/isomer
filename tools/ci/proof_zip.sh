#!/bin/bash
# A proof's folder (proof.json and its files, Reviews' format 2) zipped as
# proof.zip, proof.json at its top: the asset a proposal's draft carries
# (the private AttilaTheFun/reviews' docs/PROOF_FORMAT.md). zip, installed
# when missing (as root or by sudo).
#
#   tools/ci/proof_zip.sh <proof folder> <out.zip>
set -euo pipefail
folder="${1:?usage: proof_zip.sh <proof folder> <out.zip>}"
zip_file="${2:?<out.zip>}"
[ -f "$folder/proof.json" ] || { echo "::error::$folder has no proof.json"; exit 1; }
if ! command -v zip > /dev/null; then
    root_do() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
    root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends zip > /dev/null ||
        { root_do apt-get update -qq > /dev/null &&
          root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends zip > /dev/null; }
fi
mkdir -p "$(dirname "$zip_file")"
zip_file="$(cd "$(dirname "$zip_file")" && pwd)/$(basename "$zip_file")"
rm -f "$zip_file"
(cd "$folder" && zip -qr "$zip_file" .)
echo "proof_zip: $(unzip -l "$zip_file" 2> /dev/null | tail -1)"
