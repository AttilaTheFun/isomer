"""Minimal Swift declaration extractor for .swiftinterface files and Swift sources.

Not a Swift parser: it strips comments and string-literal contents, walks the
text tracking brace depth, and splits the text at declaration level (file,
type or extension bodies) into declaration headers. Function/property bodies
are skipped. Each header is classified (kind, name, argument labels,
modifiers, @available attributes) and recorded with its container (the type
or extension it sits in) and the availability it inherits from there.
"""
import re

KEYWORDS_TYPE = {"struct", "class", "enum", "protocol", "extension", "actor"}
KEYWORDS_MEMBER = {"func", "init", "subscript", "var", "let", "case", "typealias",
                   "associatedtype", "deinit", "operator", "precedencegroup", "import", "macro"}
MODIFIERS = {"public", "open", "internal", "private", "fileprivate", "package", "nonisolated",
             "final", "static", "class", "mutating", "nonmutating", "override", "convenience",
             "required", "indirect", "dynamic", "lazy", "weak", "unowned", "optional",
             "prefix", "postfix", "infix", "consuming", "borrowing", "__consuming", "isolated",
             "distributed", "sending", "rethrows"}


def strip_comments_strings(text):
    """Remove comments; replace string literal contents with nothing (keeps the
    quotes). Newlines are preserved so line numbers stay meaningful."""
    out = []
    i, n = 0, len(text)
    # stack of modes: 'code' or ('str', delim, hashes) ; interpolation pushes 'interp' with paren depth
    stack = [["code", 0]]
    while i < n:
        mode = stack[-1]
        c = text[i]
        if mode[0] in ("code", "interp"):
            if text.startswith("//", i):
                j = text.find("\n", i)
                if j < 0:
                    break
                i = j
                continue
            if text.startswith("/*", i):
                depth = 1
                j = i + 2
                while j < n and depth:
                    if text.startswith("/*", j):
                        depth += 1
                        j += 2
                    elif text.startswith("*/", j):
                        depth -= 1
                        j += 2
                    else:
                        if text[j] == "\n":
                            out.append("\n")
                        j += 1
                i = j
                continue
            if c == '"' or c == "#":
                m = re.match(r'(#*)("""|")', text[i:i + 12])
                if m:
                    hashes, delim = m.group(1), m.group(2)
                    out.append(hashes + delim)
                    stack.append(["str", delim, hashes])
                    i += len(hashes) + len(delim)
                    continue
            if mode[0] == "interp":
                if c == "(":
                    mode[1] += 1
                elif c == ")":
                    if mode[1] == 0:
                        stack.pop()
                        i += 1
                        continue
                    mode[1] -= 1
            out.append(c)
            i += 1
        else:  # inside a string
            _, delim, hashes = mode
            end = delim + hashes
            if text.startswith(end, i):
                out.append(end)
                stack.pop()
                i += len(end)
                continue
            esc = "\\" + hashes
            if text.startswith(esc, i):
                k = i + len(esc)
                if k < n and text[k] == "(":
                    stack.append(["interp", 0])
                    i = k + 1
                    continue
                i = k + 1
                continue
            if c == "\n":
                out.append("\n")
                if delim == '"':  # unterminated single-line string: bail out
                    stack.pop()
            i += 1
    return "".join(out)


def split_top_commas(s):
    parts, depth, cur = [], 0, []
    i = 0
    while i < len(s):
        c = s[i]
        if c in "([{<":
            depth += 1
        elif c in ")]}>":
            if c == ">" and i > 0 and s[i - 1] == "-":
                pass  # arrow
            else:
                depth -= 1
        if c == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(c)
        i += 1
    if "".join(cur).strip():
        parts.append("".join(cur))
    return parts


def match_paren(s, start, open_c="(", close_c=")"):
    """Index of the bracket closing s[start] (which is open_c)."""
    depth = 0
    for j in range(start, len(s)):
        if s[j] == open_c:
            depth += 1
        elif s[j] == close_c:
            depth -= 1
            if depth == 0:
                return j
    return -1


def match_angle(s, start):
    depth = 0
    for j in range(start, len(s)):
        if s[j] == "<":
            depth += 1
        elif s[j] == ">" and s[j - 1] != "-":
            depth -= 1
            if depth == 0:
                return j
    return -1


ATTR_RE = re.compile(r"@[A-Za-z_][\w]*(?:::[\w]+|\.[\w]+)*")


