"""Compare Apple's SwiftUI public API (apple_api.json) with Isomer's
(isomer_api.json) and OpenSwiftUI's (openswiftui_api.json). Writes results.json.

Matching is by name: types by qualified name; members by container + base name
+ argument labels (defaulted parameters may be omitted; the first of a run of
trailing closure parameters may be unlabeled). Argument *types* are compared
only as a secondary heuristic (overload gaps)."""
import itertools
import json
import os
import re
from collections import defaultdict

D = os.path.dirname(os.path.abspath(__file__))
TYPE_KINDS = {"struct", "class", "enum", "protocol", "typealias", "actor"}

# --- categories skipped from the counts -------------------------------------
SKIP_RULES = [
    ("AppKit/UIKit hosting & interop (NS*/UI* types and extensions)", re.compile(r"^(NS|UI)[A-Z]")),
    ("Result/plumbing types users never name (Tuple*, LimitedAvailability*, Default*Label, Empty*Content, ...)",
     re.compile(r"^(Tuple\w+|LimitedAvailability\w+|Empty(?!View$|Modifier$|AnimatableData$)\w+|Default\w*(Label|Content|Actions|LaunchActions)|"
                r"Indexed\w*Collection|Group(Sections|Elements)Of\w+|DebugReplaceableView|LazyState|ReorderDifference|"
                r"OnInsertTableRowModifier|ConditionalContent|ModifiedContent|AnyTabContent|AnyCompositorContent|"
                r"ExpansionState|IdentifiedPreferenceTypes|PreferredColorSchemeKey|ChildCollection)$")),
    ("Widgets / control widgets / Live Activities / Watch", re.compile(r"^(ControlWidget\w*|\w*WidgetConfiguration|\w*WidgetTemplate\w*|WidgetAccentedRenderingMode|ActivityViewContext)$")),
    ("Immersive / spatial / compositor (visionOS family)", re.compile(r"^(Compositor\w*|ProgressiveImmersion\w*|Chirality|ImmersionStyle\w*|RemoteDeviceIdentifier|Volumetric\w*|\w*Immersive\w*|AssistiveAccess\w*)$")),
    ("Xcode Previews", re.compile(r"^(Preview|_Preview|PreviewProvider|PreviewContext|PreviewDevice|PreviewPlatform|PreviewLayout|PreviewModifier|PreviewTrait|DeveloperToolsSupport)")),
    ("Core Data integration", re.compile(r"^(FetchRequest|FetchedResults|SectionedFetchRequest|SectionedFetchResults)$")),
    ("Widgets / control widgets / Live Activities / Watch", re.compile(r"^(Widget|WidgetConfiguration|WidgetBundle|WidgetFamily|WidgetRenderingMode|AccessoryWidgetGroup|ActivityConfiguration|WKInterfaceObjectRepresentable|WKApplicationDelegateAdaptor|WKExtensionDelegateAdaptor)")),
    ("Immersive / spatial / compositor (visionOS family)", re.compile(r"^(ImmersiveSpace|ImmersionStyle|ImmersiveSpaceContent|ImmersiveSpaceContentBuilder|ImmersiveContentBrightness|OpenImmersiveSpaceAction|DismissImmersiveSpaceAction|ImmersiveEnvironmentBehavior|SurroundingsEffect|VolumetricWindowStyle|WorldTrackingLimitation|Model3D|SpatialEventCollection|SpatialEventGesture|ProjectiveTransform|RemoteImmersiveSpace|Alignment3D|Rotation3D|Point3D|Size3D|Vector3D|Rect3D|DepthAlignment|HorizontalAlignment3D|VerticalAlignment3D|GeometryProxy3D|Edge3D|Angle3D|AffineTransform3D|ViewAlignedVolume|PhysicalMetric|RealityKit|ContentWorldOrientation|WorldAlignmentBehavior|WorldRecenterPhase|SurfaceSnappingInfo|SpatialContainer|SpatialOverlay|PresentationComponent|BreakthroughEffect|WindowManagerRole|ManipulationBehavior|AttachmentProxy)")),
]
SKIP_MEMBER_CONTAINERS = re.compile(r"^(ModifiedContent|TableColumnBuilder|ToolbarContentBuilder|ViewBuilder|SceneBuilder|CommandsBuilder|TabContentBuilder|SliderTickBuilder|KeyframesBuilder|AccessibilityRotorContentBuilder|TableRowBuilder|ContentBuilder|AttributedTextFormatting\.DefinitionBuilder|AttributeScopes|Never|Optional|Swift|CGFloat|CGPoint|CGSize|CGRect|CGAffineTransform|Double|Float|Int|Array|Set|Dictionary|Range|ClosedRange|Bool|String|Substring|AttributedString|NSAttributedString|Date|URL|Data|ProjectionTransform|Image\.Resolved|Color\.ResolvedHDR|UnitCurve|AnyHashable)(\.|$)")
SKIP_VIEW_MODIFIER_NAMES = re.compile(r"^(preview|widget|activity|complication|digitalCrown|focusSection|onPlayPauseCommand|onExitCommand|immersive|upperLimbVisibility|persistentSystemOverlays|ornament|glassBackgroundEffect|volumeBaseplate|hoverEffect3D|supportedVolumeViewpoints|onVolumeViewpointChange|preferredSurroundingsEffect|manipulable|realityViewCameraControls|handGestureShortcut|scrollInputBehavior|onWorldRecenter|windowGeometry|spatialOverlay|gestureContentShape3D|breakthroughEffect|presentationBreakthroughEffect|depth|rotation3DLayout|perspectiveRotationEffect|frame\(depth|offset\(z|preferredWindowClippingMargins)")


