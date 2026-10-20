"""Checks that a web site's directory holds every module its pages import.

A page whose module graph has a missing file does not run at all: the browser
drops the whole graph and the page stays blank, with the error only in the
console. (The Playground's "Run on the web" page shipped blank twice that way,
when the renderer gained an import its site's file list did not name.)

  site_imports_test.py <site directory> <entry> [<entry> ...] [--optional <path> ...]

Walks from each entry (an .html page or a .js module, relative to the site)
through the relative imports: `import … from "./x.js"`, `export … from`,
`import "./x.js"`, `import("./x.js")`, `new URL("./x.js", import.meta.url)`
and an html page's `<script src>`. Anything not found fails the test, unless
it is imported dynamically and named by --optional (a module a page loads
only in a configuration this site is not).
"""
import os
import re
import sys

STATIC = re.compile(r"""(?:^|[;\s}])(?:import|export)\s*(?:[^'"()]*?\sfrom\s*)?['"](\.{1,2}/[^'"]+)['"]""", re.M)
DYNAMIC = re.compile(r"""(?:import\s*\(\s*|new\s+URL\s*\(\s*)['"](\.{1,2}/[^'"]+)['"]""")
SCRIPT_SRC = re.compile(r"""<script\b[^>]*\bsrc\s*=\s*['"]([^'"]+)['"]""", re.I)
INLINE_MODULE = re.compile(r"""<script\b[^>]*type\s*=\s*['"]module['"][^>]*>(.*?)</script>""", re.I | re.S)
COMMENTS = re.compile(r"/\*.*?\*/|(?<![:'\"\\])//[^\n]*", re.S)


def references(path, text):
    """(specifier, dynamic) pairs a file refers to."""
    found = []
    if path.endswith((".html", ".htm")):
        for source in SCRIPT_SRC.findall(text):
            if not re.match(r"^[a-z]+:|^//", source):
                found.append((source, False))
        text = "\n".join(INLINE_MODULE.findall(text))
    elif not path.endswith((".js", ".mjs")):
        return found
    text = COMMENTS.sub("", text)
    found += [(s, False) for s in STATIC.findall(text)]
    found += [(s, True) for s in DYNAMIC.findall(text)]
    return found


def main(argv):
    optional = set()
    if "--optional" in argv:
        at = argv.index("--optional")
        optional = set(argv[at + 1:])
        argv = argv[:at]
    site, entries = argv[1], argv[2:]
    queue = list(entries)
    seen = set()
    missing = []
    while queue:
        relative = queue.pop()
        if relative in seen:
            continue
        seen.add(relative)
        path = os.path.join(site, relative)
        if not os.path.isfile(path):
            missing.append((relative, "an entry of the test", False))
            continue
        with open(path, encoding="utf-8", errors="replace") as file:
            text = file.read()
        for specifier, dynamic in references(relative, text):
            target = os.path.normpath(os.path.join(os.path.dirname(relative), specifier.split("?")[0].split("#")[0]))
            if target.startswith(".."):
                continue  # outside the site: another origin path, not ours to check
            if os.path.isfile(os.path.join(site, target)):
                queue.append(target)
            elif not (dynamic and target in optional):
                missing.append((target, relative, dynamic))
    if missing:
        print("The site is missing files its pages import (the page would be blank):")
        for target, importer, dynamic in sorted(set(missing)):
            print("  %s, imported%s by %s" % (target, " dynamically" if dynamic else "", importer))
        print("Add them to the site's file list.")
        return 1
    print("%d files checked, every import is in the site" % len(seen))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
