#!/bin/bash
# A Mac app, headful, for a test's HeadlessApp (docs/drive.md): built with
# --@isomer//drive:headful, so its driver dials out, run with ISO_DRIVER and
# ISO_DRIVER_NAME in its environment, light, with a home of its own, until
# this is stopped (SIGTERM, or HeadlessApp's `stop` request). Pictures (a
# test's `picture`) are its window's alone.
#
#   macos_launcher.sh <the hub's ws:// URL> <the app's name> [KEY=VALUE…] [-- <argument>…]
#
# The arguments after `--` are the app's own, after the launcher's
# (`-NSTextInsertionPointBlinkPeriodOn 100000`, a `-key value` of
# UserDefaults' argument domain: a later one wins). From the test's
# environment: ISOMER_MAC_APP, the .app, and ISOMER_FRESH (requests.sh: 1,
# the default, starts it with none of its data from before: its defaults
# deleted, through cfprefsd, which keeps them by the user's own home
# whatever CFFIXED_USER_HOME says, and its home emptied; 0 keeps both). The
# home is the app's own, in the temporary directory, the same every launch.
set -uo pipefail
. "$(dirname "$0")/requests.sh"
url="${1:?usage: macos_launcher.sh <hub url> <name> [KEY=VALUE…]}"
name="${2:?<name>}"
shift 2
app="${ISOMER_MAC_APP:?ISOMER_MAC_APP: the Mac app}"
binary="$app/Contents/MacOS/$(defaults read "$app/Contents/Info" CFBundleExecutable)"
split_arguments "$@"
environment=(ISO_DRIVER="$url" ISO_DRIVER_NAME="$name")
for pair in ${pairs[@]+"${pairs[@]}"}; do
    case "${pair%%=*}" in
        ISO_HEADLESS_WIDTH | ISO_HEADLESS_HEIGHT) ;;
        *) environment+=("$pair") ;;
    esac
done
bundle_id="$(defaults read "$app/Contents/Info" CFBundleIdentifier)"
home="${TMPDIR:-/tmp}/isomer-mac-home-$bundle_id"
if fresh; then
    defaults delete "$bundle_id" > /dev/null 2>&1
    rm -rf "$home"
fi
mkdir -p "$home"
env "${environment[@]}" CFFIXED_USER_HOME="$home" "$binary" -AppleInterfaceStyle Light \
    -ApplePersistenceIgnoreState YES -AppleShowScrollBars WhenScrolling ${app_arguments[@]+"${app_arguments[@]}"} \
    > "$home/app.log" 2>&1 &
pid=$!
stop() {
    kill "$pid" 2> /dev/null || true
    wait "$pid" 2> /dev/null || true
    exit 0
}
trap stop TERM INT
# The app's largest window, by CoreGraphics' window list (no permission
# needed), pictured alone.
cat > "$home/window.js" << 'SCRIPT'
ObjC.import('CoreGraphics');
function run(argv) {
  const pid = Number(argv[0]);
  const list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo(
    $.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, 0));
  let number = '', area = 0;
  for (let i = 0; i < list.count; i++) {
    const w = list.objectAtIndex(i);
    if (ObjC.unwrap(w.objectForKey('kCGWindowOwnerPID')) !== pid) continue;
    if (ObjC.unwrap(w.objectForKey('kCGWindowLayer')) !== 0) continue;
    const b = w.objectForKey('kCGWindowBounds');
    const a = ObjC.unwrap(b.objectForKey('Width')) * ObjC.unwrap(b.objectForKey('Height'));
    if (a > area) { area = a; number = String(ObjC.unwrap(w.objectForKey('kCGWindowNumber'))); }
  }
  return number;
}
SCRIPT
take() {
    local number
    number="$(osascript -l JavaScript "$home/window.js" "$pid" 2> /dev/null)"
    [ -n "$number" ] && screencapture -x -o -l "$number" "$1"
}
serve_requests take &
wait "$pid"
