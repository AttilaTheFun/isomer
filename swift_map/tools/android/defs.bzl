"""`bazel run`-able APK install/launch wrapper over the hermetic emulator."""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

def apk_install_run(name, apk, activity, extras = "", **kwargs):
    """Installs the APK via adb and launches `activity`.

    If no device/emulator is connected, the hermetic emulator is booted
    automatically (windowed) and the script waits for it before installing.
    `bazel run` starts with CWD at <runfiles>/_main, so rlocationpaths
    resolve against the parent directory.
    """
    script_name = name + "_run.sh"
    write_file(
        name = name + "_script",
        out = script_name,
        content = [
            "#!/bin/bash",
            "set -euo pipefail",
            'RUNFILES_ROOT="$PWD/.."',
            'APK="$RUNFILES_ROOT/$1"',
            'ADB="$RUNFILES_ROOT/$2"',
            'EMULATOR_SH="$RUNFILES_ROOT/$3"',
            "",
            "has_device() {",
            '  "$ADB" devices | awk \'NR>1 && $2 == "device"\' | grep -q .',
            "}",
            "",
            '"$ADB" start-server >/dev/null 2>&1 || true',
            "if ! has_device; then",
            '  echo "No device connected; booting the hermetic emulator..."',
            '  EMULATOR_LOG="${TMPDIR:-/tmp}/swift_map_emulator/emulator.log"',
            '  mkdir -p "$(dirname "$EMULATOR_LOG")"',
            # The emulator script consumes args $4..$6 (emulator binary,
            # system image marker, adb) and passes the rest to the emulator.
            '  "$EMULATOR_SH" "$4" "$5" "$6" >"$EMULATOR_LOG" 2>&1 &',
            '  echo "  (emulator log: $EMULATOR_LOG)"',
            '  "$ADB" wait-for-device',
            "  for _ in $(seq 1 120); do",
            # Wait for boot AND the package manager: installing immediately
            # after sys.boot_completed flips races a "Broken pipe" failure.
            '    if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d \'\\r\')" = "1" ] && "$ADB" shell cmd package path android >/dev/null 2>&1; then break; fi',
            "    sleep 2",
            "  done",
            "  if ! has_device; then",
            '    echo "error: emulator failed to boot; see $EMULATOR_LOG" >&2',
            "    exit 1",
            "  fi",
            '  echo "Emulator booted."',
            "fi",
            '"$ADB" install -r "$APK"',
            '"$ADB" shell am start -S -n "{}" {}'.format(activity, extras),
            'echo "Launched {}; streaming logcat (Ctrl-C to stop)"'.format(activity),
            'exec "$ADB" logcat -s SwiftMap:* AndroidRuntime:* "*:F"',
        ],
        is_executable = True,
    )
    sh_binary(
        name = name,
        srcs = [script_name],
        args = [
            "$(rlocationpath %s)" % apk,
            "$(rlocationpath @android_platform_tools//:adb)",
            "$(rlocationpath //swift_map/tools/android/emulator:run_emulator.sh)",
            "$(rlocationpath @android_emulator//:emulator/emulator)",
            "$(rlocationpath @android_system_image//:system.img)",
            "$(rlocationpath @android_platform_tools//:adb)",
        ],
        data = [
            apk,
            "//swift_map/tools/android/emulator:run_emulator.sh",
            "@android_emulator//:all",
            "@android_emulator//:emulator/emulator",
            "@android_platform_tools//:adb",
            "@android_system_image//:all",
            "@android_system_image//:system.img",
        ],
        **kwargs
    )
