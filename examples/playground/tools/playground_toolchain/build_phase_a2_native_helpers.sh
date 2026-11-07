#!/bin/bash
# Phase A2 of the on-device Playground compiler: the three helper tools the
# swift build runs on the HOST (SWIFT_NATIVE_SWIFT_TOOLS_PATH), built from
# the same swift sources over phase A's LLVM, with -fno-rtti as LLVM's are.
# native-tools/ also links every tool of the base toolchain (swift.org's of
# the sources' release; ISO_BASE_TC as in build_phase_c2_swift.sh).
set -euo pipefail
cd "$(dirname "$0")"
NINJA=~/Developer/swiftwasm-source/ninja/ninja
[ -x "$NINJA" ] || NINJA=$(command -v ninja)
SWIFT_RELEASE=6.4.2
BASE_TC="${ISO_BASE_TC:-}"
if [ -z "$BASE_TC" ]; then
  for version in ~/Library/Caches/bazel/_bazel_*/*/external/rules_swift++swift+swift_toolchain_xcode/.swift-version; do
    [ "$(cat "$version" 2>/dev/null)" = "$SWIFT_RELEASE" ] && { BASE_TC="$(dirname "$version")/usr/bin"; break; }
  done
fi
[ -x "$BASE_TC/swiftc" ] || { echo "no base toolchain at $BASE_TC (set ISO_BASE_TC)" >&2; exit 1; }
"$NINJA" -C build/host-tblgen LLVMSupport LLVMDemangle LLVMBitstreamReader
mkdir -p build/host-helpers native-tools
FLAGS=(-std=c++17 -O2 -fno-rtti -DNDEBUG -Iswift/include -Illvm-project/llvm/include -Ibuild/host-tblgen/include)
LIBS=(build/host-tblgen/lib/libLLVMSupport.a build/host-tblgen/lib/libLLVMDemangle.a build/host-tblgen/lib/libLLVMBitstreamReader.a -lz -lcurses)
xcrun clang++ "${FLAGS[@]}" -c swift/lib/Localization/LocalizationFormat.cpp -o build/host-helpers/localization.o
xcrun clang++ "${FLAGS[@]}" -c swift/lib/Basic/Assertions.cpp -o build/host-helpers/assertions.o
for tool in swift-def-to-strings-converter swift-serialize-diagnostics swift-compatibility-symbols; do
    xcrun clang++ "${FLAGS[@]}" swift/tools/$tool/$tool.cpp build/host-helpers/localization.o build/host-helpers/assertions.o "${LIBS[@]}" -o native-tools/$tool
done
for tool in "$BASE_TC"/*; do
    case "$(basename "$tool")" in swift-def-to-strings-converter | swift-serialize-diagnostics | swift-compatibility-symbols) continue ;; esac
    ln -sfn "$tool" "native-tools/$(basename "$tool")"
done
