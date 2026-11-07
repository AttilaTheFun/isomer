#!/bin/bash
# The Windows Swift SDK for building on Linux, out of swift.org's Windows
# toolchain installer: its Windows.platform (the SDK the compiler builds
# against, XCTest and Testing beside it) and the runtime's DLLs for arm64
# and x64 (what an app ships beside its .exe), as one archive. Run on Linux
# with 7-Zip and msitools (apt: 7zip msitools); the archive is then served
# from OS Server's files (`oss files add`) and named by its SHA-256 in
# MODULE.bazel (tools/windows/README.md).
#
#   tools/windows/make_swift_sdk.sh <swift-X.Y.Z-RELEASE-windows10-arm64.exe> <out.tar.gz>
set -euo pipefail
installer="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
out="$2"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

# A WiX bundle: its own cabinet, then the payloads' (the attached
# container), each payload named a0…aN, mapped to its file by the bundle's
# manifest (the first cabinet's file "0").
7z e -y -oux "$installer" 0 >/dev/null
offsets=($(grep -obUaP 'MSCF\x00\x00\x00\x00' "$installer" | cut -d: -f1))
[ ${#offsets[@]} -ge 2 ] || { echo "make_swift_sdk.sh: no attached container in $installer" >&2; exit 1; }
# Each cabinet after the bundle's own holds payloads: one in 6.3's
# installers, several in 6.4's.
for offset in "${offsets[@]:1}"; do
    tail -c +$((offset + 1)) "$installer" >attached.cab
    7z e -y -opayloads attached.cab >/dev/null || true
done
mkdir msi
grep -o '<Payload [^>]*>' ux/0 | while read -r payload; do
    file="$(sed -n 's/.*FilePath="\([^"]*\)".*/\1/p' <<<"$payload")"
    source="$(sed -n 's/.*SourcePath="\([^"]*\)".*/\1/p' <<<"$payload")"
    if [ -f "payloads/$source" ]; then cp "payloads/$source" "msi/$file"; fi
done

msiextract -C extracted msi/windows.msi >/dev/null
[ ! -f msi/rtl.msi ] || msiextract -C extracted msi/rtl.msi >/dev/null
swift="extracted/LocalApp/Programs/Swift"
version="$(ls "$swift/Platforms")"
mkdir -p "sdk/swift-windows-sdk"
cp -a "$swift/Platforms/$version/Windows.platform" sdk/swift-windows-sdk/
# The runtime's merge modules: a cabinet of files keyed by id, named in
# the module's File table.
for arch in arm64:aarch64 amd64:x86_64; do
    module="$swift/Redistributables/$version/rtl.${arch%%:*}.msm"
    [ -f "$module" ] || { echo "make_swift_sdk.sh: no ${arch%%:*} runtime in this installer" >&2; continue; }
    mkdir -p "rtl-${arch%%:*}" "sdk/swift-windows-sdk/runtime/${arch##*:}"
    (cd "rtl-${arch%%:*}" && 7z x -y "$work/$module" >/dev/null && 7z x -y MergeModule.CABinet -ofiles >/dev/null)
    msiinfo export "$module" File | tail -n +4 | while IFS=$'\t' read -r key _ name _; do
        [ -f "rtl-${arch%%:*}/files/$key" ] && cp "rtl-${arch%%:*}/files/$key" "sdk/swift-windows-sdk/runtime/${arch##*:}/${name#*|}"
    done
done
# 6.4's installers carry the runtime as an MSI per architecture
# (rtl.arm64.msi: the arm64 installer has arm64's alone), its DLLs as
# files rather than a merge module's.
for arch in arm64:aarch64 amd64:x86_64 x64:x86_64; do
    [ -f "msi/rtl.${arch%%:*}.msi" ] || continue
    msiextract -C "rtl-msi-${arch%%:*}" "msi/rtl.${arch%%:*}.msi" >/dev/null
    mkdir -p "sdk/swift-windows-sdk/runtime/${arch##*:}"
    find "rtl-msi-${arch%%:*}" -type f \( -name '*.dll' -o -name '*.exe' \) -exec cp {} "sdk/swift-windows-sdk/runtime/${arch##*:}/" \;
done
[ -n "$(ls sdk/swift-windows-sdk/runtime/*/*.dll 2>/dev/null)" ] || { echo "make_swift_sdk.sh: no runtime in $installer" >&2; exit 1; }
printf '%s\n' "$version" >sdk/swift-windows-sdk/VERSION
tar -czf "$out" -C sdk swift-windows-sdk
echo "make_swift_sdk.sh: $out (Swift $version): $(du -h "$out" | cut -f1)"
