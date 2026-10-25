#!/usr/bin/env python3
"""Fills the oss server's Bazel cache with this checkout's builds. The cache
finds an action by its exact command, so a build fills it for whoever runs
the same build the same way:

  * Agents' containers (Visor's sessions in a Linux container): built in
    a throwaway container of the image their containers are made from
    (visor-agent:latest), with this checkout where a session sees isomer
    (~/Developer/isomer, the runner's own home: a session's folder is at
    the same path inside as on the Mac), at a session's default size, and
    removed after (Bazel's output with it; the cache keeps what was built).
    Each module's tests, and the Linux, web and Android apps the proof
    builds.
  * This Mac's builds (the proof's Apple builds, and a Mac that reads the
    cache with `oss cache use`): the proof's builds with its flags.

  OSS_CACHE_HOST=<the oss server's address> OSS_CACHE_WRITE_TOKEN=<token> \\
      tools/ci/populate_cache.py [--dry-run]

The write token goes into a .netrc of this run's own (mode 600, removed at
the end; mounted into the container, named by NETRC there), never onto a
command line; Bazel's HTTP cache reads credentials from the file NETRC
names. CI's `Bazel cache` workflow runs it after each merge to main
(.github/workflows/cache.yml), with the token from an environment only main
may use.
"""
import os, shlex, subprocess, sys, tempfile

ISOMER = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXAMPLES = os.path.join(ISOMER, "examples")

# The image Visor makes sessions' containers from, and where a session sees
# isomer: the runner runs as the Mac's user, so its home is theirs.
IMAGE = os.environ.get("ISOMER_CACHE_IMAGE", "visor-agent:latest")
SESSION_PATH = os.environ.get("ISOMER_SESSION_PATH", os.path.join(os.path.expanduser("~"), "Developer", "isomer"))
# The oss server as a container reaches it: the Mac, the default network's
# gateway (Apple's container, 192.168.64.0/24).
CONTAINER_HOST = os.environ.get("OSS_CACHE_CONTAINER_HOST", "192.168.64.1")

# (directory under isomer, flags, targets), in the container: what agents
# run most, each module's tests at Bazel's default settings, and the
# proof's Linux, web and Android builds with its flags.
CONTAINER_BUILDS = [
    ("", ["test", "--keep_going"], ["//..."]),
    ("examples", ["test", "--keep_going"], ["//..."]),
    ("examples", ["build", "-c", "opt"], [
        "//linux/storybook_linux_application:storybook_linux_application_bin",
        "//playground/linux/playground_linux_application:playground_linux_application_bin",
        "//playground/linux/playground_linux_application:playground_wasm_loader",
        "//web/storybook_web_application:storybook_web_application_site",
        "//playground/web/splash_web_application:site",
        "//android/storybook_android_application:storybook_android_application_apk",
        "//playground/android/playground_android_application:playground_android_application_apk",
    ]),
]

# (directory under isomer, flags, targets), on this Mac: the proof's builds
# (tools/proof/proof.py's build_ios, build_macos), flag for flag, and the
# Mac's tests.
MAC_BUILDS = [
    ("examples", ["build", "-c", "opt", "--ios_multi_cpus=sim_arm64"],
     ["//apple/storybook_ios_application:storybook_ios_sim_application", "//apple/storybook_isomer_ios_application"]),
    ("examples", ["build", "-c", "opt", "--ios_multi_cpus=sim_arm64", "--define", "iso_playground_embedded=1"],
     ["//playground/apple/playground_ios_application"]),
    ("examples", ["build", "-c", "opt"],
     ["//apple/storybook_macos_application", "//playground/apple/playground_macos_application"]),
    ("", ["test"], ["//..."]),
    ("examples", ["test"], ["//..."]),
]

# The size a session's container gets by default (Visor's New Session).
CONTAINER_SIZE = ["--cpus", "6", "--memory", "16g"]


def run(command, dry_run, **kwargs):
    print("$ " + " ".join(shlex.quote(part) for part in command), flush=True)
    return 0 if dry_run else subprocess.run(command, **kwargs).returncode


def bazel_line(directory, flags, targets, cache):
    """A Bazel command, as a shell line run from isomer's root."""
    verb, rest = flags[0], flags[1:]
    command = ["bazel", verb, cache, *rest, *targets]
    return f"(cd {shlex.quote(directory or '.')} && {' '.join(shlex.quote(part) for part in command)})"


def main():
    dry_run = "--dry-run" in sys.argv
    host, token = os.environ.get("OSS_CACHE_HOST"), os.environ.get("OSS_CACHE_WRITE_TOKEN")
    if not dry_run and (not host or not token):
        sys.exit("populate_cache.py needs OSS_CACHE_HOST and OSS_CACHE_WRITE_TOKEN")
    host = host or "<oss host>"
    work = tempfile.mkdtemp(prefix="oss-cache-")
    netrc = os.path.join(work, "netrc")
    with os.fdopen(os.open(netrc, os.O_WRONLY | os.O_CREAT, 0o600), "w") as file:
        # The same token under both names the cache is reached by.
        for name in (host, CONTAINER_HOST):
            file.write(f"machine {name} login bazel password {token or ''}\n")
    environment = dict(os.environ, NETRC=netrc)
    environment.pop("OSS_CACHE_WRITE_TOKEN", None)
    failed = []
    try:
        # In a container like a session's: one shell, each build's failure
        # noted and the rest carried on (a failing test is still a result
        # worth keeping; --keep_going builds what can be built).
        cache = f"--remote_cache=http://{CONTAINER_HOST}:7490"
        lines = [f"{bazel_line(d, f, t, cache)} || echo FAILED: {shlex.quote(' '.join([d or '.', *f]))} >> /tmp/failed"
                 for d, f, t in CONTAINER_BUILDS]
        script = "rm -f /tmp/failed; " + "; ".join(lines) + "; test ! -s /tmp/failed || { cat /tmp/failed; exit 1; }"
        print(f"== in {IMAGE}, at {SESSION_PATH}", flush=True)
        if run(["container", "run", "--rm", *CONTAINER_SIZE,
                "--volume", f"{ISOMER}:{SESSION_PATH}", "--volume", f"{work}:/run/oss-cache",
                "--env", "NETRC=/run/oss-cache/netrc", "--workdir", SESSION_PATH,
                IMAGE, "bash", "-c", script], dry_run, env=environment) != 0:
            failed.append("the container's builds")

        # On this Mac.
        cache = f"--remote_cache=http://{host}:7490"
        for directory, flags, targets in MAC_BUILDS:
            print(f"== {directory or '.'}: {' '.join(flags)} {' '.join(targets)}", flush=True)
            verb, rest = flags[0], flags[1:]
            status = run(["bazel", verb, cache, *rest, *targets], dry_run,
                         cwd=os.path.join(ISOMER, directory), env=environment)
            # bazel test's 3: built, a test failed (still worth keeping).
            if status not in ((0, 3) if verb == "test" else (0,)):
                failed.append(f"{directory or '.'}: {' '.join(flags)}")
    finally:
        os.remove(netrc)
        os.rmdir(work)
    if failed:
        sys.exit("failed: " + "; ".join(failed))
    print("the cache has main's builds")


if __name__ == "__main__":
    main()
