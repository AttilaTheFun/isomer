#!/bin/bash
# Checks an APK whose app links the NDK's shared C++ runtime (check.bzl):
#
#   check.sh <llvm-nm> <llvm-objdump> <zipper> <app.apk> <abi> <library> <out>
#
# - lib/<abi>/ holds libc++_shared.so beside the app's library;
# - the app's library needs libc++_shared.so (DT_NEEDED) and takes libc++
#   from it (its C++ runtime's symbols undefined there);
# - it defines none of what libc++_shared.so exports: no second libc++ in
#   it, static and hidden (its whole symbol table read, not just what it
#   exports).
# <out> is a summary, the evidence.
set -euo pipefail
abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
nm="$(abs "$1")" objdump="$(abs "$2")" zipper="$(abs "$3")" apk="$(abs "$4")"
abi="$5" library="$6" out="$(abs "$7")"
fail() { echo "android_libcxx_shared: $*" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The zipper extracts into the working directory.
(cd "$work" && "$zipper" x "$apk" > /dev/null)
lib="$work/lib/$abi/$library"
libcxx="$work/lib/$abi/libc++_shared.so"
[ -f "$lib" ] || fail "no lib/$abi/$library in the APK"
[ -f "$libcxx" ] || fail "no lib/$abi/libc++_shared.so in the APK"
# Symbol names alone, without a version (name@VERSION).
symbols() { "$nm" "$@" --format=just-symbols | sed 's/@.*//' | LC_ALL=C sort -u; }
"$objdump" -p "$lib" | awk '$1 == "NEEDED" { print $2 }' > "$work/needed"
grep -qx 'libc++_shared.so' "$work/needed" ||
    fail "$library doesn't need libc++_shared.so (it needs: $(tr '\n' ' ' < "$work/needed"))"
# libc++'s and libc++abi's own (C++ names, __cxa_*, the personality).
symbols -D --defined-only "$libcxx" | grep -E '^(_Z|__cxa_|__gxx_|__dynamic_cast)' > "$work/libcxx" || true
[ -s "$work/libcxx" ] || fail "libc++_shared.so exports no C++ runtime symbols"
symbols --defined-only "$lib" > "$work/defined"
grep -q '^Java_' "$work/defined" || fail "$library has no symbol table to read (built stripped?)"
LC_ALL=C comm -12 "$work/libcxx" "$work/defined" > "$work/both"
if [ -s "$work/both" ]; then
    fail "$library defines $(wc -l < "$work/both" | tr -d ' ') of libc++_shared.so's symbols, a libc++ of its own: $(head -n 10 "$work/both" | tr '\n' ' ')"
fi
symbols -D --undefined-only "$lib" > "$work/undefined"
LC_ALL=C comm -12 "$work/libcxx" "$work/undefined" > "$work/taken"
[ -s "$work/taken" ] || fail "$library takes nothing from libc++_shared.so"
{
    echo "lib/$abi/: $(cd "$work/lib/$abi" && ls | tr '\n' ' ')"
    echo "$library needs: $(tr '\n' ' ' < "$work/needed")"
    echo "$library takes $(wc -l < "$work/taken" | tr -d ' ') of libc++_shared.so's $(wc -l < "$work/libcxx" | tr -d ' ') C++ runtime symbols, among them: $(grep -E '^(__cxa_throw|__gxx_personality_v0|__dynamic_cast)$' "$work/taken" | tr '\n' ' ')"
    echo "$library defines none of them ($(wc -l < "$work/defined" | tr -d ' ') symbols defined)"
} > "$out"