def take_attributes(h):
    """Split leading attributes/modifiers from a header. Returns (attrs, mods, rest)."""
    attrs, mods = [], []
    s = h.strip()
    while s:
        if s.startswith("@"):
            m = ATTR_RE.match(s)
            if not m:
                break
            j = m.end()
            # attribute argument list directly after the name
            k = j
            if k < len(s) and s[k] == "(":
                e = match_paren(s, k)
                if e < 0:
                    e = len(s) - 1
                j = e + 1
            attrs.append(s[:j])
            s = s[j:].lstrip()
            continue
        m = re.match(r"([A-Za-z_]\w*)(\s*\(\s*(set|unsafe|safe)\s*\))?", s)
        if m and m.group(1) in MODIFIERS:
            w = m.group(1)
            # `class func` / `class var` is a modifier; `class Foo` is a type
            if w == "class":
                nxt = s[m.end():].lstrip()
                if not re.match(r"(func|var|let|subscript|override|final|public|open|nonisolated|static)\b", nxt):
                    break
            mods.append(w + (m.group(2) or "").replace(" ", ""))
            s = s[m.end():].lstrip()
            continue
        break
    return attrs, mods, s


MODULES = ("Accessibility Combine CoreData CoreFoundation CoreGraphics CoreMedia CoreTransferable DataDetection "
           "DeveloperToolsSupport Dispatch Foundation OSLog Observation Spatial Swift SwiftUI SwiftUICore Symbols "
           "UIKit AppKit UniformTypeIdentifiers _Concurrency _StringProcessing _SwiftConcurrencyShims os simd "
           "ObjectiveC Darwin QuartzCore CoreText CoreImage").split()
MOD_DOT_RE = re.compile(r"(?<![\w.])(?:" + "|".join(sorted(MODULES, key=len, reverse=True)) + r")\.(?=[A-Za-z_])")


def norm_type(t):
    t = re.sub(r"\b\w+::", "", t)
    t = MOD_DOT_RE.sub("", t)
    t = re.sub(r"\s+", " ", t).strip()
    return t


def parse_params(plist, is_subscript=False):
    """plist: text inside the parens. Returns list of (label, has_default, variadic)."""
    out = []
    for p in split_top_commas(plist):
        p = p.strip()
        if not p:
            continue
        colon = None
        depth = 0
        for j, c in enumerate(p):
            if c in "([{<":
                depth += 1
            elif c in ")]}>":
                depth -= 1
            elif c == ":" and depth == 0 and not p[j:j + 2] == "::" and not (j > 0 and p[j - 1] == ":"):
                colon = j
                break
        head = p if colon is None else p[:colon]
        typ = "" if colon is None else p[colon + 1:]
        # drop attributes on the parameter (@ViewBuilder etc.)
        head = re.sub(r"@[\w:.]+(<[^>]*>)?(\([^)]*\))?", "", head).strip()
        toks = head.split()
        toks = [t for t in toks if t not in ("inout", "isolated", "sending", "consuming", "borrowing", "__owned", "__shared")]
        if not toks:
            label = "_"
        elif len(toks) == 1:
            label = "_" if is_subscript else toks[0]
        else:
            label = toks[0]
        has_default = False
        depth = 0
        for j, c in enumerate(typ):
            if c in "([{<":
                depth += 1
            elif c in ")]}>":
                if not (c == ">" and j > 0 and typ[j - 1] == "-"):
                    depth -= 1
            elif c == "=" and depth == 0 and typ[j - 1:j + 1] not in ("==", "!=", "<=", ">=") and typ[j:j + 2] != "==":
                has_default = True
                break
        variadic = "..." in typ.split("=")[0]
        out.append((label, has_default, variadic, norm_type(typ.split("=")[0]) if typ else ""))
    return out


