#!/bin/bash
# Builds the Android Playground OPTIMIZED, checks what it packaged, installs
# it on a connected device, and compiles it ahead of time there. It does not
# launch the app.
#
#   tools/install_android.sh [device serial]
#
# Built here, every time, and never installed from a path left by an earlier
# build: the 0.19 release put an APK on a phone that had been built minutes
# before the last fix to the "Run on the web" site, and its page was blank
# though the tagged source was right.
#
# Always `-c opt`: a fastbuild APK is debuggable, so ART runs its Kotlin and
# Compose largely interpreted, and its Swift is unoptimized.
set -euo pipefail
cd "$(dirname "$0")/.."
SERIAL="${1:-${ANDROID_SERIAL:-}}"
TARGET=//android/playground_android_application:playground_android_application_apk
PACKAGE=com.LoganShire.Isomer
bazel build -c opt "$TARGET"
APK="$(bazel cquery -c opt --output=files "$TARGET" 2>/dev/null | grep -v unsigned | grep '\.apk$' | head -1)"
# The "Run on the web" site inside it holds every module its page imports
# (the same walk the site's own test does, on the packaged copy).
CHECK="$(mktemp -d)"; trap 'rm -rf "$CHECK"' EXIT
unzip -q -o "$APK" assets/web_site.zip -d "$CHECK"
unzip -q -o "$CHECK/assets/web_site.zip" -d "$CHECK/site"
IMPORTS="$(find -L "$(bazel info output_base)/external" -maxdepth 4 -path '*isomer*/tools/wasm/site_imports_test.py' 2>/dev/null | head -1)"
[ -n "$IMPORTS" ] || { echo "isomer's site_imports_test.py not found in the output base" >&2; exit 1; }
python3 "$IMPORTS" "$CHECK/site" index.html
ADB="$(find -L "$(bazel info output_base)/external" -maxdepth 4 -path '*androidsdk*platform-tools*' -name adb -type f 2>/dev/null | head -1)"
ADB="${ADB:-adb}"
"$ADB" ${SERIAL:+-s "$SERIAL"} install -r "$APK"
# Compile it ahead of time now. A sideloaded app otherwise runs its Kotlin
# and Compose interpreted and JIT-compiled until the phone's idle maintenance
# gets to it (the Play Store does this at install): on a mid-range phone that
# is the renderer's half of every frame.
"$ADB" ${SERIAL:+-s "$SERIAL"} shell cmd package compile -m speed -f "$PACKAGE" >/dev/null
# Not launched: installing is all this does (AGENTS.md: a phone that is a
# person's own is installed on when asked, and left alone).
"$ADB" ${SERIAL:+-s "$SERIAL"} shell dumpsys package "$PACKAGE" | grep -E "versionName|versionCode" || true
echo "installed $APK"
