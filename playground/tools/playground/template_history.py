#!/usr/bin/env python3
"""Fingerprints of every template the Playground has shipped.

A project made from a template and never edited still holds that template's
source as it was then. To bring such projects to the current template (and
leave edited ones alone), the apps compare a project's App.swift with every
version of every template: this script rebuilds them from isomer's git
history — playground/ since the Playground came back (0.35), and the
examples before it moved out of them (0.15) — and writes their FNV-1a 64
fingerprints to shared/app/TemplateHistory.swift. Between 0.15 and
0.35 the Playground was a repository of its own, whose history is not in
isomer's: the versions it shipped are the file's own entries, which the
script keeps (a fingerprint, once shipped, is never dropped).

Each version is assembled exactly as its commit did: that commit's
samples.bzl is run (its `native.genrule` captured) over that commit's
playground_sample() calls and sources, and the genrule's shell command is
run on them. "This website" (Splash.swift) is the file itself.

    tools/playground/template_history.py [--isomer <the isomer checkout>]

Run it again whenever a template changes, once the change is committed (it
reads commits, not the working tree).
"""
import argparse, os, re, subprocess, sys, tempfile, types

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "shared", "app", "TemplateHistory.swift")

# (repository, module root inside it, the iOS app's package, the splash page).
def eras(isomer):
    return [
        (isomer, "playground/", "apple/playground_ios_application", "web/splash_web_application/Splash.swift"),
        (isomer, "examples/", "apple/playground_ios_application", "web/splash_web_application/Splash.swift"),
        (isomer, "", "examples/apple/playground_ios_application", "examples/web/splash_web_application/Splash.swift"),
    ]

def recorded():
    """{fingerprint: template file name} already in TemplateHistory.swift."""
    if not os.path.exists(OUT):
        return {}
    entries = re.findall(r'0x([0-9a-f]{16}): "([^"]+)"', open(OUT).read())
    return {int(value, 16): name for value, name in entries}

def fnv1a64(data):
    value = 0xcbf29ce484222325
    for byte in data:
        value ^= byte
        value = (value * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return value

def git(repo, *args):
    result = subprocess.run(["git", "-C", repo, *args], capture_output=True)
    return result.stdout if result.returncode == 0 else None

def calls(build, name):
    """The `name(...)` call texts in a BUILD file, strings and all."""
    out, at = [], 0
    while True:
        at = build.find(name + "(", at)
        if at < 0:
            return out
        if at > 0 and (build[at - 1].isalnum() or build[at - 1] in "_."):
            at += 1
            continue
        depth, i, quote = 0, at + len(name), None
        while i < len(build):
            c = build[i]
            if quote:
                if c == "\\":
                    i += 1
                elif build.startswith(quote, i):
                    i += len(quote) - 1
                    quote = None
            elif build.startswith('"""', i) or build.startswith("'''", i):
                quote = build[i:i + 3]
                i += 2
            elif c in "\"'":
                quote = c
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    out.append(build[at:i + 1])
                    break
            i += 1
        at = i + 1

def assemble(repo, commit, module, package, bzl, build):
    """{template file name: source} as `commit` built them."""
    genrules = []
    scope = {"native": types.SimpleNamespace(genrule=lambda **kw: genrules.append(kw))}
    try:
        exec(compile(bzl, "samples.bzl", "exec"), scope)
        for call in calls(build, "playground_sample"):
            eval(call, scope)
    except Exception as error:
        print(f"  {commit[:8]}: skipped ({error})", file=sys.stderr)
        return {}
    templates = {}
    with tempfile.TemporaryDirectory() as work:
        for rule in genrules:
            cmd = rule["cmd"]
            missing = False
            for label in re.findall(r"\$\(location ([^)]+)\)", cmd):
                if label.startswith("//"):
                    path = module + label[2:].replace(":", "/")
                else:
                    path = module + package + "/" + label.lstrip(":")
                data = git(repo, "show", f"{commit}:{path}")
                if data is None:
                    missing = True
                    break
                local = os.path.join(work, str(abs(hash(label))))
                open(local, "wb").write(data)
                cmd = cmd.replace(f"$(location {label})", local)
            if missing:
                continue
            out = os.path.join(work, "out.swift")
            cmd = cmd.replace("$@", out)
            if subprocess.run(["bash", "-c", cmd], capture_output=True).returncode == 0:
                templates[os.path.basename(rule["outs"][0])] = open(out, "rb").read()
    return templates

def history(isomer):
    """{fingerprint: (template file name, source)} of every shipped version."""
    shipped = {}
    for repo, module, package, splash in eras(isomer):
        bzl_path = module + package + "/samples.bzl"
        # Every commit that touched the rule, the calls or a source (the
        # sources were under shared/ or examples/shared/ of the module).
        paths = [module + package, module + "shared", module + "examples/shared", module + splash]
        commits = (git(repo, "log", "--all", "--format=%H", "--", *paths) or b"").decode().split()
        print(f"{os.path.basename(repo)}/{module}{package}: {len(commits)} commits", file=sys.stderr)
        for commit in commits:
            bzl = git(repo, "show", f"{commit}:{bzl_path}")
            build = git(repo, "show", f"{commit}:{module}{package}/BUILD.bazel")
            if bzl and build:
                for name, source in assemble(repo, commit, module, package, bzl.decode(), build.decode()).items():
                    shipped[fnv1a64(source)] = (name, source)
            page = git(repo, "show", f"{commit}:{module}{splash}")
            if page:
                shipped[fnv1a64(page)] = ("Splash.swift", page)
    return shipped

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--isomer", default=os.path.dirname(ROOT))
    args = parser.parse_args()
    shipped = recorded()
    shipped.update({value: name for value, (name, _) in history(args.isomer).items()})
    lines = [
        "// Generated by tools/playground/template_history.py: the FNV-1a 64",
        "// fingerprint of every version of every template the Playground has",
        "// shipped (rebuilt from git history), with the template it was. A project",
        "// whose App.swift is one of them was never edited, and takes the current",
        "// template's source (TemplateRefresh). Run the script after a template",
        "// changes.",
        "",
        "public enum TemplateHistory {",
        "    public static let shipped: [UInt64: String] = [",
    ]
    for value, name in sorted(shipped.items(), key=lambda item: (item[1], item[0])):
        lines.append(f'        0x{value:016x}: "{name}",')
    lines += [
        "    ]",
        "",
        "    /// FNV-1a 64 over the UTF-8 bytes (the script's own).",
        "    public static func fingerprint(_ source: String) -> UInt64 {",
        "        var value: UInt64 = 0xcbf29ce484222325",
        "        for byte in source.utf8 {",
        "            value ^= UInt64(byte)",
        "            value = value &* 0x100000001b3",
        "        }",
        "        return value",
        "    }",
        "",
        "    /// The template `source` is an unedited version of, if it is one.",
        "    public static func template(of source: String) -> String? {",
        "        shipped[fingerprint(source)]",
        "    }",
        "}",
        "",
    ]
    open(OUT, "w").write("\n".join(lines))
    counts = {}
    for name in shipped.values():
        counts[name] = counts.get(name, 0) + 1
    print(f"{len(shipped)} versions: " + ", ".join(f"{n} {c}" for n, c in sorted(counts.items())), file=sys.stderr)

if __name__ == "__main__":
    main()