WITNESS_ALIASES = {"AllCases", "RawValue", "Body", "AnimatableData", "ID", "Element", "Index", "Indices", "Iterator",
                   "SubSequence", "FormatInput", "FormatOutput", "Specification", "ArrayLiteralElement",
                   "StringLiteralType", "ExtendedGraphemeClusterLiteralType", "UnicodeScalarLiteralType",
                   "IntegerLiteralType", "FloatLiteralType", "Stride", "Magnitude", "Content", "Label",
                   "Configuration", "Value", "Key", "Data", "Destination", "Item", "Root", "Placeholder"}


def skip_category(rec):
    head = (rec["container"] or rec["name"]).split(".")[0]
    for cat, rx in SKIP_RULES:
        if rx.match(head):
            return cat
    if rec["container"] in ("View", "Scene") and SKIP_VIEW_MODIFIER_NAMES.match(rec["name"]):
        return "Platform-exclusive modifiers (watch/tv/vision/widgets/previews)"
    if rec.get("kind") == "typealias" and rec["container"] and rec["name"] not in ("Components",):
        # nested typealiases are associated-type witnesses (Body, TabValue, TableRowValue, ...)
        return "Protocol-conformance witnesses (==, hash, Codable, Collection, ...)"
    if rec["container"] and SKIP_MEMBER_CONTAINERS.match(rec["container"]):
        return "Builder plumbing / extensions of Swift & CoreGraphics types"
    return None


def underscored(rec):
    if rec["name"].startswith("_"):
        return True
    return any(p.startswith("_") for p in (rec["container"] or "").split("."))


# --- type normalization for the overload heuristic --------------------------
ATTR_STRIP = re.compile(r"@[\w.]+(\([^)]*\))?\s*")
TEXTY = {"LocalizedStringKey", "StringProtocol", "String", "Text", "LocalizedStringResource", "AttributedString", "Substring"}
NUMY = {"CGFloat", "Double", "Float", "Int", "BinaryFloatingPoint", "BinaryInteger"}


def norm_param_type(t, generics):
    if "@autoclosure" in t:
        t = t.split("->", 1)[1] if "->" in t else t
    t = ATTR_STRIP.sub("", t).replace("sending ", "").replace("inout ", "").strip()
    t = re.sub(r"\b(some|any)\s+", "", t)
    # closure at top level
    depth = 0
    for i, c in enumerate(t):
        if c in "(<[":
            depth += 1
        elif c in ")>]":
            if not (c == ">" and i and t[i - 1] == "-"):
                depth -= 1
        elif t[i:i + 2] == "->" and depth == 0:
            return "closure"
    opt = t.endswith("?") or t.endswith("!")
    base = t.rstrip("?!").strip()
    if base.startswith("(") and base.endswith(")") and "->" in base:
        return "closure" + ("?" if opt else "")
    def sub(name):
        if name in generics:
            c = generics[name]
            if c.startswith("=="):
                return c[2:].strip()
            c = c.split("&")[0].strip()
            return c or "Any"
        return name
    m = re.match(r"^([\w.]+)(<.*>)?$", base)
    if m:
        name = sub(m.group(1))
        args = m.group(2)
        if args:
            inner = [norm_param_type(a, generics) for a in split(args[1:-1])]
            name = f"{name}<{','.join(inner)}>"
    else:
        name = base
    first = name.split("<")[0]
    if first in TEXTY:
        name = "text"
    elif first in NUMY:
        name = "num"
    return name + ("?" if opt else "")


