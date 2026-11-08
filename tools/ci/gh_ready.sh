#!/bin/bash
# gh on a CI runner: installed when missing (as root, or by sudo), as the
# Linux containers' image may not have it. Sourced by the scripts that use
# it, with GH_TOKEN the job's.
if ! command -v gh > /dev/null; then
    root_do() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
    root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends gh > /dev/null ||
        { root_do apt-get update -qq > /dev/null &&
          root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends gh > /dev/null; }
fi
