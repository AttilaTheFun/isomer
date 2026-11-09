# Sourced by the launchers: the test's picture requests (HeadlessApp's
# `picture`), each a file <n>.request in ISOMER_LAUNCHER_REQUESTS naming
# the picture's path. `serve_requests <take>` runs until the launcher is
# stopped, calling `<take> <path>` for each request and removing it once
# answered; a launcher that can't picture its platform answers none.
serve_requests() {
    local take="$1" request path
    while true; do
        if [ -n "${ISOMER_LAUNCHER_REQUESTS:-}" ]; then
            for request in "$ISOMER_LAUNCHER_REQUESTS"/*.request; do
                [ -e "$request" ] || continue
                path="$(cat "$request")"
                "$take" "$path" || echo "launcher: no picture for $path" >&2
                rm -f "$request"
            done
        fi
        sleep 0.2
    done
}