def split(s):
    out, d, cur = [], 0, ""
    for c in s:
        if c in "(<[":
            d += 1
        elif c in ")>]":
            d -= 1
        if c == "," and d == 0:
            out.append(cur)
            cur = ""
        else:
            cur += c
    if cur.strip():
        out.append(cur)
    return out


def type_tuple(rec):
    g = rec.get("generics") or {}
    return tuple(norm_param_type(p[3], g) for p in rec.get("params", []))


# --- label matching ----------------------------------------------------------
def is_closure(ptype):
    return "->" in ptype


def label_variants(params):
    """All label sequences a call can use: defaulted params omitted in any
    combination; the first parameter of a trailing run of closures written
    as a trailing closure (label dropped -> '*')."""
    out = set()
    idx_default = [i for i, p in enumerate(params) if p[1]]
    if len(idx_default) > 9:
        idx_default = idx_default[:9]
    for k in range(len(idx_default) + 1):
        for drop in itertools.combinations(idx_default, k):
            kept = [p for i, p in enumerate(params) if i not in drop]
            labels = tuple(p[0] for p in kept)
            out.add(labels)
            # trailing closures
            j = len(kept)
            while j > 0 and is_closure(kept[j - 1][3]):
                j -= 1
            if j < len(kept):
                tl = list(labels)
                tl[j] = "*"
                out.add(tuple(tl))
    return out


def full_variants(params):
    labels = tuple(p[0] for p in params)
    out = {labels}
    j = len(params)
    while j > 0 and is_closure(params[j - 1][3]):
        j -= 1
    if j < len(params):
        tl = list(labels)
        tl[j] = "*"
        out.add(tuple(tl))
    return out


class Index:
    def __init__(self, recs):
        self.types = {}
        self.members = defaultdict(list)  # (container, name) -> [rec]
        self.names_by_container = defaultdict(set)
        for r in recs:
            if not r["public"] or r.get("status") == "unavailable":
                continue
            if r["kind"] in TYPE_KINDS:
                q = f"{r['container']}.{r['name']}" if r["container"] else r["name"]
                self.types.setdefault(q, r)
            elif r["kind"] in ("func", "init", "subscript", "var", "case", "macro"):
                self.members[(r["container"], r["name"])].append(r)
                self.names_by_container[r["container"]].add(r["name"])

    def has_type(self, q):
        if q in self.types:
            return True
        # a nested type can be declared as a typealias in an extension elsewhere
        return False

    def lookup(self, containers, name):
        out = []
        for c in containers:
            out += self.members.get((c, name), [])
        return out


# Isomer spells style protocols as option structs with static members
STYLE_OPTION = {"ButtonStyle": "ButtonStyleOption", "PrimitiveButtonStyle": "ButtonStyleOption",
                "ListStyle": "ListStyleOption", "TextFieldStyle": "TextFieldStyleOption",
                "LabelStyle": "LabelStyleOption"}
# members every conforming type gets from Equatable/Hashable/Codable/
# CustomStringConvertible/Collection etc.; not SwiftUI API in their own right
STD_WITNESS = {"==", "!=", "<", "hash", "hashValue", "description", "debugDescription", "customMirror",
               "encode", "startIndex", "endIndex", "index", "formIndex", "indices", "makeIterator",
               "animatableData", "rawValue", "allCases", "Iterator", "Element", "Index", "Indices", "SubSequence",
               "ID", "id", "+", "-", "*", "/", "+=", "-=", "*=", "/=", "magnitudeSquared", "scale", "zero"}


