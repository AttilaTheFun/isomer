"""Write /tmp/swiftui_api_audit.md from results.json, usage.json, noops.json and
the curated notes in notes.py. Also writes gaps_full.tsv (every gap with its
signatures, priority and area)."""
import json
import os
import re
import sys
from collections import Counter, defaultdict

D = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, D)
from classify import TYPE_KINDS, area_of, priority  # noqa: E402
from swiftdecl import take_attributes, norm_type  # noqa: E402
import notes  # noqa: E402

R = json.load(open(f"{D}/results.json"))
U = json.load(open(f"{D}/usage.json"))
UC = U["counts"]
NOOPS = json.load(open(f"{D}/noops.json"))
ITEMS = R["items"]

AREA_ORDER = [
    "Controls, input & styles", "Lists, tables & collections", "Navigation, toolbars & tabs",
    "Presentation & dialogs", "Layout & geometry", "Text & fonts", "Images & symbols",
    "Shapes, colors & graphics", "Appearance & visual effects", "Animation & transitions",
    "Gestures & pointer", "Scrolling", "Search", "Focus, keyboard & commands", "Menus & context menus",
    "State, data flow & lifecycle", "Environment values", "Scenes, windows & app",
    "Files, drag & drop, transfer & sharing", "Accessibility", "Feedback & haptics",
    "Other view modifiers", "Other types",
]


def usage(name, kind):
    c = UC.get(name, {})
    br = c.get("by_repo", {})
    old = br.get("old", {}).get(kind, 0)
    apps = sum(v.get(kind, 0) for r, v in br.items() if r != "old")
    return apps, old


def usage_for(it):
    if it["container"] == "View" and it["kind"] == "func":
        return usage(it["name"], "modifier")
    if it["container"] == "EnvironmentValues":
        return usage(it["name"], "keypath")
    if it["kind"] in TYPE_KINDS and not it["container"]:
        return usage(it["name"], "type")
    return (0, 0)


def clean_sig(raw, static=False):
    raw = raw.strip()
    attrs, mods, rest = take_attributes(raw)
    rest = norm_type(rest)
    rest = re.sub(r"\s+", " ", rest)
    pre = "static " if "static" in mods else ""
    return pre + rest


def sigs_of(it, limit=None):
    out = []
    seen = set()
    for s in it["sigs"] or [it["raw"]]:
        c = clean_sig(s)
        if c not in seen:
            seen.add(c)
            out.append(c)
    return out[:limit] if limit else out


def live(it):
    return not it["skip"] and it["status"] in ("ok", "soft-deprecated")


# ------------------------------------------------------------ counts -------
def type_member_coverage():
    own = defaultdict(list)
    for it in ITEMS:
        if not live(it) or it["status"] != "ok":
            continue
        if it["kind"] in ("func", "init", "var", "case", "subscript") and it["container"]:
            own[it["container"]].append(it)
    return own


OWN = type_member_coverage()


def type_status(it):
    q = it["key"][1]
    if it["isomer"] != "present":
        return "missing"
    mem = OWN.get(q, [])
    if q in ("View", "EnvironmentValues", "Scene"):
        mem = mem  # reported separately
    miss = [m for m in mem if m["isomer"] != "present"]
    return "present" if not miss else "partial"


