"""Serves a built static site from Bazel runfiles on localhost and opens it
in the default browser (pass --no-open to disable, e.g. for CI)."""

import http.server
import mimetypes
import os
import sys
import threading
import webbrowser


class Server(http.server.ThreadingHTTPServer):
    # socketserver listens with a backlog of 5. A page asks for a dozen
    # runtime modules at once, and the connections past the backlog were
    # reset now and then: one failed import leaves the page's module graph
    # unevaluated, boot() never runs, and the page stays blank without an
    # error (about one cold load in eight; none in 30 at 128).
    request_queue_size = 128


def main() -> None:
    args = [a for a in sys.argv[1:] if a != "--no-open"]
    open_browser = "--no-open" not in sys.argv[1:]
    site_rootpath = args[0]
    port = int(args[1]) if len(args) > 1 else 8080
    # Optional query string for the opened URL (e.g. "renderer=react" picks
    # the layered renderer binding; see docs/renderer_layers.md).
    query = f"?{args[2]}" if len(args) > 2 and args[2] else ""

    # The site path is a MAIN-repo rootpath, but serve.py may live in another
    # repo's runfiles dir (isomer as a dependency of the caller's
    # module). Resolve against the caller first: `bazel run` starts in
    # <runfiles>/_main, so the rootpath usually works as-is; otherwise derive
    # the runfiles root from this script's own repo dir and look under _main
    # (and at the root, for repo-qualified rlocation-style paths).
    script_repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    runfiles_root = os.path.dirname(script_repo)
    candidates = [
        site_rootpath,
        os.path.join(runfiles_root, "_main", site_rootpath),
        os.path.join(runfiles_root, site_rootpath),
        os.path.join(script_repo, site_rootpath),
    ]
    directory = next((c for c in candidates if os.path.isdir(c)), None)
    if directory is None:
        sys.exit("site directory not found; tried:\n  " + "\n  ".join(candidates))
    directory = os.path.abspath(directory)

    mimetypes.add_type("application/wasm", ".wasm")
    mimetypes.add_type("text/javascript", ".js")

    handler = lambda *args, **kwargs: http.server.SimpleHTTPRequestHandler(
        *args, directory=directory, **kwargs
    )
    url = f"http://127.0.0.1:{port}/{query}"
    server = Server(("127.0.0.1", port), handler)
    print(f"Serving {site_rootpath}")
    print(f"  -> {url}  (Ctrl-C to stop)")
    if open_browser:
        threading.Timer(0.3, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
