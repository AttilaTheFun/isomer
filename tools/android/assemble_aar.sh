#!/bin/bash
# Assembles an Isomer app's AAR (isomer_android_aar, defs.bzl):
#
#   assemble_aar.sh <zipper> <out.aar> <manifest> <proguard.txt> <abi> \
#       --jars <jar>… --libs <lib*.so>…
#
# classes.jar is the given jars merged (their classes and resources), less
# every R class (the host's build makes its own) and the jars' META-INF
# signatures and manifests; the libraries go in jni/<abi>/; R.txt is empty
# (the library declares no resources the host links against).
set -euo pipefail
# Every path made absolute: the zipper extracts into the working directory
# (its -d is relative to it), so extraction runs from inside the work tree.
abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
zipper="$(abs "$1")" out="$(abs "$2")" manifest="$3" proguard="$4" abi="$5"
shift 5
jars=() libs=() mode=""
for arg in "$@"; do
    case "$arg" in
        --jars) mode=jars ;;
        --libs) mode=libs ;;
        *) if [ "$mode" = jars ]; then jars+=("$arg"); else libs+=("$arg"); fi ;;
    esac
done
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/classes" "$work/aar/jni/$abi"
for jar in "${jars[@]}"; do
    jar="$(abs "$jar")"
    (cd "$work/classes" && "$zipper" x "$jar" > /dev/null)
done
find "$work/classes" \( -name 'R.class' -o -name 'R$*.class' \) -delete
rm -rf "$work/classes/META-INF"
entries=()
while IFS= read -r file; do
    entries+=("${file#"$work/classes/"}=$file")
done < <(find "$work/classes" -type f | LC_ALL=C sort)
"$zipper" cC "$work/aar/classes.jar" "${entries[@]}" > /dev/null
for lib in "${libs[@]}"; do cp "$lib" "$work/aar/jni/$abi/$(basename "$lib")"; done
cp "$manifest" "$work/aar/AndroidManifest.xml"
cp "$proguard" "$work/aar/proguard.txt"
: > "$work/aar/R.txt"
aar_entries=()
while IFS= read -r file; do
    aar_entries+=("${file#"$work/aar/"}=$file")
done < <(find "$work/aar" -type f | LC_ALL=C sort)
"$zipper" cC "$out" "${aar_entries[@]}" > /dev/null