def main():
    lines = []
    w = lines.append
    live_items = [i for i in ITEMS if live(i)]
    ok_items = [i for i in live_items if i["status"] == "ok"]
    soft = [i for i in live_items if i["status"] == "soft-deprecated"]
    hard = [i for i in ITEMS if not i["skip"] and i["status"] == "deprecated"]
    skipped = Counter(i["skip"] for i in ITEMS if i["skip"])

    # types
    tl = [i for i in ok_items if i["kind"] in TYPE_KINDS and not i["container"]]
    nested = [i for i in ok_items if i["kind"] in TYPE_KINDS and i["container"]]
    tl_st = Counter(type_status(i) for i in tl)
    nested_st = Counter("present" if i["isomer"] == "present" else "missing" for i in nested)
    osui_tl = Counter(i["osui"] for i in tl)

    # view modifiers
    vm = [i for i in ok_items if i["container"] == "View" and i["kind"] == "func"]
    groups = defaultdict(list)
    for i in vm:
        groups[i["name"]].append(i)

    def gstat(L):
        s = set(x["isomer"] for x in L)
        if s == {"present"}:
            return "present"
        if "present" in s or "partial" in s:
            return "partial"
        return "missing"
    vm_g = Counter(gstat(L) for L in groups.values())
    vm_s = Counter(i["isomer"] for i in vm)
    vm_osui = Counter("present" if any(x["osui"] == "present" for x in L) else "missing" for L in groups.values())

    env = [i for i in ok_items if i["container"] == "EnvironmentValues" and i["kind"] in ("var",)]
    env_st = Counter(i["isomer"] for i in env)
    scene = [i for i in ok_items if i["container"] == "Scene" and i["kind"] == "func"]
    scene_names = Counter(gstat([x for x in scene if x["name"] == n]) for n in set(x["name"] for x in scene))
    glob = [i for i in ok_items if i["container"] is None and i["kind"] in ("func", "macro")]
    iso_types = {i["key"][1] for i in ok_items if i["kind"] in TYPE_KINDS and i["isomer"] == "present"}

    def host_present(c):
        parts = c.split(".")
        return all(".".join(parts[:k]) in iso_types for k in range(1, len(parts) + 1))
    other_all = [i for i in ok_items if i["kind"] in ("func", "init", "var", "case", "subscript")
                 and i["container"] not in ("View", "EnvironmentValues", "Scene", None)]
    other = [i for i in other_all if host_present(i["container"])]
    other_in_missing = len(other_all) - len(other)
    other_st = Counter(i["isomer"] for i in other)
    inits_view_types = [i for i in other if i["kind"] == "init"]
    inits_st = Counter(i["isomer"] for i in inits_view_types)
    nested = [i for i in nested if host_present(i["container"])]
    nested_st = Counter("present" if i["isomer"] == "present" else "missing" for i in nested)

    # ---- priorities for every gap
    gap_rows = []
    for i in live_items:
        if i["isomer"] == "present":
            continue
        apps, old = usage_for(i)
        gp = False
        if i["container"] == "View" and i["kind"] == "func":
            gp = gstat(groups.get(i["name"], [i])) != "missing"
        gs = len(groups.get(i["name"], [i])) if (i["container"] == "View" and i["kind"] == "func") else 1
        p = priority(i, apps, old, gp, gs)
        if i["status"] == "soft-deprecated":
            p = "dep"
        i["prio"] = p
        i["area"] = area_of(i)
        i["usage"] = (apps, old)
        gap_rows.append(i)
    # fold members/nested types of types Isomer lacks into that type's entry
    missing_types = {i["key"][1]: i for i in live_items if i["kind"] in TYPE_KINDS and i["isomer"] != "present"}
    folded_rows = []
    kept = []
    for i in gap_rows:
        c = i["container"]
        host = None
        if c:
            parts = c.split(".")
            for k in range(1, len(parts) + 1):
                q = ".".join(parts[:k])
                if q in missing_types:
                    host = missing_types[q]
                    break
        if host is not None and host is not i:
            host["folded"] = host.get("folded", 0) + 1
            folded_rows.append(i)
        else:
            kept.append(i)
    all_gap_rows = gap_rows
    gap_rows = kept
    prio_area = defaultdict(Counter)
    for i in gap_rows:
        prio_area[i["area"]][i["prio"]] += 1

    # ================================================================ write
    w("# SwiftUI public API coverage audit: Isomer")
    w("")
    w(f"Date: 2026-10-11. Isomer at `main` cffc3ef (working tree as checked out). "
      "Apple SDKs: Xcode 27.0 (27A266a), iPhoneOS 27.0 and MacOSX 27.0 SDKs, `SwiftUI` + `SwiftUICore` "
      "arm64e `.swiftinterface` files (4 files, about 123k lines).")
    w("")
    w("Compared by name: types by qualified name; members by container + base name + argument labels "
      "(a SwiftUI signature counts as present when Isomer can be called with the same labels, defaulted "
      "arguments and a trailing closure allowed). Argument *types* were compared only as a heuristic "
      "(section 4). Read-only audit: no code changed, no builds run. Scripts and raw data: "
      "`/tmp/swiftui_audit/` (method in section 7).")
    w("")
    w("## 1. Summary")
    w("")
    w(notes.HEADLINE.format(
        tl_have=tl_st.get("present", 0) + tl_st.get("partial", 0), tl_total=sum(tl_st.values()),
        tl_present=tl_st.get("present", 0), vm_have=vm_g.get("present", 0) + vm_g.get("partial", 0),
        vm_total=sum(vm_g.values()), env_present=env_st.get("present", 0), env_total=sum(env_st.values()),
        scene_total=sum(scene_names.values())))
    w("")
    w("### Counts")
    w("")
    w("In scope: public, non-SPI, non-underscored SwiftUI/SwiftUICore declarations available on iOS or macOS, "
      "not hard-deprecated, minus the skipped categories (section 7). Soft-deprecated API (`deprecated: 100000`, "
      "e.g. `foregroundColor`, `navigationBarTitle`) is counted separately.")
    w("")
    w("| Area of the API | In scope | Present | Partial | Missing | Isomer coverage |")
    w("| --- | ---: | ---: | ---: | ---: | ---: |")

    def row(name, st, total=None):
        total = total or sum(st.values())
        pr, pa, mi = st.get("present", 0), st.get("partial", 0), st.get("missing", 0)
        cov = (pr + 0.5 * pa) / total * 100 if total else 0
        w(f"| {name} | {total} | {pr} | {pa} | {mi} | {cov:.0f}% |")
    row("Top-level types (struct/class/enum/protocol/typealias)", tl_st)
    row("Nested types of the types Isomer declares (e.g. `Text.DateStyle`)", nested_st)
    row("View modifiers, by base name (e.g. `sheet`)", vm_g)
    row("View modifiers, by signature (base name + labels)", vm_s)
    row("Environment values (`EnvironmentValues` properties)", env_st)
    row("Scene modifiers, by base name", scene_names)
    row("Global functions & macros (`withAnimation`, `@Entry`, ...)", Counter(i["isomer"] for i in glob))
    row("Members of the types Isomer declares (inits, methods, properties, cases)", other_st)
    row("... of which initializers", inits_st)
    w("")
    w(f"Not in the table: {other_in_missing} members and nested types of the {tl_st.get('missing', 0)} "
      "top-level types Isomer lacks (they come with the type; section 3 lists each missing type once, with "
      "its member count).")
    w("")
    w("\"Partial\" for a type means Isomer declares it but lacks some of its in-scope members; for a "
      "modifier base name, that some of its overloads/label sets are missing; for a signature, that only "
      "some call forms compile (e.g. Isomer lacks a defaulted argument such as `onDismiss:`). Coverage "
      "column counts partial as half.")
    w("")
    w(f"Soft-deprecated but in scope: {len(soft)} items ({sum(1 for i in soft if i['isomer'] == 'present')} "
      f"present in Isomer). Hard-deprecated items excluded: {len(hard)}. Items skipped by category: "
      f"{sum(skipped.values())} (section 7).")
    w("")
    w("For reference, OpenSwiftUI (`~/Developer/OpenSwiftUI`, public declarations) has "
      f"{osui_tl.get('present', 0)} of the {len(tl)} top-level types and {vm_osui.get('present', 0)} of the "
      f"{len(groups)} View-modifier base names, against Isomer's {tl_st.get('present', 0) + tl_st.get('partial', 0)} "
      f"and {vm_g.get('present', 0) + vm_g.get('partial', 0)}. Isomer is ahead in navigation (35 names to 2), "
      "presentation (12 to 1), lists (13 to 4), scrolling (17 to 4) and search; OpenSwiftUI is ahead in layout "
      "(`Layout`, `ViewThatFits`, alignment guides), shapes and styles, animation (`Animatable`, transitions, "
      "`GeometryEffect`), gestures, text modifiers, preferences and the style protocols, the areas section 2 ranks "
      "highest, so its sources are a useful reference there.")
    w("")
    w("### Gaps by area and priority")
    w("")
    w("P1 = commonly used in typical apps; P2 = less common; P3 = niche, platform-specific or new in the "
      "26/27 SDKs. `dep` = soft-deprecated API Isomer lacks. Counts are signatures/members/types, not base names.")
    w("")
    w("| Area | P1 | P2 | P3 | dep |")
    w("| --- | ---: | ---: | ---: | ---: |")
    tot = Counter()
    for a in AREA_ORDER:
        c = prio_area.get(a)
        if not c:
            continue
        tot.update(c)
        w(f"| {a} | {c.get('P1', 0)} | {c.get('P2', 0)} | {c.get('P3', 0)} | {c.get('dep', 0)} |")
    w(f"| **Total** | **{tot.get('P1', 0)}** | **{tot.get('P2', 0)}** | **{tot.get('P3', 0)}** | **{tot.get('dep', 0)}** |")
    w("")

    # ---- top P1 list (curated)
    w("## 2. Top P1 gaps")
    w("")
    w(notes.TOP_P1_INTRO)
    w("")
    for k, (title, body) in enumerate(notes.TOP_P1, 1):
        w(f"{k}. **{title}** {body}")
    w("")

    # ---- per-area lists
    w("## 3. Gaps by area")
    w("")
    w("Each area lists P1 then P2 gaps with the SwiftUI signatures (module prefixes and attributes "
      "stripped; one line per overload), then P3 by name. `usage a/o` = call sites in apps written on Isomer "
      "/ older native SwiftUI code (section 7); `Skip` = SkipUI's support level for that name; "
      "`OSUI` = OpenSwiftUI declares it. A partial modifier lists only its missing signatures, with what "
      "Isomer has.")
    w("")
    by_area = defaultdict(list)
    split_prios = defaultdict(set)
    for i in gap_rows:
        by_area[i["area"]].append(i)
        if i["container"] == "View" and i["kind"] == "func":
            split_prios[i["name"]].add(i["prio"])
    for a in AREA_ORDER:
        L = by_area.get(a)
        if not L:
            continue
        w(f"### {a}")
        w("")
        if a in notes.AREA_NOTES:
            w(notes.AREA_NOTES[a])
            w("")
        for pr in ("P1", "P2"):
            PL = [i for i in L if i["prio"] == pr]
            if not PL:
                continue
            w(f"**{pr}**")
            w("")
            emit_items(w, PL, groups, full=True, split=split_prios)
            w("")
        P3 = [i for i in L if i["prio"] == "P3"]
        if P3:
            names = sorted(set(short_name(i) for i in P3))
            w(f"**P3** ({len(P3)}): " + ", ".join(f"`{n}`" for n in names))
            w("")
        DEP = [i for i in L if i["prio"] == "dep"]
        if DEP:
            names = sorted(set(short_name(i) + (f" [a/o {i['usage'][0]}/{i['usage'][1]}]" if sum(i['usage']) else "") for i in DEP))
            w(f"**Soft-deprecated, missing** ({len(DEP)}): " + ", ".join(f"`{n}`" for n in names))
            w("")

    # ---- type heuristic
    w("## 4. Present by name, narrower by type")
    w("")
    w(notes.TYPE_GAPS_INTRO)
    w("")
    for title, body in notes.TYPE_GAPS:
        w(f"- **{title}** {body}")
    w("")

    # ---- no-ops
    w("## 5. No-ops and partial behaviour in Isomer")
    w("")
    w(notes.NOOPS_INTRO)
    w("")
    for title, body in notes.NOOPS:
        w(f"- **{title}** {body}")
    w("")
    w("Mechanical scan (public functions whose body is empty, returns `self`, or never reads a parameter; "
      "`/tmp/swiftui_audit/noops.py`, 91 hits), SwiftUI-facing entries not already covered above:")
    w("")
    covered = notes.NOOPS_COVERED
    extra = 0
    for o in NOOPS:
        loc = f"{o['path']}:{o['line']}"
        if loc in covered or "HostBridge" in o["sig"] or o["path"].startswith("shared/renderers") \
                or "Runtime.swift" in o["path"] or "HotBridge" in o["path"]:
            continue
        if any(f == "empty" for f in o["flags"]) and "params" not in " ".join(o["flags"]):
            continue
        w(f"- `{loc}` `{o['name']}`: {'; '.join(o['flags'])}")
        extra += 1
    if not extra:
        w("- nothing beyond the list above; its other hits are host-bridge defaults, renderer internals, and benign "
          "cases (type-only generic parameters such as `onScrollGeometryChange(for:)`, `clipShape(Circle)`, "
          "string-interpolation capacity hints).")
    w("")

    # ---- soft-deprecated still common
    w("## 6. Soft-deprecated API")
    w("")
    w(notes.SOFT_DEP)
    w("")
    rows = []
    for i in soft:
        if i["container"] == "View" and i["kind"] == "func":
            apps, old = usage(i["name"], "modifier")
            rows.append((old + apps, f"{i['name']}({i['labels']})", i["isomer"], apps, old))
    rows.sort(key=lambda r: (-r[0], r[1]))
    w("| Soft-deprecated signature | Isomer | base-name usage a/o |")
    w("| --- | --- | ---: |")
    for _, n, st, a_, o_ in rows:
        if a_ + o_ == 0:
            continue
        w(f"| `.{n}` | {st} | {a_}/{o_} |")
    w("")
    w("Others (no usage of the base name in either corpus): " +
      ", ".join(f"`.{n}` ({st})" for _, n, st, a_, o_ in rows if a_ + o_ == 0) + ".")
    w("")

    # ---- method
    w("## 7. Method, scope and limitations")
    w("")
    w(notes.METHOD)
    w("")
    w("Skipped categories (declarations, both platforms merged):")
    w("")
    for k, v in skipped.most_common():
        w(f"- {k}: {v}")
    w(f"- Per-platform records marked unavailable on that platform: {R['dropped_unavailable']} (an item available "
      "on the other platform is kept; watchOS/tvOS/visionOS-only API drops out here)")
    w(f"- Hard-deprecated: {len(hard)}")
    w("")
    w(notes.LIMITS)
    w("")
    w("## Appendix: Isomer public API that is not SwiftUI's")
    w("")
    w(notes.ISO_ONLY_INTRO)
    w("")
    io = R["isomer_only"]
    tys = sorted(set(x["name"] for x in io if x["kind"] in TYPE_KINDS))
    mods = sorted(set(x["name"] for x in io if x["kind"] not in TYPE_KINDS and not x["name"].endswith(".body()")))
    w("Types: " + ", ".join(f"`{t}`" for t in tys))
    w("")
    w("Members on SwiftUI types: " + ", ".join(f"`{t}`" for t in mods))
    w("")
    open("/tmp/swiftui_api_audit.md", "w").write("\n".join(lines) + "\n")

    # full TSV
    with open(f"{D}/gaps_full.tsv", "w") as f:
        f.write("priority\tarea\tstatus\tcontainer\tname\tlabels\tplatforms\tintroduced\tusage_apps\tusage_old\tskipui\topenswiftui\tsignatures\n")
        for i in sorted(all_gap_rows, key=lambda x: (x["prio"], x["area"], x["container"] or "", x["name"])):
            f.write("\t".join(str(v) for v in [
                i["prio"], i["area"], i["isomer"], i["container"] or "", i["name"], i["labels"],
                ",".join(i["plats"]), json.dumps(i.get("introduced", {})), i["usage"][0], i["usage"][1],
                i.get("skipui") or "", i["osui"], " || ".join(sigs_of(i))]) + "\n")
    print("P:", dict(tot), "types", dict(tl_st), "nested", dict(nested_st), "vm groups", dict(vm_g),
          "vm sigs", dict(vm_s), "env", dict(env_st), "scene", dict(scene_names), "other", dict(other_st),
          "inits", dict(inits_st), file=sys.stderr)


