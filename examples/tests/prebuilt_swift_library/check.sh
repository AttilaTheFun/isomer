#!/bin/bash
# Checks an app's APK that takes a prebuilt Swift library (check.bzl;
# docs/prebuilt_swift_libraries.md in isomer):
#
#   check.sh <llvm-nm> <llvm-objdump> <zipper> <apk> <abi> <library> <out> \
#            <Module,Module…> archive <lib<Module>.a>…
#   check.sh … <Module,Module…> shared <lib<name>.so>
#
# archive (route b, the static archives linked into the app's one library):
# - the app's library needs no Foundation of the Swift SDK's (no
#   libFoundation*.so) and holds no CoreFoundation runtime (CFRunLoop,
#   CFString), which only corelibs' Foundation brings: its one Foundation is
#   Isomer's, which it defines;
# - it defines each module's symbols from the archives (those the linker
#   keeps: it drops what nothing reaches, unused property descriptors say);
# - none of the Swift symbols the archives use and don't define (Isomer's
#   Foundation and SwiftUI, the standard library, the runtime) is left
#   undefined in it for another library at load, and Foundation's are
#   defined in it: their code runs on the app's own copy of Isomer;
# - the archives define (strongly) none of Foundation's own symbols: they
#   carry no Foundation of their own.
# shared (route a, a shared library over Isomer's shared platform):
# - lib/<abi>/ holds libisomer_platform.so, the app's library and the
#   prebuilt library;
# - the prebuilt library needs libisomer_platform.so, exports its modules'
#   symbols, takes Foundation from the platform, and every Swift symbol it
#   uses and doesn't define is one the platform exports;
# - the app's library needs both, and takes the modules' symbols from the
#   prebuilt library;
# - neither defines (strongly) any Swift symbol the platform exports: one
#   runtime, one Foundation, one Isomer in the process.
# <out> is a summary, the evidence.
set -euo pipefail
abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
nm="$(abs "$1")" objdump="$(abs "$2")" zipper="$(abs "$3")" apk="$(abs "$4")"
abi="$5" library="$6" out="$(abs "$7")" modules="$8" route="$9"
shift 9
fail() { echo "prebuilt_swift_library: $*" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
(cd "$work" && "$zipper" x "$apk" > /dev/null)
libs="$work/lib/$abi"
lib="$libs/$library"
[ -f "$lib" ] || fail "no lib/$abi/$library in $(basename "$apk")"

# Symbol names, without a version (name@VERSION), sorted for comm.
names() { sed 's/@.*//' | LC_ALL=C sort -u; }
# Swift's: mangled names ($s…) and the runtime's entry points (swift_…).
swift_only() { grep -E '^(\$s|swift_)' || true; }
# Strongly defined symbols (not weak: a client may emit its own weak copy
# of a lazy witness-table cache or a metadata accessor; the linker keeps one).
strong() { "$nm" "$@" --defined-only --format=posix | awk 'NF >= 2 && $2 !~ /^[WwVv]$/ { print $1 }' | names; }
undefined() { "$nm" "$@" --undefined-only --format=just-symbols | names; }
needed() { "$objdump" -p "$1" | awk '$1 == "NEEDED" { print $2 }'; }
count() { wc -l < "$1" | tr -d ' '; }
# A module's symbols: $s<length><name>.
prefixes="$(tr ',' '\n' <<< "$modules" | awk 'NF { printf "%s^\\$s%d%s", (n++ ? "|" : ""), length($0), $0 }')"
FOUNDATION='^\$s(10Foundation|20FoundationEssentials)'

needed "$lib" > "$work/needed"
"$nm" --defined-only --format=just-symbols "$lib" | names > "$work/defined"
grep -q '^Java_' "$work/defined" || fail "$library has no symbol table to read (built stripped?)"

case "$route" in
archive)
    [ $# -gt 0 ] || fail "no archives"
    ! grep -E 'Foundation' "$work/needed" > /dev/null ||
        fail "$library needs the Swift SDK's Foundation: $(tr '\n' ' ' < "$work/needed")"
    grep -E "$FOUNDATION" "$work/defined" > "$work/foundation" || true
    [ -s "$work/foundation" ] || fail "$library defines no Foundation"
    # CoreFoundation's runtime and its CFRunLoop, CFString: corelibs' alone
    # (Isomer's Foundation, over swift-foundation, carries CF's Unicode
    # tables, __CFUniChar*, in _FoundationCShims, and nothing else of CF).
    grep -E '^(__CFInitialize|_CFRuntimeRegisterClass|CFRunLoop[A-Z]|CFString[A-Z])' "$work/defined" > "$work/cf" || true
    [ ! -s "$work/cf" ] || fail "$library holds CoreFoundation, corelibs' Foundation beside Isomer's: $(head -n 5 "$work/cf" | tr '\n' ' ')"
    : > "$work/archive_defined"
    : > "$work/archive_undefined"
    for archive in "$@"; do
        strong "$archive" | swift_only >> "$work/archive_defined"
        undefined "$archive" | swift_only >> "$work/archive_undefined"
    done
    LC_ALL=C sort -u -o "$work/archive_defined" "$work/archive_defined"
    LC_ALL=C sort -u -o "$work/archive_undefined" "$work/archive_undefined"
    LC_ALL=C comm -12 "$work/archive_defined" "$work/defined" > "$work/kept"
    for module in $(tr ',' ' ' <<< "$modules"); do
        grep -q "^\\\$s${#module}$module" "$work/kept" ||
            fail "$library defines none of $module's symbols from its archive"
    done
    grep -E "$prefixes" "$work/kept" > "$work/own" || true
    LC_ALL=C comm -23 "$work/archive_undefined" "$work/archive_defined" > "$work/uses"
    undefined "$lib" > "$work/lib_undefined"
    LC_ALL=C comm -12 "$work/uses" "$work/lib_undefined" > "$work/unresolved"
    [ ! -s "$work/unresolved" ] ||
        fail "$library leaves $(count "$work/unresolved") of what the archives use undefined: $(head -n 5 "$work/unresolved" | tr '\n' ' ')"
    grep -E "$FOUNDATION" "$work/uses" | LC_ALL=C comm -12 - "$work/defined" > "$work/uses_foundation" || true
    [ -s "$work/uses_foundation" ] || fail "$library defines nothing of Foundation's that the archives use"
    grep -E "$FOUNDATION" "$work/archive_defined" > "$work/own_foundation" || true
    [ ! -s "$work/own_foundation" ] ||
        fail "the archives define Foundation's own symbols: $(head -n 5 "$work/own_foundation" | tr '\n' ' ')"
    {
        echo "lib/$abi/: $(cd "$libs" && ls | tr '\n' ' ')"
        echo "$library needs: $(tr '\n' ' ' < "$work/needed")"
        echo "$library keeps $(count "$work/kept") of the $(count "$work/archive_defined") Swift symbols the archives define ($(count "$work/own") of $modules's own)"
        echo "and leaves none of the $(count "$work/uses") they use undefined; $(count "$work/uses_foundation") of them are Foundation's, defined in it"
        echo "its Foundation: $(count "$work/foundation") symbols defined, no CoreFoundation, no SDK Foundation needed"
    } > "$out"
    ;;
shared)
    shared="$1"
    platform="$libs/libisomer_platform.so"
    prebuilt="$libs/$shared"
    [ -f "$platform" ] || fail "no lib/$abi/libisomer_platform.so in $(basename "$apk")"
    [ -f "$prebuilt" ] || fail "no lib/$abi/$shared in $(basename "$apk")"
    "$nm" -D --defined-only --format=just-symbols "$platform" | names | swift_only > "$work/platform"
    grep -E "$FOUNDATION" "$work/platform" > /dev/null || fail "libisomer_platform.so exports no Foundation"
    needed "$prebuilt" > "$work/prebuilt_needed"
    grep -qx libisomer_platform.so "$work/prebuilt_needed" ||
        fail "$shared doesn't need libisomer_platform.so (it needs: $(tr '\n' ' ' < "$work/prebuilt_needed"))"
    "$nm" -D --defined-only --format=just-symbols "$prebuilt" | names | swift_only > "$work/prebuilt_exports"
    grep -E "$prefixes" "$work/prebuilt_exports" > "$work/own" || true
    [ -s "$work/own" ] || fail "$shared exports none of $modules's symbols"
    undefined -D "$prebuilt" | swift_only > "$work/prebuilt_uses"
    LC_ALL=C comm -23 "$work/prebuilt_uses" "$work/platform" > "$work/unresolved"
    [ ! -s "$work/unresolved" ] ||
        fail "$shared uses $(count "$work/unresolved") Swift symbols the platform doesn't export: $(head -n 5 "$work/unresolved" | tr '\n' ' ')"
    grep -E "$FOUNDATION" "$work/prebuilt_uses" > "$work/uses_foundation" || true
    [ -s "$work/uses_foundation" ] || fail "$shared takes nothing of Foundation's from the platform"
    for file in "$prebuilt" "$lib"; do
        strong "$file" | swift_only > "$work/strong"
        LC_ALL=C comm -12 "$work/strong" "$work/platform" > "$work/both"
        [ ! -s "$work/both" ] ||
            fail "$(basename "$file") defines $(count "$work/both") of the platform's symbols, a copy of its own: $(head -n 5 "$work/both" | tr '\n' ' ')"
    done
    for want in libisomer_platform.so "$shared"; do
        grep -qx "$want" "$work/needed" || fail "$library doesn't need $want (it needs: $(tr '\n' ' ' < "$work/needed"))"
    done
    undefined -D "$lib" | grep -E "$prefixes" > "$work/takes" || true
    [ -s "$work/takes" ] || fail "$library takes nothing of $modules's from $shared"
    LC_ALL=C comm -23 "$work/takes" "$work/prebuilt_exports" > "$work/unresolved"
    [ ! -s "$work/unresolved" ] ||
        fail "$library uses $(count "$work/unresolved") of $modules's symbols $shared doesn't export: $(head -n 5 "$work/unresolved" | tr '\n' ' ')"
    {
        echo "lib/$abi/: $(cd "$libs" && ls | tr '\n' ' ')"
        echo "$shared needs: $(tr '\n' ' ' < "$work/prebuilt_needed")"
        echo "$shared exports $(count "$work/own") of $modules's symbols and takes all $(count "$work/prebuilt_uses") Swift symbols it uses from the platform, $(count "$work/uses_foundation") of them Foundation's"
        echo "$library needs: $(tr '\n' ' ' < "$work/needed")"
        echo "$library takes $(count "$work/takes") of $modules's symbols from $shared"
        echo "neither defines any of the platform's $(count "$work/platform") exported Swift symbols"
    } > "$out"
    ;;
*) fail "route is archive or shared, not $route" ;;
esac