def parse_availability(attrs):
    """Return dict: platform -> dict(introduced, deprecated, unavailable, obsoleted). '*' for all."""
    av = {}
    spi = False
    for a in attrs:
        if a.startswith("@_spi(") or a.startswith("@_spi_available"):
            spi = True
            continue
        if not a.startswith("@available("):
            continue
        body = a[len("@available("):-1]
        parts = [x.strip() for x in split_top_commas(body)]
        if not parts:
            continue
        first = parts[0]
        kw = {"unavailable", "deprecated", "introduced", "obsoleted", "message", "renamed", "noasync"}
        if len(parts) > 1 and (any(p.split(":")[0].strip() in kw for p in parts[1:])) and " " not in first:
            plat = first
            d = av.setdefault(plat, {})
            for p in parts[1:]:
                k, _, v = p.partition(":")
                k, v = k.strip(), v.strip()
                if k == "unavailable":
                    d["unavailable"] = True
                elif k == "deprecated":
                    d["deprecated"] = v or "yes"
                elif k == "introduced":
                    d["introduced"] = v
                elif k == "obsoleted":
                    d["obsoleted"] = v
                elif k == "renamed":
                    d["renamed"] = True
        else:
            for p in parts:
                m = re.match(r"(\w+)\s+([\d.]+)", p)
                if m:
                    av.setdefault(m.group(1), {})["introduced"] = m.group(2)
    return av, spi


def parse_generics(gen, tail):
    """Map generic parameter name -> constraint text (first protocol), from
    `<A: P, B>` and a trailing `where A : P, B == X` clause."""
    g = {}
    for part in split_top_commas(gen):
        part = norm_type(part)
        if not part:
            continue
        nm, _, c = part.partition(":")
        nm = nm.strip().replace("each ", "")
        g[nm] = c.strip()
    m = re.search(r"\bwhere\b(.*)$", tail, re.S)
    if m:
        for part in split_top_commas(m.group(1)):
            part = norm_type(part)
            mm = re.match(r"(\w+)\s*:\s*(.+)$", part)
            if mm and mm.group(1) in g and not g[mm.group(1)]:
                g[mm.group(1)] = mm.group(2).strip()
            mm = re.match(r"(\w+)\s*==\s*(.+)$", part)
            if mm and mm.group(1) in g:
                g[mm.group(1)] = "==" + mm.group(2).strip()
    return g


def classify_header(h):
    attrs, mods, rest = take_attributes(h)
    m = re.match(r"([A-Za-z_]\w*)", rest)
    if not m:
        return None
    kw = m.group(1)
    rec = {"attrs": attrs, "mods": mods, "kw": kw, "raw": re.sub(r"\s+", " ", h.strip())}
    after = rest[m.end():]
    if kw in KEYWORDS_TYPE:
        nm = re.match(r"\s*((?:\w+::)?\w+(?:\.(?:\w+::)?\w+)*)", after)
        if not nm:
            return None
        name = norm_type(nm.group(1))
        rec["kind"] = kw
        rec["name"] = name
        tail = after[nm.end():]
        wh = re.search(r"\bwhere\b(.*)$", tail, re.S)
        rec["where"] = norm_type(wh.group(1)) if wh else ""
        conf = tail.split("where")[0]
        rec["conformances"] = norm_type(conf.split(":", 1)[1]) if ":" in conf else ""
        return rec
    if kw == "func":
        nm = re.match(r"\s*(`?[\w]+`?|[^\s(<]+)\s*", after)
        if not nm:
            return None
        name = nm.group(1).strip("`")
        j = nm.end()
        gen = ""
        if j < len(after) and after[j] == "<":
            e = match_angle(after, j)
            gen = after[j + 1:e] if e > 0 else ""
            j = e + 1 if e > 0 else j
        k = after.find("(", j)
        if k < 0:
            return None
        e = match_paren(after, k)
        params = parse_params(after[k + 1:e]) if e > 0 else []
        tail = after[e + 1:] if e > 0 else ""
        rec.update(kind="func", name=name, params=params, sig_tail=norm_type(tail),
                   generics=parse_generics(gen, tail))
        return rec
    if kw == "init":
        j = 0
        if after[:1] in "?!":
            j = 1
        gen = ""
        if j < len(after) and after[j] == "<":
            e = match_angle(after, j)
            gen = after[j + 1:e]
            j = e + 1
        k = after.find("(", j)
        if k < 0:
            return None
        e = match_paren(after, k)
        params = parse_params(after[k + 1:e]) if e > 0 else []
        tail = after[e + 1:] if e > 0 else ""
        rec.update(kind="init", name="init", params=params, generics=parse_generics(gen, tail))
        return rec
    if kw == "subscript":
        k = after.find("(")
        e = match_paren(after, k)
        params = parse_params(after[k + 1:e], is_subscript=True) if e > 0 else []
        rec.update(kind="subscript", name="subscript", params=params)
        return rec
    if kw in ("var", "let"):
        names = []
        for part in split_top_commas(after):
            nm = re.match(r"\s*`?(\w+)`?", part)
            if nm:
                names.append(nm.group(1))
        tm = re.match(r"\s*`?\w+`?\s*:\s*(.*)$", after, re.S)
        rec.update(kind="var", names=names, name=names[0] if names else "", vtype=norm_type(tm.group(1)) if tm else "")
        return rec
    if kw == "case":
        names = []
        for part in split_top_commas(after):
            nm = re.match(r"\s*`?(\w+)`?", part)
            if nm:
                names.append(nm.group(1))
        rec.update(kind="case", names=names, name=names[0] if names else "")
        return rec
    if kw in ("typealias", "associatedtype"):
        nm = re.match(r"\s*(\w+)", after)
        rec.update(kind=kw, name=nm.group(1) if nm else "")
        return rec
    if kw == "macro":
        nm = re.match(r"\s*(\w+)", after)
        rec.update(kind="macro", name=nm.group(1) if nm else "")
        return rec
    return None


