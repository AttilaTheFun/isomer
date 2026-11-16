# Sourced by the launchers: the test's requests (HeadlessApp's `picture`
# and `quit`), files in ISOMER_LAUNCHER_REQUESTS.
#
# - <n>.request: a picture, its first line the path to write it to, then
#   lines of KEY=VALUE about the app as it stands (orientation=<the
#   interface's: portrait, portrait-upside-down, landscape-left,
#   landscape-right; none where the platform has no such thing>).
#   Or, its first line `scene:<phase>` (HeadlessApp's `scene`): the app's
#   scene moved by the platform itself (active, inactive, background), by a
#   launcher that defines `scene <phase>` (Android's: the app sent home and
#   brought back); answered in <n>.answer, `ok`, or why not, when the
#   test's driver command moves it instead.
# - stop: the test is done with the app (`quit`), seen within a poll: the
#   launcher ends, as SIGTERM ends it, so a test needn't wait out a signal
#   that a platform (Windows) doesn't deliver.
#
# `serve_requests <take>` runs until the launcher is stopped, calling
# `<take> <path> <orientation>` for each picture and removing the request
# once answered (a launcher that can't picture its platform answers none).
# Started in the background by a launcher that waits on its app, it stops
# that launcher (its $$) with SIGTERM, whose trap ends the app.
serve_requests() {
    local take="$1" request path orientation
    while true; do
        if [ -n "${ISOMER_LAUNCHER_REQUESTS:-}" ]; then
            if [ -e "$ISOMER_LAUNCHER_REQUESTS/stop" ]; then
                kill -TERM $$ 2> /dev/null
                return 0
            fi
            for request in "$ISOMER_LAUNCHER_REQUESTS"/*.request; do
                [ -e "$request" ] || continue
                path="$(head -1 "$request")"
                case "$path" in
                scene:*)
                    if declare -F scene > /dev/null && scene "${path#scene:}"; then
                        echo ok > "${request%.request}.answer"
                    else
                        echo "the launcher doesn't move the scene to ${path#scene:}" > "${request%.request}.answer"
                    fi
                    ;;
                *)
                    orientation="$(sed -n 's/^orientation=//p' "$request")"
                    "$take" "$path" "$orientation" || echo "launcher: no picture for $path" >&2
                    ;;
                esac
                rm -f "$request"
            done
        fi
        sleep 0.05
    done
}

# Whether the app starts with none of its data from before: ISOMER_FRESH,
# 1 (the default, as HeadlessApp's own: a test's app starts as an app built
# headless does, with nothing kept from another test) or 0 (its files,
# defaults and caches kept, for a test of what lasts between launches).
fresh() { [ "${ISOMER_FRESH:-1}" != 0 ]; }

# A launcher's arguments after the hub's URL and the app's name:
# KEY=VALUE pairs (the app's environment), then, after `--`, the app's own
# command-line arguments (`-NSTextInsertionPointBlinkPeriodOn 100000`, a
# UserDefaults argument domain's `-key value`). `split_arguments "$@"` sets
# `pairs` and `app_arguments`.
split_arguments() {
    pairs=()
    app_arguments=()
    while [ $# -gt 0 ]; do
        if [ "$1" = -- ]; then
            shift
            app_arguments=("$@")
            return
        fi
        pairs+=("$1")
        shift
    done
}
