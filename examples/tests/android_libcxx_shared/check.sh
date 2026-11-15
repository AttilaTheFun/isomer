#!/bin/bash
# Checks an APK or AAR whose app links the NDK's shared C++ runtime
# (check.bzl):
#
#   check.sh <llvm-nm> <llvm-objdump> <zipper> <archive> <abi> <library> <out> \
#            <dir> [<libc++_shared.so>]
#
# <dir> is where the archive keeps native libraries: lib (an APK) or jni
# (an AAR). Given the NDK's <libc++_shared.so>, the archive must not carry
# one (an AAR leaves it to its host), and the checks read that one.
#
# - <dir>/<abi>/ holds libc++_shared.so beside the app's library (an APK);
# - the app's library needs libc++_shared.so (DT_NEEDED) and takes libc++
#   from it (its C++ runtime's symbols undefined there);
# - it defines none of what libc++_shared.so exports: no second libc++ in
#   it, static and hidden (its whole symbol table read, not just what it
#   exports).
# <out> is a summary, the evidence.
set -euo pipefail
abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
nm="$(abs "$1")" objdump="$(abs "$2")" zipper="$(abs "$3")" archive="$(abs "$4")"
abi="$5" library="$6" out="$(abs "$7")" dir="$8" given="${9:+$(abs "$9")}"
fail() { echo "android_libcxx_shared: $*" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The zipper extracts into the working directory.
(cd "$work" && "$zipper" x "$archive" > /dev/null)
lib="$work/$dir/$abi/$library"
libcxx="$work/$dir/$abi/libc++_shared.so"
[ -f "$lib" ] || fail "no $dir/$abi/$library in $(basename "$archive")"
if [ -n "$given" ]; then
    [ ! -e "$libcxx" ] || fail "$(basename "$archive") carries $dir/$abi/libc++_shared.so, which its host supplies"
    libcxx="$given"
else
    [ -f "$libcxx" ] || fail "no $dir/$abi/libc++_shared.so in $(basename "$archive")"
fi
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
note=""
[ -z "$given" ] || note=" (libc++_shared.so left to the host; the NDK's read)"
{
    echo "$dir/$abi/: $(cd "$work/$dir/$abi" && ls | tr '\n' ' ')$note"
    echo "$library needs: $(tr '\n' ' ' < "$work/needed")"
    echo "$library takes $(wc -l < "$work/taken" | tr -d ' ') of libc++_shared.so's $(wc -l < "$work/libcxx" | tr -d ' ') C++ runtime symbols, among them: $(grep -E '^(__cxa_throw|__gxx_personality_v0|__dynamic_cast)$' "$work/taken" | tr '\n' ' ')"
    echo "$library defines none of them ($(wc -l < "$work/defined" | tr -d ' ') symbols defined)"
} > "$out"