CONT_START = re.compile(r"^\s*(->|where\b|throws\b|rethrows\b|async\b|:|,|&|=|\.|\{|\)|>|\|\||&&)")
CONT_END = re.compile(r"(->|,|:|&|=|\bwhere|\(|<|\|\||&&)\s*$")


def walk(text):
    """Yield (header_text, line_no, opens_body, context_stack_snapshot)."""
    text = strip_comments_strings(text)
    # drop compiler directives (#if/#else/#endif and their conditions), keeping all branches
    lines = text.split("\n")
    lines = ["" if re.match(r"\s*#(if|elseif|else|endif|warning|error|sourceLocation)\b", ln) else ln for ln in lines]
    text = "\n".join(lines)
    n = len(text)
    stack = [{"kind": "file", "name": None}]
    buf = []
    buf_line = 1
    depth = 0  # paren/bracket (and brace inside parens) depth within buf
    i = 0
    line = 1
    results = []
    code_depth = 0

    def flush(opens):
        nonlocal buf
        h = "".join(buf).strip()
        buf = []
        if h:
            results.append((h, buf_line, opens, [dict(c) for c in stack]))
            return results[-1]
        return None

    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
        top = stack[-1]
        if top["kind"] == "code":
            if c == "{":
                top["depth"] += 1
            elif c == "}":
                top["depth"] -= 1
                if top["depth"] == 0:
                    stack.pop()
            i += 1
            continue
        # declaration context
        if not "".join(buf).strip():
            buf_line = line
        if c in "([":
            depth += 1
            buf.append(c)
        elif c in ")]":
            depth = max(0, depth - 1)
            buf.append(c)
        elif c == "{" and depth > 0:
            depth += 1
            buf.append(c)
        elif c == "}" and depth > 0:
            depth -= 1
            buf.append(c)
        elif c == "{":
            hdr = "".join(buf).strip()
            r = flush(True)
            rec = classify_header(hdr) if hdr else None
            if rec and rec["kw"] in KEYWORDS_TYPE:
                stack.append({"kind": rec["kw"], "name": rec["name"], "rec": rec})
            else:
                stack.append({"kind": "code", "depth": 1})
        elif c == "}":
            flush(False)
            if len(stack) > 1:
                stack.pop()
        elif c == ";" and depth == 0:
            flush(False)
        elif c == "\n" and depth == 0:
            cur = "".join(buf)
            s = cur.strip()
            if s:
                # attributes-only so far? keep accumulating
                a, mods, rest = take_attributes(s)
                if not rest:
                    buf.append(c)
                else:
                    # look ahead to the next non-empty line
                    j = i + 1
                    while j < n:
                        k = text.find("\n", j)
                        if k < 0:
                            k = n
                        nxt = text[j:k]
                        if nxt.strip():
                            break
                        j = k + 1
                    else:
                        nxt = ""
                    if CONT_END.search(s) or CONT_START.match(nxt):
                        buf.append(" ")
                    else:
                        flush(False)
            else:
                buf = []
        else:
            buf.append(c)
        i += 1
    flush(False)
    return results


def container_path(stack):
    """Qualified container name from a context stack (excluding file)."""
    names = []
    for c in stack[1:]:
        if c["kind"] == "code":
            return None
        names.append(c["name"])
    return ".".join(names) if names else None


