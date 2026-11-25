#!/bin/bash
# Opens :embedded_aar (BUILD.bazel) and checks what isomer_android_aar's
# attributes put in it, and what they leave out.
#
#   check_aar.sh <zipper> <embedded_aar.aar>
set -euo pipefail
abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
zipper="$(abs "$1")" aar="$(abs "$2")"
work="${TEST_TMPDIR:-$(mktemp -d)}/aar"
rm -rf "$work" && mkdir -p "$work/aar" "$work/classes"
# The zipper extracts into the working directory.
(cd "$work/aar" && "$zipper" x "$aar" > /dev/null)
(cd "$work/classes" && "$zipper" x "$work/aar/classes.jar" > /dev/null)

failures=0
has() {
    if [ -e "$work/$1" ]; then echo "ok: $1"; else echo "FAIL: $1 is missing ($2)"; failures=$((failures + 1)); fi
}
lacks() {
    if [ -e "$work/$1" ]; then echo "FAIL: $1 is there ($2)"; failures=$((failures + 1)); else echo "ok: no $1"; fi
}
# An ELF shared object for arm64-v8a: e_machine (two bytes at 18) is
# EM_AARCH64, 183.
arm64() {
    local machine
    machine="$(od -An -tu2 -j18 -N2 "$work/$1" 2> /dev/null | tr -d ' ')"
    if [ "$machine" = 183 ]; then echo "ok: $1 is arm64"; else echo "FAIL: $1's machine is ${machine:-unreadable}, not arm64's 183"; failures=$((failures + 1)); fi
}

has aar/AndroidManifest.xml "the library's manifest"
has aar/proguard.txt "the consumer rules"
# The app's Swift, and the further libraries (extra_native_libs), built for
# the AAR's ABI.
has aar/jni/arm64-v8a/libembedded_aar_runtime_bindings.so "the app's Swift"
has aar/jni/arm64-v8a/libaar_extra.so "a cc_binary in extra_native_libs"
has aar/jni/arm64-v8a/libaar_prebuilt.so "a cc_library's prebuilt .so in extra_native_libs"
[ ! -e "$work/aar/jni/arm64-v8a/libaar_extra.so" ] || arm64 aar/jni/arm64-v8a/libaar_extra.so
[ ! -e "$work/aar/jni/arm64-v8a/libaar_prebuilt.so" ] || arm64 aar/jni/arm64-v8a/libaar_prebuilt.so
# assets, fonts and resources, as isomer_android_app lays them out.
has aar/assets/hello.txt "assets, at assets/'s root"
has aar/assets/fonts/Fixture.ttf "fonts, in assets/fonts/ for Font.custom"
has aar/assets/bundle/Data.json "resources, in assets/bundle/ for Bundle.main"
has aar/assets/bundle/fr.lproj/Localizable.strings "a resource in its .lproj folder"
has aar/assets/bundle/de.lproj/Strings.strings "a Swift library's data, in its .lproj folder"
lacks aar/assets/bundle/Contents.json "an asset catalog, which rules_apple compiles"
# classes.jar: the app's and Isomer's, not the host's.
has classes/dev/isomer/aartest/MainActivity.class "the app's entry activity"
has classes/dev/isomer/runtime/IsomerRuntime.class "Isomer's runtime"
lacks classes/dev/isomer/aartest/host/HostSdk.class "provided_deps are the host's"
lacks classes/dev/isomer/aartest/host/CompileOnly.class "a neverlink library is never packed"
lacks classes/androidx "AndroidX is the host's (provided_by_name)"
lacks classes/kotlin "Kotlin's standard library is the host's (provided_by_name)"

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed"; exit 1; }
echo "embedded_aar: every check passed"
