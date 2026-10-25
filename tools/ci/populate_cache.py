#!/usr/bin/env python3
"""Fills the oss server's Bazel cache with this checkout's builds: what the
release proof builds, with the proof's flags, and each module's tests as
agents run them. The cache finds an action by its exact command, so these
are the builds whose results others read: an oss lease, a container, a Mac
(`oss cache use`) downloads what was built here instead of building it.

  OSS_CACHE_HOST=<the oss server's address> OSS_CACHE_WRITE_TOKEN=<token> \\
      tools/ci/populate_cache.py

The write token goes into a .netrc of this run's own (mode 600, removed at
the end), never onto a command line; Bazel's HTTP cache reads credentials
from the file NETRC names. CI's `Bazel cache` workflow runs it after each
merge to main (.github/workflows/cache.yml), with the token from an
environment only main may use.
"""
import os, subprocess, sys, tempfile

ISOMER = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXAMPLES = os.path.join(ISOMER, "examples")
PLAYGROUND = os.path.join(ISOMER, "playground")

# (module, flags, targets): the proof's builds (tools/proof/proof.py's
# build_ios, build_macos, build_android, build_web), flag for flag.
BUILDS = [
    (EXAMPLES, ["-c", "opt", "--ios_multi_cpus=sim_arm64"],
     ["//apple/storybook_ios_application:storybook_ios_sim_application", "//apple/storybook_isomer_ios_application"]),
    (PLAYGROUND, ["-c", "opt", "--ios_multi_cpus=sim_arm64", "--define", "iso_playground_embedded=1"],
     ["//apple/playground_ios_application"]),
    (EXAMPLES, ["-c", "opt"], ["//apple/storybook_macos_application",
                               "//android/storybook_android_application:storybook_android_application_apk",
                               "//web/storybook_web_application:storybook_web_application_site"]),
    (PLAYGROUND, ["-c", "opt"], ["//apple/playground_macos_application",
                                 "//android/playground_android_application:playground_android_application_apk"]),
]
# What agents run most: each module's tests, at Bazel's default settings.
TESTS = [ISOMER, EXAMPLES, PLAYGROUND]


def main():
    host, token = os.environ.get("OSS_CACHE_HOST"), os.environ.get("OSS_CACHE_WRITE_TOKEN")
    if not host or not token:
        sys.exit("populate_cache.py needs OSS_CACHE_HOST and OSS_CACHE_WRITE_TOKEN")
    work = tempfile.mkdtemp(prefix="oss-cache-")
    netrc = os.path.join(work, "netrc")
    with os.fdopen(os.open(netrc, os.O_WRONLY | os.O_CREAT, 0o600), "w") as file:
        file.write(f"machine {host} login bazel password {token}\n")
    environment = dict(os.environ, NETRC=netrc)
    environment.pop("OSS_CACHE_WRITE_TOKEN")
    cache = [f"--remote_cache=http://{host}:7490"]
    failed = []
    try:
        for cwd, flags, targets in BUILDS:
            print(f"== {os.path.relpath(cwd, ISOMER) or '.'}: build {' '.join(flags)} {' '.join(targets)}", flush=True)
            if subprocess.run(["bazel", "build", *cache, *flags, *targets], cwd=cwd, env=environment).returncode != 0:
                failed.append(f"build {targets}")
        for cwd in TESTS:
            print(f"== {os.path.relpath(cwd, ISOMER) or '.'}: test //...", flush=True)
            # A failing test is still a result worth keeping; the build's
            # own failure is what this reports.
            result = subprocess.run(["bazel", "test", *cache, "//..."], cwd=cwd, env=environment)
            if result.returncode not in (0, 3):
                failed.append(f"test {cwd}")
    finally:
        os.remove(netrc)
        os.rmdir(work)
    if failed:
        sys.exit("failed: " + "; ".join(failed))
    print("the cache has main's builds")


if __name__ == "__main__":
    main()