def extract(text, module, platform, path, interface=True):
    """Return list of declaration records."""
    out = []
    for hdr, ln, opens, stack in walk(text):
        rec = classify_header(hdr)
        if not rec:
            continue
        cont = container_path(stack)
        if cont is None and len(stack) > 1:
            continue
        ctx_recs = [c.get("rec") for c in stack[1:]]
        # availability inheritance: collect attrs from contexts and the decl
        av_layers = []
        spi = False
        ctx_public = True
        in_protocol = False
        ext_public = False
        where_alt = None
        for cr in ctx_recs:
            av, s = parse_availability(cr["attrs"])
            av_layers.append(av)
            spi = spi or s
            if cr["kw"] == "protocol":
                in_protocol = True
            else:
                in_protocol = False
            if cr["kw"] == "extension":
                ext_public = ("public" in cr["mods"] or "open" in cr["mods"])
                m = re.match(r"Self\s*==\s*([\w.<>]+)", cr.get("where", ""))
                where_alt = m.group(1) if m else None
            else:
                ext_public = False
        av, s = parse_availability(rec["attrs"])
        av_layers.append(av)
        spi = spi or s
        mods = rec["mods"]
        kind = rec.get("kind")
        last_ctx = stack[-1]["kind"] if len(stack) > 1 else "file"
        # every enclosing type declaration must itself be public
        enclosing_public = all(("public" in cr["mods"] or "open" in cr["mods"])
                               for cr in ctx_recs if cr["kw"] in ("struct", "class", "enum", "protocol", "actor"))
        if kind == "extension":
            is_public = True  # extensions themselves carry no access; members decide
        elif not enclosing_public:
            is_public = False
        elif kind in ("case",):
            is_public = True
        elif last_ctx == "protocol" and kind != "extension":
            is_public = True
        elif "public" in mods or "open" in mods:
            is_public = True
        elif ext_public and not any(m in mods for m in ("private", "fileprivate", "internal", "package")):
            is_public = True
        else:
            is_public = False
        if interface and any(a.startswith("@usableFromInline") for a in rec["attrs"]) and not ("public" in mods or "open" in mods):
            is_public = False
        names = rec.get("names") or [rec.get("name")]
        for nm in names:
            r = {
                "module": module,
                "platform": platform,
                "path": path,
                "line": ln,
                "kind": kind,
                "name": nm,
                "container": cont,
                "container_kind": last_ctx,
                "static": "static" in mods or "class" in mods,
                "public": is_public,
                "spi": spi,
                "av_layers": av_layers,
                "where_alt": where_alt,
                "raw": rec["raw"],
                "ctx_where": ctx_recs[-1].get("where", "") if ctx_recs else "",
            }
            if "params" in rec:
                r["params"] = rec["params"]
                r["generics"] = rec.get("generics", {})
                r["labels"] = "".join(p[0] + ":" for p in rec["params"])
            if kind in KEYWORDS_TYPE:
                r["conformances"] = rec.get("conformances", "")
                r["where"] = rec.get("where", "")
            if kind == "var":
                r["vtype"] = rec.get("vtype", "")
            out.append(r)
    return out


def platform_status(rec, platform):
    """For a record parsed from `platform`'s interface: 'ok', 'deprecated',
    'soft-deprecated' (deprecated: 100000), or 'unavailable'."""
    keys = {"iOS": ["iOS", "anyAppleOS"], "macOS": ["macOS", "OSX", "anyAppleOS"]}[platform]
    status = "ok"
    for av in rec["av_layers"]:
        for k in keys + ["*"]:
            d = av.get(k)
            if not d:
                continue
            if d.get("unavailable") or d.get("obsoleted"):
                return "unavailable"
            if d.get("deprecated"):
                v = d["deprecated"]
                try:
                    soft = float(v.split(".")[0]) >= 100000
                except ValueError:
                    soft = False
                st = "soft-deprecated" if soft else "deprecated"
                if status != "deprecated":
                    status = st
    return status


def introduced(rec, platform):
    keys = {"iOS": ["iOS", "anyAppleOS"], "macOS": ["macOS", "OSX", "anyAppleOS"]}[platform]
    v = None
    for av in rec["av_layers"]:
        for k in keys:
            d = av.get(k)
            if d and d.get("introduced"):
                v = d["introduced"]
    return v