def is_witness(it):
    n, labels = it["name"], it.get("labels", "")
    if it["kind"] == "init" and labels in ("from:", "rawValue:"):
        return True
    if n in ("+", "-", "*", "/", "==", "!=", "<", "+=", "-=", "*=", "/=", "~="):
        return True
    if n in ("scale",) and it["container"] not in ("Shape", "View", "AnyTransition", "Image", "Text"):
        return n == "scale" and labels == "by:"
    return n in STD_WITNESS and it["container"] not in ("View",) and n not in ("scale", "id") or (n == "id" and it["kind"] == "var" and it["container"] not in ("View",))


def containers_for(rec):
    cs = [rec["container"]]
    if rec["container"] in STYLE_OPTION:
        cs.append(STYLE_OPTION[rec["container"]])
    if rec.get("where_alt"):
        cs.append(rec["where_alt"])
    # Apple puts view-content modifiers on protocols Isomer may host on View
    if rec["container"] in ("ShapeView", "InsettableShape"):
        cs += ["Shape"]
    if rec["container"] == "Shape":
        cs += ["InsettableShape"]
    return cs


def match_member(rec, idx):
    """'present' | 'partial' | 'missing', plus how."""
    cands = idx.lookup(containers_for(rec), rec["name"])
    if rec["kind"] in ("var", "case"):
        if cands:
            return "present", "name"
        # a static var on Apple can be a static func with defaults on Isomer
        return "missing", ""
    if not cands:
        # SwiftUI has many text/image modifiers on View too (iOS 16+);
        # Isomer may offer them only on Text / Image / Shape
        if rec["container"] == "View":
            for alt in ("Text", "Image", "Shape"):
                if idx.lookup([alt], rec["name"]):
                    return "partial", f"only on {alt}"
        return "missing", ""
    cands_fn = [c for c in cands if c["kind"] in ("func", "init", "subscript")]
    if rec["kind"] in ("func", "init", "subscript"):
        want = full_variants([tuple(p) for p in rec["params"]])
        have = set()
        for c in cands_fn:
            have |= label_variants([tuple(p) for p in c["params"]])
        if want & have:
            return "present", "labels"
        # partial: some reduced call form works (e.g. a defaulted argument
        # Isomer does not take)
        some = label_variants([tuple(p) for p in rec["params"]])
        if some & have:
            return "partial", "some-call-forms"
        # the base name exists, but not with these labels: this signature is
        # missing (its group is partial)
        return "missing", "other-labels"
    return "missing", ""


