"""Count how often SwiftUI names are used in a corpus of apps (read-only), to
ground priorities. Corpus: .swift files that import SwiftUI under the repos
SWIFTUI_AUDIT_REPOS names ("name=path,name=path"; by default the public
repos checked out beside this one), vendored/third-party/build directories
excluded. Writes usage.json:
{name: {"modifier": n, "type": n, "keypath": n, "member": n, "by_repo": {...}}}."""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from swiftdecl import strip_comments_strings  # noqa: E402

D = os.path.dirname(os.path.abspath(__file__))
# The directory this checkout sits in, where the other repos are by default.
H = os.path.dirname(os.path.dirname(os.path.dirname(D)))
REPOS = dict(item.split("=", 1) for item in os.environ["SWIFTUI_AUDIT_REPOS"].split(",")) \
    if os.environ.get("SWIFTUI_AUDIT_REPOS") else {
    "visor": f"{H}/visor",
    "agent_ui": f"{H}/agent_ui",
    "visor_isomer": f"{H}/visor_isomer",
    "isomer_examples": f"{H}/isomer/examples",
}
EXCLUDE = re.compile(r"/(bazel-[^/]*|\.build|third_party|external|node_modules|Pods|DerivedData|\.git)/")


def corpus():
    files = {}
    for repo, root in REPOS.items():
        for dp, dn, fn in os.walk(root, followlinks=False):
            dn[:] = [d for d in dn if not (d.startswith("bazel-") or d in (".build", "third_party", "external", "node_modules", ".git", "Pods", "DerivedData"))]
            for f in fn:
                if f.endswith(".swift"):
                    p = os.path.join(dp, f)
                    if EXCLUDE.search(p):
                        continue
                    try:
                        t = open(p, encoding="utf-8", errors="replace").read()
                    except OSError:
                        continue
                    if re.search(r"^\s*import\s+SwiftUI\b", t, re.M):
                        files[p] = (repo, strip_comments_strings(t))
    return files


def main():
    res = json.load(open(f"{D}/results.json"))
    names = set()
    for i in res["items"]:
        names.add(i["name"])
        if i["container"]:
            names.add(i["container"].split(".")[0])
    files = corpus()
    print(len(files), "files", file=sys.stderr)
    by_repo_text = {}
    for p, (repo, t) in files.items():
        by_repo_text.setdefault(repo, []).append(t)
    texts = {r: "\n".join(ts) for r, ts in by_repo_text.items()}
    out = {}
    for n in sorted(names):
        if not re.match(r"^\w+$", n) or n == "init":
            continue
        e = re.escape(n)
        pats = {
            "modifier": re.compile(r"\." + e + r"\s*[({]"),
            "type": re.compile(r"(?<![\w.])" + e + r"(?=\s*[({<.]|\s*$|\s*[:,)>\]]|\s*\{)", re.M) if n[:1].isupper() else None,
            "keypath": re.compile(r"\\\." + e + r"\b"),
            "member": re.compile(r"(?<![\w])\." + e + r"\b"),
        }
        rec = {"by_repo": {}}
        for k, rx in pats.items():
            if rx is None:
                rec[k] = 0
                continue
            tot = 0
            for r, t in texts.items():
                c = len(rx.findall(t))
                tot += c
                if c and k in ("modifier", "type", "keypath"):
                    rec["by_repo"].setdefault(r, {})[k] = c
            rec[k] = tot
        out[n] = rec
    json.dump({"files": len(files), "by_repo_files": {r: len(v) for r, v in by_repo_text.items()}, "counts": out},
              open(f"{D}/usage.json", "w"))


if __name__ == "__main__":
    main()
