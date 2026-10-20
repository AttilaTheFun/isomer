"""Find Isomer public funcs/inits whose body is empty, returns `self`, or never
reads one of its parameters (accepted-but-ignored arguments). Writes noops.json."""
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from swiftdecl import strip_comments_strings, match_paren, split_top_commas  # noqa: E402

ISO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRCS = (sorted(glob.glob(f"{ISO}/shared/swift_ui_core/*.swift")) + sorted(glob.glob(f"{ISO}/shared/renderers/*.swift"))
        + sorted(glob.glob(f"{ISO}/wasm/libraries/swift_ui/*.swift")) + sorted(glob.glob(f"{ISO}/android/libraries/swift_ui/*.swift")))
HDR = re.compile(r"(?:nonisolated\s+)?public\s+(?:static\s+|mutating\s+|nonisolated\s+)*(func\s+(`?[\w]+`?|[^\s(<]+)|init[?!]?)\s*(<[^{(]*?>)?\s*\(")


def main():
    out = []
    for path in SRCS:
        raw = open(path).read()
        t = strip_comments_strings(raw)
        for m in HDR.finditer(t):
            k = m.end() - 1
            e = match_paren(t, k)
            if e < 0:
                continue
            plist = t[k + 1:e]
            # find body
            b = t.find("{", e)
            nl_semicolon = t.find("\n", e)
            # protocol requirement (no body) if a newline+decl comes before '{' with nothing like '->' continuing
            between = t[e + 1:b] if b > 0 else ""
            if b < 0 or re.search(r"\n\s*(public|func|var|let|case|static|init|@|\})", between):
                continue
            depth = 0
            j = b
            while j < len(t):
                if t[j] == "{":
                    depth += 1
                elif t[j] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            body = t[b + 1:j]
            line = t.count("\n", 0, m.start()) + 1
            name = m.group(2) or "init"
            params = []
            for p in split_top_commas(plist):
                head = p.split(":")[0]
                head = re.sub(r"@[\w.]+(\([^)]*\))?", "", head).strip().split()
                if not head:
                    continue
                internal = head[-1].strip("`")
                label = head[0] if len(head) > 1 else head[0]
                if internal == "_":
                    continue
                params.append((label, internal))
            stripped = body.strip()
            flags = []
            if stripped in ("", "self"):
                flags.append("empty" if not stripped else "returns self")
            unused = [f"{lab}" + (f" ({inn})" if inn != lab else "") for lab, inn in params
                      if not re.search(r"(?<![\w.])" + re.escape(inn) + r"\b", body)]
            if unused and stripped not in ("", "self"):
                flags.append("ignores: " + ", ".join(unused))
            elif unused:
                flags.append("params: " + ", ".join(unused))
            if flags:
                out.append({"path": path.replace(ISO + "/", ""), "line": line, "name": name,
                            "sig": re.sub(r"\s+", " ", t[m.start():e + 1])[:200], "flags": flags})
    json.dump(out, open("/tmp/swiftui_audit/noops.json", "w"), indent=1)
    for o in out:
        print(f"{o['path']}:{o['line']} {o['name']} -- {'; '.join(o['flags'])}")


if __name__ == "__main__":
    main()