def main():
    apple = json.load(open(f"{D}/apple_api.json"))
    iso = json.load(open(f"{D}/isomer_api.json"))
    extras = json.load(open(f"{D}/isomer_extras_api.json"))
    osui = json.load(open(f"{D}/openswiftui_api.json"))
    skip_api = json.load(open(f"{D}/skip_supported.json"))
    skip_names = {}
    for e in skip_api:
        n = e["api"].lstrip("@.").split("(")[0].strip()
        skip_names[n] = e["level"]
    I = Index(iso)
    X = Index(extras)
    O = Index(osui)

    # merge Apple records across platforms/modules
    items = {}
    skipped = defaultdict(set)
    dropped_unavailable = 0
    for r in apple:
        if not r["public"] or r["spi"] or underscored(r):
            continue
        if r["kind"] in ("extension", "associatedtype", "import", "deinit", "operator", "precedencegroup"):
            continue
        if r["status"] == "unavailable":
            dropped_unavailable += 1
            continue
        if r["kind"] in TYPE_KINDS:
            key = ("type", f"{r['container']}.{r['name']}" if r["container"] else r["name"], "")
        else:
            labels = r.get("labels", "")
            key = (r["kind"] if r["kind"] not in ("case",) else "var", f"{r['container']}.{r['name']}" if r["container"] else r["name"], labels)
        it = items.get(key)
        if not it:
            it = items[key] = {
                "key": list(key), "kind": r["kind"], "name": r["name"], "container": r["container"],
                "labels": r.get("labels", ""), "params": r.get("params", []), "generics": r.get("generics", {}),
                "where_alt": r.get("where_alt"), "static": r["static"], "platforms": {}, "modules": set(),
                "sigs": set(), "type_tuples": set(), "raw": r["raw"],
            }
        it["platforms"].setdefault(r["platform"], set()).add(r["status"])
        if r.get("introduced"):
            it.setdefault("introduced", {})[r["platform"]] = r["introduced"]
        it["modules"].add(r["module"])
        if r["kind"] in ("func", "init", "subscript"):
            it["type_tuples"].add(type_tuple(r))
            if r["status"] not in ("deprecated",):
                it["sigs"].add(r["raw"])
        if not it.get("where_alt") and r.get("where_alt"):
            it["where_alt"] = r["where_alt"]

    out = []
    for key, it in items.items():
        # deprecation status across platforms: best status wins
        best = "unavailable"
        order = ["ok", "soft-deprecated", "deprecated", "unavailable"]
        for plat, sts in it["platforms"].items():
            for s in sts:
                if order.index(s) < order.index(best):
                    best = s
        it["status"] = best
        it["plats"] = sorted(it["platforms"].keys())
        cat = skip_category({"container": it["container"], "name": it["name"], "kind": it["kind"], "raw": it["raw"]})
        if it["kind"] in TYPE_KINDS and not it["container"]:
            cat = cat or skip_category({"container": None, "name": it["name"]})
        if not cat and it["kind"] not in TYPE_KINDS and is_witness(it):
            cat = "Protocol-conformance witnesses (==, hash, Codable, Collection, ...)"
        it["skip"] = cat
        rec = {"kind": it["kind"], "name": it["name"], "container": it["container"],
               "params": it["params"], "where_alt": it["where_alt"]}
        if it["kind"] in TYPE_KINDS:
            q = key[1]
            it["isomer"] = "present" if I.has_type(q) else "missing"
            it["isomer_how"] = I.types[q]["kind"] if q in I.types else ""
            it["extras"] = X.has_type(q)
            it["osui"] = "present" if O.has_type(q) else "missing"
        else:
            # all overloads with the same labels were merged; match on labels
            st, how = match_member(rec, I)
            it["isomer"], it["isomer_how"] = st, how
            it["extras"] = match_member(rec, X)[0] == "present"
            it["osui"] = match_member(rec, O)[0]
            # overload-type heuristic
            if st == "present" and it["kind"] in ("func", "init"):
                cands = I.lookup(containers_for(rec), it["name"])
                have = set()
                for c in cands:
                    if c["kind"] in ("func", "init"):
                        have.add(type_tuple(c))
                missing_tt = []
                for tt in it["type_tuples"]:
                    # compare positionally on the labels Apple uses
                    if tt not in have:
                        missing_tt.append(tt)
                it["missing_type_overloads"] = [list(t) for t in missing_tt]
                it["isomer_type_tuples"] = [list(t) for t in have]
        it["skipui"] = skip_names.get(it["name"]) if (it["container"] in (None, "View", "Shape", "Image", "Text", "ShapeStyle", "InsettableShape") or it["kind"] in TYPE_KINDS) else None
        it["modules"] = sorted(it["modules"])
        it["sigs"] = sorted(it["sigs"])
        it["type_tuples"] = [list(t) for t in it["type_tuples"]]
        it["platforms"] = {k: sorted(v) for k, v in it["platforms"].items()}
        out.append(it)

    # Isomer public names that SwiftUI lacks (non-underscored), for context
    apple_types = {i["key"][1] for i in out if i["kind"] in TYPE_KINDS}
    apple_members = {(i["container"], i["name"]) for i in out if i["kind"] not in TYPE_KINDS}
    iso_only = []
    for q, r in I.types.items():
        if q not in apple_types and not any(p.startswith("_") for p in q.split(".")):
            iso_only.append({"kind": r["kind"], "name": q, "path": r["path"], "line": r["line"]})
    for (c, n), rs in I.members.items():
        if (c, n) in apple_members or n.startswith("_") or (c or "").startswith("_"):
            continue
        if c in ("View", "Scene", "App", "Text", "Image", "Shape", "EnvironmentValues"):
            r = rs[0]
            iso_only.append({"kind": r["kind"], "name": f"{c}.{n}({r.get('labels', '')})", "path": r["path"], "line": r["line"]})

    json.dump({"items": out, "dropped_unavailable": dropped_unavailable, "isomer_only": iso_only},
              open(f"{D}/results.json", "w"), indent=0, default=list)
    print(len(out), "items")


if __name__ == "__main__":
    main()
