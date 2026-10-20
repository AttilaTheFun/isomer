#!/usr/bin/env python3
"""Checks that apps built for wasm or Android link Isomer's Foundation and not
the Swift SDK's (swift-corelibs-foundation and its CoreFoundation, ICU and
FoundationEssentials copies): a library that imports Foundation without
depending on @isomer//:foundation finds the SDK's, which then links beside
Isomer's.

    tools/foundation/check_link.py [<bazel flags>] <target> [<target> ...]
        (run in the workspace, after building the targets with the same flags:
         `-c opt`, `--config=...`)

Reads each link action's command line and the autolink files it reads, in
the configuration the flags give. An autolink file that is not on disk
(the targets were built with other flags, or not at all) is an error, not
a pass: a check that reads nothing finds nothing.
Exit status 1 and a list of what came from the SDK, if anything did.
"""

import json
import os
import re
import subprocess
import sys

# ICU itself is the SDK's (lib_FoundationICU.a, which Isomer's
# FoundationInternationalization links by name): not a leak.
SDK_LIBRARIES = re.compile(
    r"(^|/)(lib)?(Foundation|CoreFoundation|FoundationEssentials|"
    r"FoundationInternationalization|FoundationNetworking|FoundationXML|_FoundationCollections|"
    r"_FoundationCShims)\.a$"
)
AUTOLINK = re.compile(
    r"^-l(Foundation|CoreFoundation|FoundationEssentials|FoundationInternationalization|"
    r"FoundationNetworking|FoundationXML|_FoundationCollections|_FoundationCShims)$"
)


def link_actions(target, flags):
    query = 'mnemonic("CppLink", deps({}))'.format(target)
    out = subprocess.run(
        ["bazel", "aquery", query, "--output=jsonproto"] + flags, capture_output=True, text=True, check=True
    ).stdout
    data = json.loads(out or "{}")
    return data.get("actions", [])


def main(argv):
    # Labels are the targets; everything else is a flag (`-c opt` included).
    targets = [a for a in argv if a.startswith(("//", "@", ":"))]
    flags = [a for a in argv if not a.startswith(("//", "@", ":"))]
    execroot = subprocess.run(
        ["bazel", "info", "execution_root"] + flags, capture_output=True, text=True, check=True
    ).stdout.strip()
    problems = []
    unbuilt = []
    for target in targets:
        for action in link_actions(target, flags):
            args = action.get("arguments", [])
            output = next((a for a in args if a.endswith((".wasm", ".so"))), None)
            if output is None:
                continue
            for arg in args:
                path = arg.lstrip("@")
                if "swift_toolchain" in path and SDK_LIBRARIES.search(path):
                    problems.append("{}: links {}".format(output, path))
                if arg.startswith("@") and path.endswith(".autolink"):
                    full = os.path.join(execroot, path)
                    if not os.path.exists(full):
                        unbuilt.append(path)
                        continue
                    for flag in open(full).read().split():
                        if AUTOLINK.match(flag):
                            problems.append("{}: {} asks for {}".format(output, path, flag))
    if unbuilt:
        print("not built with these flags ({}): {} autolink files, e.g. {}".format(
            " ".join(flags) or "no flags", len(set(unbuilt)), sorted(set(unbuilt))[0]))
        print("build the targets with the same flags first")
        return 2
    if problems:
        print("\n".join(sorted(set(problems))))
        return 1
    print("ok: no Foundation from the Swift SDK in", ", ".join(targets))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