def short_name(i):
    if i["kind"] in TYPE_KINDS:
        return i["key"][1]
    c = i["container"]
    pre = f"{c}." if c and c != "View" else ("." if c == "View" else "")
    return f"{pre}{i['name']}({i['labels']})" if i["kind"] in ("func", "init", "subscript") else f"{pre}{i['name']}"


def emit_items(w, L, groups, full=True, split=None):
    # types first, then view modifiers grouped by base name, then other members grouped by container
    types = [i for i in L if i["kind"] in TYPE_KINDS]
    mods = [i for i in L if i["container"] == "View" and i["kind"] not in TYPE_KINDS]
    rest = [i for i in L if i not in types and i not in mods]
    concrete = defaultdict(list)
    plain_types = []
    for i in types:
        m = re.search(r"^(?:final )?(?:struct|class) \w+(?:<[^>]*>)? : (\w*Style)\b", sigs_of(i, 1)[0] if sigs_of(i, 1) else "")
        if m and i["key"][1].endswith("Style") and "." not in i["key"][1]:
            concrete[m.group(1)].append(i)
        else:
            plain_types.append(i)
    for proto in sorted(concrete):
        names = ", ".join(f"`{x['key'][1]}`" + (f" (a/o {x['usage'][0]}/{x['usage'][1]})" if sum(x["usage"]) else "")
                          for x in sorted(concrete[proto], key=lambda x: x["key"][1]))
        w(f"- concrete `{proto}` types: {names}")
    for i in sorted(plain_types, key=lambda x: x["key"][1]):
        a, o = i["usage"]
        meta = meta_str(i, a, o)
        fold = f" +{i['folded']} members" if i.get("folded") else ""
        w(f"- type `{i['key'][1]}` ({i['kind']}{fold}) {meta}")
        for s in sigs_of(i, 1):
            w(f"  - `{s[:300]}`")
    mg = defaultdict(list)
    for i in mods:
        mg[i["name"]].append(i)
    for n in sorted(mg, key=lambda n: (-sum(mg[n][0]["usage"]), n)):
        GL = mg[n]
        allg = groups.get(n, GL)
        have = sorted(set(x["labels"] for x in allg if x["isomer"] == "present"))
        st = "partial" if have or any(x["isomer"] == "partial" for x in allg) else "missing"
        a, o = GL[0]["usage"]
        meta = meta_str(GL[0], a, o)
        hv = f"; Isomer has `{', '.join(n + '(' + h + ')' for h in have)}`" if have else ""
        here = GL[0]["prio"]
        others = sorted(p for p in (split or {}).get(n, set()) if p != here and p in ("P1", "P2", "P3"))
        if others:
            hv += f"; more overloads under {'/'.join(others)}"
        w(f"- `.{n}` ({st}{hv}) {meta}")
        for i in sorted(GL, key=lambda x: x["labels"]):
            tag = " (only some call forms)" if i["isomer"] == "partial" else ""
            for s in sigs_of(i):
                w(f"  - `{s[:400]}`{tag}")
    cg = defaultdict(list)
    for i in rest:
        cg[i["container"] or "global functions and macros"].append(i)
    for c in sorted(cg):
        w(f"- `{c}`:")
        for i in sorted(cg[c], key=lambda x: (x["name"], x["labels"])):
            tag = " (partial)" if i["isomer"] == "partial" else ""
            a, o = i["usage"]
            for s in sigs_of(i, 2):
                w(f"  - `{s[:400]}`{tag}{(' ' + meta_str(i, a, o)) if (a or o or i.get('skipui')) else ''}")


def meta_str(i, a, o):
    bits = []
    plats = i["plats"]
    if len(plats) == 1:
        bits.append(f"{plats[0]} only")
    intro = i.get("introduced") or {}
    if intro.get("iOS"):
        bits.append(f"iOS {intro['iOS']}")
    elif intro.get("macOS"):
        bits.append(f"macOS {intro['macOS']}")
    if a or o:
        bits.append(f"usage {a}/{o}")
    if i.get("skipui"):
        bits.append(f"Skip {i['skipui']}")
    if i.get("osui") == "present":
        bits.append("OSUI")
    return "[" + "; ".join(bits) + "]" if bits else ""


if __name__ == "__main__":
    main()
