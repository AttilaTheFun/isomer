#!/usr/bin/env python3
"""Writes docs/parity/: for each Apple framework Isomer provides off Apple
platforms, what of Apple's interface Isomer implements, what it does not,
why, and whether it means to.

    tools/parity/parity.py            (from the isomer checkout; builds what it reads)

Both sides are symbol graphs. Apple's come from the installed Xcode's iOS SDK
(`swift-symbolgraph-extract`, which also gives the Swift view of a framework
written in C or Objective-C). Isomer's come from its modules as built for
wasm, the compiler writing their graphs as it compiles them. A declaration
matches when its path, name (with argument labels) and parameter types match.

Apple's declarations that are private (an underscore), unavailable or
deprecated on iOS are not counted. The rest that Isomer lacks are sorted by
tools/parity/reasons/<Module>.json into groups, each with why it is missing
and whether it is planned, maybe, or not planned; what no group claims is
listed as not yet classified.
"""

import collections
import datetime
import glob
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APPLE_DIR = "/tmp/isomer_parity/apple"
# macOS's graphs: what counts is iOS's interface, but a declaration Apple has
# on macOS only (the Mac's toolbar placements) is Apple's, not an addition.
APPLE_MAC_DIR = "/tmp/isomer_parity/apple_macos"
ISOMER_DIR = "/tmp/isomer_parity/isomer"
# The same modules as Android and the CLI (macOS) build them: compared too,
# for docs/parity/superset.md (the wasm build is what --check reads).
ISOMER_ANDROID_DIR = "/tmp/isomer_parity/isomer_android"
ISOMER_CLI_DIR = "/tmp/isomer_parity/isomer_cli"
OUT_DIR = os.path.join(ROOT, "docs", "parity")
REASONS_DIR = os.path.join(ROOT, "tools", "parity", "reasons")

# Each report: Apple's modules (with a filter on which of their symbols
# belong to it) and Isomer's.
MODULES = [
    {
        "name": "CoreGraphics",
        "sources": ["core_graphics"],
        "apple": [("CoreGraphics", None), ("CoreFoundation", r"^CG")],
        "isomer": ["CoreGraphics"],
        "isomer_where": "`core_graphics/` (module `CoreGraphics`)",
    },
    {
        "name": "Foundation",
        "sources": ["foundation"],
        "apple": [("Foundation", None)],
        "isomer": ["Foundation", "FoundationEssentials", "FoundationInternationalization"],
        "isomer_where": "`foundation/` (module `Foundation`) over the swift-foundation fork's FoundationEssentials, and its FoundationInternationalization with ICU when an app builds with `--@isomer//foundation:internationalization`",
    },
    {
        "name": "SwiftUI",
        "sources": ["shared/swift_ui_core", "shared/renderers", "wasm/libraries/swift_ui", "android/libraries/swift_ui"],
        "apple": [("SwiftUI", None), ("SwiftUICore", None)],
        "isomer": ["SwiftUI"],
        "isomer_where": "`shared/swift_ui_core`, `shared/renderers` and the wasm host (module `SwiftUI`)",
    },
    {
        "name": "Metal",
        "sources": ["metal/metal"],
        "apple": [("Metal", None)],
        "isomer": ["Metal"],
        "isomer_where": "`metal/metal` (module `Metal`) over `metal/isomer_metal` (IsomerMetal: the shader translator and the backend interface), with WebGPU in a browser (`metal/web`, `metal/runtime`)",
    },
    {
        "name": "CoreTransferable",
        "sources": ["frameworks/core_transferable"],
        "apple": [("CoreTransferable", None)],
        "isomer": ["CoreTransferable"],
        "isomer_where": "`frameworks/core_transferable` (module `CoreTransferable`), which Isomer's SwiftUI re-exports as Apple's does",
    },
    {
        "name": "UniformTypeIdentifiers",
        "sources": ["frameworks/uniform_type_identifiers"],
        "apple": [("UniformTypeIdentifiers", None)],
        "isomer": ["UniformTypeIdentifiers"],
        "isomer_where": "`frameworks/uniform_type_identifiers` (module `UniformTypeIdentifiers`)",
    },
    {
        "name": "PhotosUI",
        "sources": ["frameworks/photos_ui"],
        # The SwiftUI picker is PhotosUI's cross-import overlay with SwiftUI.
        "apple": [("PhotosUI", None), ("_PhotosUI_SwiftUI", None)],
        "isomer": ["PhotosUI"],
        "isomer_where": "`frameworks/photos_ui`, compiled over each platform's SwiftUI (module `PhotosUI`)",
    },
    {
        "name": "ImageIO",
        "sources": ["shared/image_io"],
        "apple": [("ImageIO", None)],
        "isomer": ["ImageIO"],
        "isomer_where": "`shared/image_io` (module `ImageIO`), the decoding the renderers' images need, on wasm and Android",
        # Not a strict subset yet (docs/parity/superset.md says how not):
        # reported, and listed there, but not failed by --check.
        "known_gap": True,
    },
    {
        "name": "Observation",
        "apple": [("Observation", None)],
        "isomer": ["Observation"],
        "isomer_where": "the Swift toolchain's own module (the wasm SDK's)",
        "toolchain": True,
    },
    {
        "name": "Synchronization",
        "apple": [("Synchronization", None)],
        "isomer": ["Synchronization"],
        "isomer_where": "the Swift toolchain's own module (the wasm SDK's)",
        "toolchain": True,
    },
]


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


# MARK: - Symbol graphs


# Apple's modules read only for what Apple's types have through them
# (NSObject's members, the standard library's protocols), never counted.
SUPPORT_MODULES = ["Swift", "ObjectiveC"]


def apple_graphs():
    sdk = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).strip()
    version = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"]).strip()
    os.makedirs(APPLE_DIR, exist_ok=True)
    modules = sorted({m for spec in MODULES for m, _ in spec["apple"]} | set(SUPPORT_MODULES))
    for module in modules:
        # A cross-import overlay's graphs come with its framework's.
        if glob.glob(os.path.join(APPLE_DIR, module + ".symbols.json")) \
                or glob.glob(os.path.join(APPLE_DIR, module + "@*.symbols.json")):
            continue
        subprocess.run(
            ["xcrun", "swift-symbolgraph-extract", "-module-name", module,
             "-target", "arm64-apple-ios%s" % version, "-sdk", sdk,
             "-output-dir", APPLE_DIR, "-minimum-access-level", "public", "-skip-synthesized-members"],
            check=True, capture_output=True)
    mac_sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
    mac_version = run(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).strip()
    os.makedirs(APPLE_MAC_DIR, exist_ok=True)
    for module in modules:
        if glob.glob(os.path.join(APPLE_MAC_DIR, module + ".symbols.json")) \
                or glob.glob(os.path.join(APPLE_MAC_DIR, module + "@*.symbols.json")):
            continue
        subprocess.run(
            ["xcrun", "swift-symbolgraph-extract", "-module-name", module,
             "-target", "arm64-apple-macos%s" % mac_version, "-sdk", mac_sdk,
             "-output-dir", APPLE_MAC_DIR, "-minimum-access-level", "public", "-skip-synthesized-members"],
            capture_output=True)
    return sdk, version


def bazel_output_base():
    return run(["bazel", "info", "output_base"], cwd=ROOT).strip()


def isomer_graphs():
    """Builds Isomer's wasm modules with the compiler writing their graphs."""
    if os.path.isdir(ISOMER_DIR):
        shutil.rmtree(ISOMER_DIR)
    os.makedirs(ISOMER_DIR)
    # Isomer's graphs keep synthesized members (a protocol's default counts
    # as implemented); Apple's skip them (only what Apple declares counts).
    # The graphs are written beside Bazel's outputs, not as outputs: a run
    # compiles afresh (a define of its own keeps the cache from answering).
    copts = ["-emit-symbol-graph", "-emit-symbol-graph-dir", ISOMER_DIR,
             "-symbol-graph-minimum-access-level", "public",
             # `@_spi` declarations are public-facing too (a host imports
             # them): what an Apple-named module has behind SPI counts.
             "-include-spi-symbols",
             "-DISOMER_PARITY_%d" % int(datetime.datetime.now().timestamp())]
    subprocess.run(
        # Foundation as an app that opts into FoundationInternationalization
        # has it (what the report counts says so).
        ["bazel", "build", "--platforms=//tools/platforms:wasm32", "--//foundation:internationalization"]
        + ["--@rules_swift//swift:copt=%s" % c for c in copts]
        + ["//wasm/libraries/swift_ui:swift_ui", "//foundation:foundation", "//metal/metal:metal",
           "//frameworks/core_transferable", "//frameworks/uniform_type_identifiers",
           "//wasm/libraries/swift_ui:photos_ui",
           # The Isomer umbrella and the Isomer* modules beneath it: what
           # Isomer adds beside Apple's (superset.md lists it).
           "//wasm/libraries/swift_ui:isomer"],
        cwd=ROOT, check=True)
    # Android's and the CLI's builds of the same modules, each into a
    # directory of its own (the modules have the same names).
    for directory, flags, targets in (
            (ISOMER_ANDROID_DIR, ["--platforms=//tools/platforms:android_arm64", "--//foundation:internationalization"],
             ["//android/libraries/swift_ui:swift_ui", "//android/libraries/swift_ui:photos_ui",
              "//foundation:foundation"]),
            (ISOMER_CLI_DIR, [], ["//cli/libraries/swift_ui:swift_ui"])):
        if os.path.isdir(directory):
            shutil.rmtree(directory)
        os.makedirs(directory)
        subprocess.run(
            ["bazel", "build"] + flags
            + ["--@rules_swift//swift:copt=%s" % c.replace(ISOMER_DIR, directory) for c in copts] + targets,
            cwd=ROOT, check=True)
    # Observation and Synchronization: the wasm SDK's own modules.
    base = bazel_output_base()
    bundle = glob.glob(os.path.join(
        base, "external", "rules_swift++swift+swift_toolchain_wasm_sdk_*", "*.artifactbundle", "*",
        "wasm32-unknown-wasip1"))[0]
    extractor = glob.glob(os.path.join(
        base, "external", "rules_swift++swift+swift_toolchain_*", "usr", "bin", "swift-symbolgraph-extract"))[0]
    for module in ("Observation", "Synchronization"):
        subprocess.run(
            [extractor, "-module-name", module, "-target", "wasm32-unknown-wasip1",
             "-sdk", os.path.join(bundle, "WASI.sdk"),
             "-resource-dir", os.path.join(bundle, "swift.xctoolchain", "usr", "lib", "swift_static"),
             "-output-dir", ISOMER_DIR, "-minimum-access-level", "public"],
            check=True, capture_output=True)


_DEMANGLED = {}


def owners(precise_ids):
    """The module each mangled name belongs to (the extension's module for
    an extension member), demangled once (the mangled form can abbreviate a
    module's name)."""
    wanted = [p for p in precise_ids if p.startswith("s:") and p not in _DEMANGLED]
    if wanted:
        out = subprocess.run(["xcrun", "swift-demangle", "--compact"], input="\n".join("$s" + p[2:] for p in wanted),
                             capture_output=True, text=True).stdout.split("\n")
        for precise, text in zip(wanted, out):
            found = re.search(r"\(extension in ([A-Za-z_][A-Za-z0-9_]*)\)", text)
            _DEMANGLED[precise] = found.group(1) if found else re.match(r"[^A-Za-z_]*([A-Za-z_][A-Za-z0-9_]*)", text).group(1) if text else ""
    return _DEMANGLED


def load(directory, module, path_filter=None, own_only=False):
    """The module's symbols (its own file and its extensions of others).
    `own_only` keeps only what the module declares itself: a graph the
    compiler writes includes what the module re-exports."""
    mangled = "%d%s" % (len(module), module)
    symbols = []
    for path in sorted(glob.glob(os.path.join(directory, module + ".symbols.json"))
                       + glob.glob(os.path.join(directory, module + "@*.symbols.json"))):
        data = json.load(open(path))
        candidates = [s for s in data.get("symbols", [])
                      if not path_filter or re.search(path_filter, s["pathComponents"][0])]
        if own_only:
            unsure = [s["identifier"]["precise"] for s in candidates if mangled not in s["identifier"]["precise"]]
            known = owners(unsure)
            candidates = [s for s in candidates if mangled in s["identifier"]["precise"]
                          or known.get(s["identifier"]["precise"]) == module]
        symbols.extend(candidates)
    return symbols


# MARK: - Conformances

# A conformance is interface too: code that compares, hashes or uses as a
# view what Isomer's type allows and Apple's does not builds with Isomer only.
# Left out: the marker protocols, whose graphs differ by tool (Apple's are
# extracted from the SDK, Isomer's written by the compiler; an Objective-C
# class's Sendable is in its header) and which add no members.
MARKER_PROTOCOLS = {"Sendable", "SendableMetatype", "BitwiseCopyable", "Copyable", "Escapable"}

# What the standard library's protocols bring along, which neither graph
# spells out (a Hashable type is Equatable).
IMPLIED_PROTOCOLS = {
    "Hashable": ["Equatable"], "Comparable": ["Equatable"], "Strideable": ["Comparable"],
    "Codable": ["Encodable", "Decodable"], "SetAlgebra": ["Equatable", "ExpressibleByArrayLiteral"],
    "OptionSet": ["SetAlgebra", "RawRepresentable"], "Collection": ["Sequence"],
    "BidirectionalCollection": ["Collection"], "RandomAccessCollection": ["BidirectionalCollection"],
    "MutableCollection": ["Collection"], "RangeReplaceableCollection": ["Collection"],
    "Error": ["Sendable"], "AdditiveArithmetic": ["Equatable"],
    "Numeric": ["AdditiveArithmetic", "ExpressibleByIntegerLiteral"], "SignedNumeric": ["Numeric"],
    "FloatingPoint": ["SignedNumeric", "Strideable", "Hashable"],
    "BinaryFloatingPoint": ["FloatingPoint", "ExpressibleByFloatLiteral"],
    "BinaryInteger": ["Hashable", "Numeric", "CustomStringConvertible", "Strideable"],
    "FixedWidthInteger": ["BinaryInteger", "LosslessStringConvertible"],
    "SignedInteger": ["BinaryInteger", "SignedNumeric"], "UnsignedInteger": ["BinaryInteger"],
    "LosslessStringConvertible": ["CustomStringConvertible"],
    "ExpressibleByStringInterpolation": ["ExpressibleByStringLiteral"],
    "ExpressibleByStringLiteral": ["ExpressibleByExtendedGraphemeClusterLiteral"],
    "ExpressibleByExtendedGraphemeClusterLiteral": ["ExpressibleByUnicodeScalarLiteral"],
}


def conformance_graph(directories, modules):
    """Each type's stated conformances (by path) and each protocol's
    parents, from the graphs of `modules` ((name, path filter) pairs)."""
    symbols, relationships = {}, []
    for directory in directories:
        for module, path_filter in modules:
            for path in (glob.glob(os.path.join(directory, module + ".symbols.json"))
                         + glob.glob(os.path.join(directory, module + "@*.symbols.json"))):
                data = json.load(open(path))
                for symbol in data.get("symbols", []):
                    if not path_filter or re.search(path_filter, symbol["pathComponents"][0]):
                        symbols.setdefault(symbol["identifier"]["precise"], symbol)
                relationships.extend(data.get("relationships", []))

    def name(precise, fallback=None):
        if precise in symbols:
            return ".".join(symbols[precise]["pathComponents"])
        return (fallback or precise).split(".")[-1]

    conformances, parents = collections.defaultdict(set), collections.defaultdict(set)
    for r in relationships:
        if r["kind"] not in ("conformsTo", "inheritsFrom") or r["source"] not in symbols:
            continue
        source = symbols[r["source"]]
        target = name(r["target"], r.get("targetFallback"))
        if source["kind"]["identifier"] == "swift.protocol":
            parents[".".join(source["pathComponents"])].add(target)
        elif r["kind"] == "conformsTo":
            conformances[".".join(source["pathComponents"])].add(target)
    return conformances, parents


def implied(protocols, parents):
    """`protocols` with everything they bring along."""
    seen, queue = set(), list(protocols)
    while queue:
        protocol = queue.pop()
        if protocol not in seen:
            seen.add(protocol)
            queue.extend(IMPLIED_PROTOCOLS.get(protocol, ()))
            queue.extend(parents.get(protocol, ()))
    return seen


def conformance_differences(spec, isomer_dirs=(ISOMER_DIR,)):
    """For the types both have: the conformances Isomer's type has that
    Apple's lacks (`extra`, marker protocols aside: --check fails on one)
    and the reverse (`missing`), then the same for Sendable, which the
    graphs record for both (Apple's `~Sendable` and a header's
    NS_SWIFT_SENDABLE included): `sendable_extra` (Isomer's type is,
    Apple's is not) and `sendable_missing`. Lists of (type, protocol) or
    types. A type Apple lacks is the declarations' business, not this."""
    apple, apple_parents = conformance_graph((APPLE_DIR, APPLE_MAC_DIR), spec["apple"])
    isomer, isomer_parents = conformance_graph(isomer_dirs, [(module, None) for module in spec["isomer"]])
    result = {"extra": [], "missing": [], "sendable_extra": [], "sendable_missing": []}
    for path in sorted(set(isomer) & set(apple)):
        ours, theirs = implied(isomer[path], isomer_parents), implied(apple[path], apple_parents)
        result["extra"] += [(path, p) for p in sorted(isomer[path] - theirs) if p not in MARKER_PROTOCOLS]
        result["missing"] += [(path, p) for p in sorted(apple[path] - ours) if p not in MARKER_PROTOCOLS]
        if "Sendable" in ours and "Sendable" not in theirs:
            result["sendable_extra"].append(path)
        if "Sendable" in theirs and "Sendable" not in ours:
            result["sendable_missing"].append(path)
    return result


def extra_conformances(spec, isomer_dirs=(ISOMER_DIR,)):
    """(type, protocol) for each conformance Isomer's type has that Apple's
    same type does not, stated or implied (marker protocols aside)."""
    return conformance_differences(spec, isomer_dirs)["extra"]


# MARK: - Comparing

KIND_GROUPS = {
    "swift.struct": "type", "swift.class": "type", "swift.enum": "type", "swift.protocol": "type",
    "swift.typealias": "type", "swift.actor": "type",
    "swift.associatedtype": "associatedtype",
    "swift.init": "init",
    # An instance member and a static one of the same name are different
    # API (`Color.red` the colour, `color.red` a component).
    "swift.method": "method", "swift.type.method": "type.method",
    "swift.property": "property", "swift.type.property": "type.property",
    "swift.subscript": "subscript", "swift.type.subscript": "type.subscript",
    "swift.enum.case": "case",
    "swift.func": "func", "swift.func.op": "operator", "swift.var": "var", "swift.macro": "macro",
}

QUALIFIER = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*(?:::|\.)(?=[A-Z_])")


def spelled(fragments):
    return QUALIFIER.sub("", "".join(f.get("spelling", "") for f in fragments)).strip()


def parameter_types(symbol):
    signature = symbol.get("functionSignature")
    if not signature:
        return ()
    types = []
    for parameter in signature.get("parameters", []):
        fragments = parameter.get("declarationFragments", [])
        # The parameter's type names alone: how a declaration spells `any`,
        # `inout` or a module qualifier does not make it another overload.
        types.append(spelled([f for f in fragments if f.get("kind") in ("typeIdentifier", "genericParameter")]))
    return tuple(t.replace(" ", "") for t in types)


def signature(symbol):
    """A declaration's types as code sees them: each parameter's and the
    result's (a property's or subscript's own type), its generic
    parameters named by what they must conform to, so `<S: StringProtocol>`
    and `<T: StringProtocol>` are one signature and `(String)` another.
    Read from each type's text: qualifiers (`Text.Scale`, `T.Value`),
    attributes, `any`, `some`, `inout` and the like do not make another
    signature."""
    generics = {}
    swift_generics = symbol.get("swiftGenerics") or {}
    for parameter in swift_generics.get("parameters", []):
        generics[parameter["name"]] = []
    same = {}
    extension_constraints = [c for c in (symbol.get("swiftExtension") or {}).get("constraints", [])
                             if c.get("kind") == "sameType" and c.get("lhs") == "Self"]
    for constraint in swift_generics.get("constraints", []) + extension_constraints:
        if constraint.get("kind") in ("conformance", "superclass") and constraint.get("lhs") in generics:
            generics[constraint["lhs"]].append(QUALIFIER.sub("", constraint.get("rhs", "")))
        elif constraint.get("kind") == "sameType" and constraint.get("lhs") == "Self":
            # `extension Shape where Self == RoundedRectangle`: its Self is that type.
            same["Self"] = QUALIFIER.sub("", constraint.get("rhs", ""))

    def typed(text, result=False):
        text = text.replace("`", "")
        for name, value in same.items():
            text = re.sub(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % re.escape(name), value, text)
        # Apple's top-level typealiases as what they name (its graphs spell
        # MTLNewLibraryCompletionHandler out as the closure type).
        for _ in range(2):
            text = re.sub(r"(?<![A-Za-z0-9_.])([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_])",
                          lambda m: TYPEALIASES.get(m.group(1), m.group(1)), text)
        text = re.sub(r"@[A-Za-z_]+(?:\([^)]*\))?", "", text)
        # A `some P` parameter is a generic one (`<P>`); a `some P` result is P.
        text = re.sub(r"\bsome\s+([A-Za-z_][A-Za-z0-9_.]*)", r"\1" if result else r"<\1>", text)
        text = re.sub(r"\b(?:any|inout|borrowing|consuming|sending|__owned|__shared|isolated)\s+", "", text)
        text = re.sub(r"\{[^}]*\}", "", text)
        previous = None
        while previous != text:
            previous = text
            text = re.sub(r"(?<![A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*(?:<[^<>]*(?:<[^<>]*>[^<>]*)*>)?\.(?=[A-Za-z_])", "", text)
        for name, constraints in generics.items():
            text = re.sub(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % re.escape(name),
                          "<%s>" % "&".join(sorted(constraints)), text)
        text = re.sub(r"\bCGFloat\b", "Double", text).replace(" ", "")
        # The standard library's C type names are the Swift types they alias.
        for c, swift in C_TYPES.items():
            text = re.sub(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % c, swift, text)
        text = text.replace("->()", "->Void")
        # A closure type's parameter labels (`(_ oldValue: V, _ newValue: V)`).
        text = re.sub(r"(?<=[(,])_?[a-z][A-Za-z0-9_]*:", "", text)
        text = text.replace("repeateach", "")
        previous = None
        while previous != text:
            previous = text
            text = re.sub(r"\(([A-Za-z0-9_<>&\[\]:]+)\)(?=[?!]|[,)]|$|->)", r"\1", text)
        if result and text in ("", "()"):
            return "Void"
        return text

    def after_colon(fragments):
        text = "".join(f.get("spelling", "") for f in fragments)
        return text.split(":", 1)[1] if ":" in text else text

    function = symbol.get("functionSignature")
    if not function and KIND_GROUPS.get(symbol["kind"]["identifier"]) in ("init", "method", "type.method", "func"):
        function = {"parameters": [], "returns": []}
    if function:
        parameters = tuple(typed(after_colon(p.get("declarationFragments", []))) for p in function.get("parameters", []))
        return parameters, typed("".join(f.get("spelling", "") for f in function.get("returns", [])), result=True)
    fragments = symbol.get("declarationFragments", [])
    names = [i for i, f in enumerate(fragments) if f.get("kind") == "identifier"]
    return None, typed(after_colon(fragments[names[0] + 1:] if names else fragments), result=True)


def signed_alike(ours, allowed):
    """Whether `ours` is one of Apple's signatures `allowed`, an associated
    type's name in Apple's standing for any type."""
    if ours in allowed:
        return True
    # An unconstrained generic of ours: any type of Apple's there.
    if "<>" in "".join((ours[0] or ()) + (ours[1],)):
        loose = re.compile("^" + re.escape("\x01".join((ours[0] or ()) + (ours[1],))).replace("<>", "<[^<>]*>") + "$")
        for parameters, result in allowed:
            if (parameters is None) == (ours[0] is None) and (parameters is None or len(parameters) == len(ours[0])):
                if loose.match("\x01".join((parameters or ()) + (result,))):
                    return True
    names = [n for n in ASSOCIATED_TYPES if n]
    if not names:
        return False
    wildcard = re.compile(r"(?<![A-Za-z0-9_])(?:%s)(?![A-Za-z0-9_])" % "|".join(map(re.escape, sorted(names, key=len, reverse=True))))

    # An unconstrained generic of Apple's: a generic of ours, or a type's
    # associated type (`Data.Element`, which ours may spell where Apple's
    # graph has a type parameter).
    generic_or_associated = r"(?:<[^<>]*>|%s)" % "|".join(map(re.escape, sorted(names, key=len, reverse=True)))

    def pattern(text):
        text = text.replace("<>", "\x00")
        parts, last = [], 0
        for m in wildcard.finditer(text):
            parts.append(re.escape(text[last:m.start()]))
            parts.append(r"[^,]+?")
            last = m.end()
        parts.append(re.escape(text[last:]))
        # An unconstrained generic of Apple's (or one whose constraints its
        # graph leaves out): any generic of ours.
        return re.compile("^" + "".join(parts).replace("\x00", generic_or_associated) + "$")

    for parameters, result in allowed:
        if (parameters is None) != (ours[0] is None):
            continue
        if parameters is not None and len(parameters) != len(ours[0]):
            continue
        if not pattern(result).match(ours[1]):
            continue
        if parameters is None or all(pattern(a).match(o) for a, o in zip(parameters, ours[0])):
            return True
    return False


def self_as(symbol, generic=True):
    """`signature` with Self written as the enclosing type (`static let
    wide: Self` in an enum is Apple's `wide: UnitsStyle`)."""
    parameters, result = signature(symbol)
    if len(symbol["pathComponents"]) < 2:
        return parameters, result
    name = symbol["pathComponents"][-2]
    # A generic type's Self has its parameters (`Predicate<Input>`).
    args = TYPE_PARAMETERS.get(tuple(symbol["pathComponents"][:-1])) if generic else None
    if args:
        name = "%s<%s>" % (name, ",".join(args))
    swap = lambda text: re.sub(r"(?<![A-Za-z0-9_])Self(?![A-Za-z0-9_])", name, text)
    return (None if parameters is None else tuple(swap(t) for t in parameters)), swap(result)


def as_self(symbol):
    """`signature` with the enclosing type written as Self, as a protocol's
    requirement (Equatable's `==`) has it."""
    parameters, result = signature(symbol)
    if len(symbol["pathComponents"]) < 2:
        return parameters, result
    name = re.escape(symbol["pathComponents"][-2])
    swap = lambda text: re.sub(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % name, "Self", text)
    return (None if parameters is None else tuple(swap(t) for t in parameters)), swap(result)


COMPILER_PROVIDED = {"hashValue", "rawValue", "RawValue", "init(rawValue:)", "allCases", "AllCases"}


def private(symbol):
    return any(part.startswith("_") for part in symbol["pathComponents"])


def unavailable_or_deprecated(symbol):
    for entry in symbol.get("availability", []) or []:
        domain = entry.get("domain", "*")
        if domain not in ("*", "iOS", "Swift"):
            continue
        if entry.get("isUnconditionallyUnavailable") or entry.get("obsoleted"):
            return "unavailable"
        if entry.get("isUnconditionallyDeprecated") or entry.get("deprecated"):
            return "deprecated"
    return None


def key(symbol):
    group = KIND_GROUPS.get(symbol["kind"]["identifier"], symbol["kind"]["identifier"])
    path = tuple(symbol["pathComponents"])
    return (path, group)


def display(symbol):
    return ".".join(symbol["pathComponents"])


def stubbed(symbol):
    """Declared unavailable by Isomer to name a gap (tools/parity/stubs.py's
    "Not yet in Isomer"), not implemented."""
    for entry in symbol.get("availability", []) or []:
        if entry.get("isUnconditionallyUnavailable") and "Not yet in Isomer" in (entry.get("message") or ""):
            return True
    return False


def apple_reach():
    """Every (path, kind group) Apple's interface lets code write, beyond
    what its graphs list for a type itself: what a class inherits (an
    imported class's `init()`, `description`, `==` from NSObject), what a
    conformance brings (`rawValue` of an imported option set, `lock()` of
    NSLocking, the standard protocols' members), and what a typealias
    reaches (`Data.Base64EncodingOptions` is `NSData.Base64EncodingOptions`).
    A static property and an enum case are interchangeable in use."""
    symbols, relationships = {}, []
    for directory in (APPLE_DIR, APPLE_MAC_DIR):
        for path in glob.glob(os.path.join(directory, "*.symbols.json")):
            data = json.load(open(path))
            module = os.path.basename(path).split("@")[0].split(".")[0]
            for symbol in data.get("symbols", []):
                symbols.setdefault(symbol["identifier"]["precise"], symbol)
                symbol.setdefault("_module", module)
            relationships.extend(data.get("relationships", []))
    for symbol in symbols.values():
        kind = symbol["kind"]["identifier"]
        if kind == "swift.associatedtype":
            ASSOCIATED_TYPES.add(symbol["pathComponents"][-1])
        elif kind == "swift.typealias" and len(symbol["pathComponents"]) == 1 \
                and symbol.get("_module") in TYPEALIAS_MODULES \
                and not (symbol.get("swiftGenerics") or {}).get("parameters"):
            text = "".join(f.get("spelling", "") for f in symbol.get("declarationFragments", []))
            if "=" in text:
                TYPEALIASES[symbol["pathComponents"][0]] = text.split("=", 1)[1].strip()
    members, parents = collections.defaultdict(list), collections.defaultdict(set)
    for r in relationships:
        if r["kind"] in ("memberOf", "requirementOf", "optionalRequirementOf"):
            members[r["target"]].append(r["source"])
        elif r["kind"] in ("inheritsFrom", "conformsTo"):
            parents[r["source"]].add(r["target"])

    def reachable_members(precise):
        seen, queue, found = set(), [precise], []
        while queue:
            current = queue.pop()
            if current in seen:
                continue
            seen.add(current)
            found.extend(members.get(current, ()))
            queue.extend(parents.get(current, ()))
        return found

    types = {p: s for p, s in symbols.items() if KIND_GROUPS.get(s["kind"]["identifier"]) == "type"}
    by_path = collections.defaultdict(list)
    for symbol in symbols.values():
        by_path[tuple(symbol["pathComponents"])].append(symbol)
    keys = set()

    def add(path, symbol):
        group = KIND_GROUPS.get(symbol["kind"]["identifier"], symbol["kind"]["identifier"])
        # An associated type is satisfied by a typealias.
        group = "type" if group == "associatedtype" else group
        parameters, result = signature(symbol)
        for name, dropped in call_forms_dropping(path[-1], symbol):
            keys.add((path[:-1] + (name,), group))
            kept = None if parameters is None else tuple(t for i, t in enumerate(parameters) if i not in dropped)
            APPLE_SIGNATURES[(path[:-1] + (name,), group)].add((kept, result))
            # A case written as a static property (`.red`): its type is
            # the enum's, which a case's graph does not spell.
            if group == "case":
                APPLE_SIGNATURES[(path[:-1] + (name,), "type.property")].add(ANY_SIGNATURE)
            # An enum case and a static property are used alike (`.red`).
            if group in ("case", "type.property"):
                keys.add((path[:-1] + (name,), "type.property" if group == "case" else "case"))

    def reach(root, precise):
        """What code reaches through the type `precise` written as `root`."""
        target = tuple(types[precise]["pathComponents"])
        for path, found in by_path.items():
            if path[:len(target)] == target and len(path) > len(target):
                for symbol in found:
                    add(root + path[len(target):], symbol)
        for member in reachable_members(precise):
            symbol = symbols.get(member)
            if symbol:
                add(root + (symbol["pathComponents"][-1],), symbol)

    for symbol in symbols.values():
        add(tuple(symbol["pathComponents"]), symbol)
    for precise, symbol in types.items():
        reach(tuple(symbol["pathComponents"]), precise)
        if symbol["kind"]["identifier"] == "swift.typealias":
            targets = [f.get("preciseIdentifier") for f in symbol.get("declarationFragments", [])
                       if f.get("kind") == "typeIdentifier" and f.get("preciseIdentifier") in types]
            if targets:
                reach(tuple(symbol["pathComponents"]), targets[-1])
    return keys


_APPLE_REACH = None
# Apple's top-level, non-generic typealiases (name -> what it names, as
# `signature` reads types) and its associated types' names, which a
# requirement reached through a protocol spells where a conformer has its
# own type (OptionSet's `rawValue: RawValue` is a mask's `UInt`).
TYPEALIASES = {
    # Darwin's, which the graphs here do not include.
    "uuid_t": "(UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)",
}
ASSOCIATED_TYPES = set()
# Whose top-level typealiases are expanded: the frameworks compared (not
# Objective-C's `Category`, an OpaquePointer, or Darwin's).
TYPEALIAS_MODULES = {"SwiftUI", "SwiftUICore", "Foundation", "CoreGraphics", "CoreFoundation", "Metal",
                     "CoreTransferable", "UniformTypeIdentifiers", "PhotosUI", "Observation", "Synchronization"}
# Each Apple key's signatures (`signature`), filled by apple_reach.
APPLE_SIGNATURES = collections.defaultdict(set)
ANY_SIGNATURE = ("*", "*")
C_TYPES = {"CChar": "Int8", "CSignedChar": "Int8", "CUnsignedChar": "UInt8", "CShort": "Int16",
           "CUnsignedShort": "UInt16", "CInt": "Int32", "CUnsignedInt": "UInt32", "CLong": "Int",
           "CUnsignedLong": "UInt", "CLongLong": "Int64", "CUnsignedLongLong": "UInt64",
           "CFloat": "Float", "CDouble": "Double", "CBool": "Bool"}
# Isomer's generic types' parameter names, by path (filled by compare).
TYPE_PARAMETERS = {}
SIGNED_GROUPS = {"init", "method", "type.method", "func", "operator", "subscript", "type.subscript",
                 "property", "type.property", "var"}


def call_forms(name, symbol):
    """`name` and the names a call has when it leaves out defaulted
    parameters: Apple's `makeBuffer(length:options:)` has `options = []`,
    so `makeBuffer(length:)` is Apple's too (Isomer declares it apart where
    a protocol requirement cannot have a default)."""
    return [form for form, _ in call_forms_dropping(name, symbol)]


def call_forms_dropping(name, symbol):
    """`call_forms`, each with the indices of the parameters it leaves out."""
    match = re.match(r"^(.*)\((.*)\)$", name)
    signature = symbol.get("functionSignature")
    if not match or not signature or not match.group(2):
        return [(name, frozenset())]
    labels = match.group(2).split(":")[:-1]
    parameters = signature.get("parameters", [])
    if len(parameters) != len(labels):
        return [(name, frozenset())]
    text = "".join(f.get("spelling", "") for f in symbol.get("declarationFragments", []))
    defaulted = []
    for index, parameter in enumerate(parameters):
        internal = parameter.get("internalName") or parameter.get("name")
        if internal and re.search(r"\b%s: [^,]*? = " % re.escape(internal), text):
            defaulted.append(index)
    if not defaulted or len(defaulted) > 6:
        return [(name, frozenset())]
    forms = []
    for mask in range(1 << len(defaulted)):
        dropped = frozenset(defaulted[i] for i in range(len(defaulted)) if mask >> i & 1)
        kept = [label for i, label in enumerate(labels) if i not in dropped]
        forms.append(("%s(%s)" % (match.group(1), "".join(label + ":" for label in kept)), dropped))
    return forms


def compare(apple, isomer, apple_elsewhere=()):
    by_key = collections.defaultdict(list)
    for symbol in isomer:
        if stubbed(symbol):
            continue
        by_key[key(symbol)].append(symbol)
    isomer_types = {tuple(s["pathComponents"]) for s in isomer if KIND_GROUPS.get(s["kind"]["identifier"]) == "type"}
    implemented, missing, partial, set_aside = [], [], [], collections.Counter()
    seen = set()
    for symbol in apple:
        if private(symbol):
            set_aside["private (underscored)"] += 1
            continue
        state = unavailable_or_deprecated(symbol)
        if state:
            set_aside[state + " on iOS"] += 1
            continue
        k = key(symbol)
        dedup = (k, parameter_types(symbol))
        if dedup in seen:
            continue
        seen.add(dedup)
        candidates = by_key.get(k, [])
        if not candidates and symbol["pathComponents"][-1] in COMPILER_PROVIDED \
                and tuple(symbol["pathComponents"][:-1]) in isomer_types:
            # What the compiler gives a Hashable type or a raw-value enum,
            # which symbol graphs leave out: there when the type is.
            implemented.append(symbol)
            continue
        if not candidates:
            missing.append(symbol)
        elif parameter_types(symbol) in {parameter_types(c) for c in candidates}:
            implemented.append(symbol)
        else:
            # The name is there, with other parameter types: counted as
            # implemented, listed for review.
            implemented.append(symbol)
            partial.append(symbol)
    global _APPLE_REACH
    if _APPLE_REACH is None:
        _APPLE_REACH = apple_reach()
    apple_keys = {key(s) for s in apple} | {key(s) for s in apple_elsewhere} | _APPLE_REACH
    additions = [s for s in isomer if key(s) not in apple_keys and not private(s) and not stubbed(s)
                 and "::SYNTHESIZED::" not in s["identifier"]["precise"]]
    # A type of another kind than Apple's (a struct where Apple has a
    # protocol) is Isomer's own too: code using it as Isomer has it need
    # not compile against Apple's.
    type_kinds = {"swift.struct", "swift.class", "swift.enum", "swift.protocol", "swift.typealias"}
    apple_type_kinds = collections.defaultdict(set)
    for symbol in list(apple) + list(apple_elsewhere):
        if symbol["kind"]["identifier"] in type_kinds:
            apple_type_kinds[tuple(symbol["pathComponents"])].add(symbol["kind"]["identifier"])
    for symbol in isomer:
        kinds = apple_type_kinds.get(tuple(symbol["pathComponents"]))
        # Where Apple has a typealias, the type it names may be of any kind.
        if kinds and "swift.typealias" in kinds:
            continue
        if kinds and symbol["kind"]["identifier"] in type_kinds and symbol["kind"]["identifier"] not in kinds \
                and not private(symbol) and symbol not in additions:
            additions.append(symbol)
    # Declarations Apple has by name and kind, but not with these types:
    # the strict subset is of the .swiftinterface (2026-10-12), so
    # `init(_ title: String)` where Apple has `init<S: StringProtocol>(_:)`
    # is Isomer's own too.
    own_ids = {id(s) for s in additions}
    for symbol in isomer:
        if KIND_GROUPS.get(symbol["kind"]["identifier"]) == "type":
            names = [p["name"] for p in (symbol.get("swiftGenerics") or {}).get("parameters", []) if p.get("depth", 0) == 0]
            if names:
                TYPE_PARAMETERS[tuple(symbol["pathComponents"])] = names
    retyped = []
    for symbol in isomer:
        group = KIND_GROUPS.get(symbol["kind"]["identifier"])
        if group not in SIGNED_GROUPS or id(symbol) in own_ids or private(symbol) or stubbed(symbol) \
                or "::SYNTHESIZED::" in symbol["identifier"]["precise"]:
            continue
        allowed = APPLE_SIGNATURES.get(key(symbol))
        if not allowed or ANY_SIGNATURE in allowed:
            continue
        forms = (signature(symbol), as_self(symbol), self_as(symbol), self_as(symbol, generic=False))
        if not any(signed_alike(form, allowed) for form in forms):
            retyped.append(symbol)
    return implemented, missing, set_aside, additions, partial, retyped


# Where an addition comes from: swift-foundation as upstream has it (Isomer
# builds the fork's sources; a file of Isomer's there has "Isomer" in its
# name), or Isomer.
def from_upstream(symbol, isomer_by_path):
    location = (symbol.get("location") or {}).get("uri", "")
    if not location:
        parent = isomer_by_path.get(tuple(symbol["pathComponents"][:-1]))
        location = (parent.get("location") or {}).get("uri", "") if parent else ""
    return "/swift-foundation+/" in location and "Isomer" not in os.path.basename(location)


_MODIFIERS = r"(?:(?:final|static|class|override|mutating|nonisolated(?:\(unsafe\))?|indirect|required|convenience)\s+)*"
DECLARATION = re.compile(
    r"^\s*(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*" + _MODIFIERS + r"(?:public|open)\s+" + _MODIFIERS
    + r"(?:struct|class|enum|protocol|actor|func|var|let|typealias|associatedtype)\s+(_[A-Za-z0-9_]*)")


def apple_interface_text():
    sdk = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).strip()
    files = glob.glob(os.path.join(sdk, "System/Library/Frameworks/*/Modules/*.swiftmodule/arm64e-apple-ios.swiftinterface")) \
        + glob.glob(os.path.join(sdk, "usr/lib/swift/*.swiftmodule/arm64e-apple-ios.swiftinterface"))
    return "\n".join(open(f, errors="ignore").read() for f in files)


def underscored_additions(spec, apple_text):
    """Public declarations with an underscored name that no Apple
    interface has: symbol graphs leave underscored names out (both sides),
    so they are read from the sources. A name Apple's interfaces use
    (`_ConditionalContent`) is Apple's."""
    found = {}
    for directory in spec.get("sources", []):
        for path in glob.glob(os.path.join(ROOT, directory, "**", "*.swift"), recursive=True):
            if "/tests/" in path:
                continue
            for number, line in enumerate(open(path, errors="ignore"), 1):
                match = DECLARATION.match(line)
                if match and not re.search(r"\b%s\b" % re.escape(match.group(1)), apple_text):
                    found.setdefault(match.group(1), "%s:%d" % (os.path.relpath(path, ROOT), number))
    return found


# MARK: - Writing

def introduced_ios(symbol):
    for entry in symbol.get("availability", []) or []:
        if entry.get("domain") == "iOS" and entry.get("introduced"):
            return entry["introduced"].get("major", 0)
    return 0


def classify(missing, reasons):
    groups = []
    newer = reasons.get("newer")
    newer_group = None
    if newer:
        newer_group = (dict(newer, status=newer.get("status", "not yet")), [], [])
    for group in reasons.get("groups", []):
        patterns = [re.compile(p) for p in group["match"]]
        groups.append((group, patterns, []))
    unclassified = []
    for symbol in missing:
        name = display(symbol)
        if newer_group and introduced_ios(symbol) >= newer["ios"]:
            newer_group[2].append(symbol)
            continue
        for group, patterns, members in groups:
            if any(p.search(name) for p in patterns):
                members.append(symbol)
                break
        else:
            unclassified.append(symbol)
    if newer_group:
        groups.append(newer_group)
    return groups, unclassified


def examples(symbols, limit=12):
    names = []
    for symbol in symbols:
        name = "`%s`" % display(symbol)
        if name not in names:
            names.append(name)
        if len(names) == limit:
            break
    more = len({display(s) for s in symbols}) - len(names)
    return ", ".join(names) + (", and %d more" % more if more > 0 else "")


def write_report(spec, sdk_version, implemented, missing, set_aside, additions, partial, reasons, commit):
    groups, unclassified = classify(missing, reasons)
    counted = len(implemented) + len(missing)
    excluded = sum(len(m) for g, _, m in groups if g["status"] == "excluded")
    planned = sum(len(m) for g, _, m in groups if g["status"] == "not yet")
    percent = 100.0 * len(implemented) / counted if counted else 0
    lines = []
    lines.append("# %s" % spec["name"])
    lines.append("")
    lines.append(reasons.get("summary", "").strip())
    lines.append("")
    lines.append("Generated by `tools/parity/parity.py` on %s from Apple's iOS %s SDK and Isomer at `%s`: "
                 "%s." % (datetime.date.today().isoformat(), sdk_version, commit, spec["isomer_where"]))
    lines.append("")
    lines.append("| | Declarations |")
    lines.append("|---|---|")
    lines.append("| In Apple's interface (counted) | %d |" % counted)
    lines.append("| Implemented | %d (%.0f%%) |" % (len(implemented), percent))
    lines.append("| Missing, excluded | %d |" % excluded)
    lines.append("| Missing, not yet | %d |" % planned)
    lines.append("| Missing, not yet classified | %d |" % len(unclassified))
    stubs = spec.get("stubs", 0)
    if stubs:
        lines.append("| Of the missing, declared unavailable so the compiler says \"Not yet in Isomer\" | %d |" % stubs)
    for reason, count in sorted(set_aside.items()):
        lines.append("| Not counted: %s | %d |" % (reason, count))
    lines.append("")
    if reasons.get("deviations"):
        lines.append("## Implemented differently")
        lines.append("")
        for deviation in reasons["deviations"]:
            lines.append("- " + deviation)
        lines.append("")
    for status, title in (("excluded", "Excluded"), ("not yet", "Not yet")):
        chosen = [(g, m) for g, _, m in groups if g["status"] == status and m]
        if not chosen:
            continue
        lines.append("## " + title)
        lines.append("")
        for group, members in chosen:
            lines.append("### %s (%d)" % (group["title"], len(members)))
            lines.append("")
            lines.append("Why: " + group["why"])
            lines.append("")
            lines.append("Intent: " + group["intent"] + ".")
            lines.append("")
            lines.append(examples(members))
            lines.append("")
    if unclassified:
        lines.append("## Not yet classified (%d)" % len(unclassified))
        lines.append("")
        by_container = collections.defaultdict(list)
        for symbol in unclassified:
            by_container[symbol["pathComponents"][0]].append(symbol)
        for container in sorted(by_container):
            lines.append("- `%s`: %s" % (container, examples(by_container[container], 8)))
        lines.append("")
    retyped = spec.get("retyped", [])
    if retyped:
        lines.append("## Declared with other types than Apple's (%d)" % len(retyped))
        lines.append("")
        lines.append("Isomer's declarations whose name Apple has, but not with these parameter or result types "
                     "(generic parameters named by their constraints). Not in Apple's interface as written, "
                     "so not yet a strict subset of it:")
        lines.append("")
        for symbol in sorted(retyped, key=display):
            parameters, result = signature(symbol)
            shown = ("(%s)" % ", ".join(parameters) if parameters is not None else "") + (" -> " + result if result else "")
            lines.append("- `%s%s`" % (display(symbol), shown))
        lines.append("")
    if partial:
        lines.append("## Present with other parameter types (%d)" % len(partial))
        lines.append("")
        lines.append("Apple's overloads whose parameter types Isomer's declaration of the same name does not "
                     "have (counted as implemented; often a type spelled differently, sometimes an overload "
                     "missing):")
        lines.append("")
        for symbol in partial[:40]:
            lines.append("- `%s(%s)`" % (display(symbol), ", ".join(parameter_types(symbol))))
        if len(partial) > 40:
            lines.append("- and %d more" % (len(partial) - 40))
        lines.append("")
    own, upstream = additions, spec.get("upstream", [])
    underscored = spec.get("underscored", {})
    if (own or underscored) and not spec.get("toolchain"):
        lines.append("## Isomer's own public declarations (%d)" % (len(own) + len(underscored)))
        lines.append("")
        lines.append(reasons.get("additions", "Declarations the module has that Apple's does not."))
        lines.append("")
        lines.extend("- `%s`%s" % (display(symbol), " (SPI)" if symbol.get("spi") else "") for symbol in own)
        lines.extend("- `%s` (%s)" % (name, where) for name, where in sorted(underscored.items()))
        lines.append("")
    if upstream:
        lines.append("## swift-foundation's own public declarations (%d)" % len(upstream))
        lines.append("")
        lines.append("Declarations swift-foundation itself has that Apple's Foundation does not. Isomer's "
                     "fork makes them internal (or not built) so that its Foundation is a strict subset of "
                     "Apple's; these are not yet:")
        lines.append("")
        lines.append(", ".join("`%s`%s" % (display(symbol), " (SPI)" if symbol.get("spi") else "")
                               for symbol in upstream))
        lines.append("")
    conformances = spec.get("conformances", [])
    if conformances:
        lines.append("## Conformances Apple's types do not have (%d)" % len(conformances))
        lines.append("")
        lines.append("Protocols Isomer's type conforms to that Apple's same type does not (marker protocols "
                     "such as Sendable aside). Code relying on one builds with Isomer only:")
        lines.append("")
        lines.extend("- `%s`: `%s`" % (path, protocol) for path, protocol in conformances)
        lines.append("")
    path = os.path.join(OUT_DIR, spec["name"] + ".md")
    with open(path, "w") as f:
        f.write("\n".join(lines).rstrip() + "\n")
    return {"name": spec["name"], "counted": counted, "implemented": len(implemented), "percent": percent,
            "excluded": excluded, "planned": planned, "unclassified": len(unclassified)}


INTENT_ORDER = ("planned", "maybe", "not planned")

# Protocols Apple's Foundation types conform to as Objective-C classes or to
# bridge to them: listed apart in the missing lists, not planned.
OBJC_PROTOCOLS = {"NSObjectProtocol", "NSCopying", "NSMutableCopying", "NSCoding", "NSSecureCoding", "CVarArg",
                  "ReferenceConvertible", "ObjectiveCConvertibleAttributedStringKey", "NSFastEnumeration",
                  "NSItemProviderReading", "NSItemProviderWriting"}


def intent_rank(group):
    intent = group.get("intent", "")
    for rank, prefix in enumerate(INTENT_ORDER):
        if intent.startswith(prefix):
            return rank
    return len(INTENT_ORDER)


def write_missing(spec, sdk_version, missing, isomer, reasons, commit, partial=(), differences=None):
    """docs/parity/missing/<Module>.md: every declaration of Apple's interface
    the module lacks, with Apple's signature, by area and then by type: the
    list to choose what to implement next from."""
    groups, unclassified = classify(missing, reasons)
    isomer_types = {tuple(s["pathComponents"]) for s in isomer if KIND_GROUPS.get(s["kind"]["identifier"]) == "type"}
    chosen = [(g, m) for g, _, m in groups if m and g["status"] == "not yet"]
    # The catch-alls (the rest of the interface, this year's SDK) after the areas.
    catch_all = lambda group: "ios" in group or group.get("match") == ["."]
    chosen.sort(key=lambda item: (intent_rank(item[0]), catch_all(item[0]), -len(item[1])))
    excluded = [(g, m) for g, _, m in groups if m and g["status"] == "excluded"]
    if unclassified:
        chosen.append(({"title": "Not yet classified", "why": "No group in tools/parity/reasons claims these.",
                        "intent": "to be decided"}, unclassified))
    differences = differences or {}
    if not chosen and not excluded and not partial and not differences.get("missing") \
            and not differences.get("sendable_missing"):
        return False

    def declaration(symbol):
        text = spelled(symbol.get("declarationFragments", [])) or symbol["pathComponents"][-1]
        return re.sub(r"\s+", " ", text)

    def entry(symbol):
        path = symbol["pathComponents"]
        ios = introduced_ios(symbol)
        where = "in `%s`: " % ".".join(path[1:-1]) if len(path) > 2 else ""
        return "- %s`%s`%s" % (where, declaration(symbol), " (iOS %d)" % ios if ios else "")

    def by_type(members, level):
        lines = []
        containers = collections.defaultdict(list)
        for symbol in members:
            containers[symbol["pathComponents"][0]].append(symbol)
        for container in sorted(containers, key=lambda c: (-len(containers[c]), c)):
            symbols = sorted(containers[container], key=lambda s: (len(s["pathComponents"]), display(s)))
            lines.append("%s `%s` (%d%s)" % ("#" * level, container, len(symbols),
                                             "" if (container,) in isomer_types else ", the type too"))
            lines.append("")
            lines.extend(entry(s) for s in symbols)
            lines.append("")
        return lines

    name = spec["name"]
    total = sum(len(m) for _, m in chosen)
    lines = ["# %s: what Isomer does not have yet" % name, ""]
    lines.append("Every declaration of Apple's %s interface (iOS %s SDK) that Isomer's %s lacks, with Apple's "
                 "signature: the list to choose what to implement next from. [%s.md](../%s.md) has the counts, "
                 "the reasons and what is implemented differently. Generated by `tools/parity/parity.py` on %s "
                 "with Isomer at `%s`." % (name, sdk_version, name, name, name,
                                           datetime.date.today().isoformat(), commit))
    lines.append("")
    lines.append("Areas are ordered planned, then maybe, then the rest, larger first; within an area, types with "
                 "the most missing first. \"The type too\" marks a type Isomer does not declare at all; elsewhere "
                 "the type is there and these members are not. A version is the iOS release that introduced the "
                 "declaration.")
    lines.append("")
    if chosen:
        lines.append("| Area | Missing | Intent |")
        lines.append("|---|---|---|")
        for group, members in chosen:
            anchor = re.sub(r"[^a-z0-9 -]", "", group["title"].lower()).replace(" ", "-")
            lines.append("| [%s](#%s-%d) | %d | %s |" % (group["title"], anchor, len(members), len(members),
                                                       group["intent"]))
        lines.append("| Total | %d | |" % total)
        lines.append("")
        extras = [("conformances", len([c for c in differences.get("missing", []) if c[1] not in OBJC_PROTOCOLS])),
                  ("Sendable", len(differences.get("sendable_missing", []))),
                  ("overloads with other parameter types", len(partial))]
        extras = ["%s %d" % (name, count) for name, count in extras if count]
        if extras:
            lines.append("After the areas, what Isomer's types lack beyond declarations: %s." % ", ".join(extras))
            lines.append("")
        counts = collections.Counter(s["pathComponents"][0] for _, m in chosen for s in m)
        lines.append("Most missing by type (all areas):")
        lines.append("")
        lines.append(", ".join("`%s` %d%s" % (t, n, "" if (t,) in isomer_types else "*")
                               for t, n in counts.most_common(30)))
        lines.append("")
        lines.append("(* the type itself is missing.)")
        lines.append("")
        for group, members in chosen:
            lines.append("## %s (%d)" % (group["title"], len(members)))
            lines.append("")
            lines.append("Why: " + group["why"])
            lines.append("")
            lines.append("Intent: %s." % group["intent"])
            lines.append("")
            lines.extend(by_type(members, 3))
    lacking = differences.get("missing", [])
    objc = [(path, protocol) for path, protocol in lacking if protocol in OBJC_PROTOCOLS]
    lacking = [(path, protocol) for path, protocol in lacking if protocol not in OBJC_PROTOCOLS]
    for title, entries, note in (
            ("Conformances Isomer's types lack", lacking,
             "Types both have, conforming on Apple to protocols Isomer's do not (Sendable is below): code that "
             "compares, hashes, encodes, prints or uses one so builds with Apple's only."),
            ("Objective-C conformances (not planned)", objc,
             "What Apple's types conform to as Objective-C classes or for bridging to them (NSObjectProtocol, "
             "NSCopying, NSCoding, CVarArg, ReferenceConvertible…). Isomer's Foundation has no Objective-C "
             "classes (2026-10-12: no Objective-C APIs).")):
        if not entries:
            continue
        protocols_of = collections.defaultdict(list)
        for path, protocol in entries:
            protocols_of[path].append(protocol)
        lines.append("## %s (%d)" % (title, len(entries)))
        lines.append("")
        lines.append(note)
        lines.append("")
        lines.extend("- `%s`: %s" % (path, ", ".join("`%s`" % p for p in protocols))
                     for path, protocols in sorted(protocols_of.items()))
        lines.append("")
    not_sendable = differences.get("sendable_missing", [])
    if not_sendable:
        lines.append("## Sendable on Apple, not in Isomer (%d)" % len(not_sendable))
        lines.append("")
        lines.append("Code that passes one of these across actors, or keeps one in a Sendable type, builds "
                     "with Apple's only (Swift 6 language mode).")
        lines.append("")
        lines.append(", ".join("`%s`" % path for path in not_sendable))
        lines.append("")
    if partial:
        lines.append("## Overloads with other parameter types (%d)" % len(partial))
        lines.append("")
        lines.append("Apple's overloads of a name Isomer has, with parameter types Isomer's declarations of "
                     "it do not take (counted as implemented in the report): often an overload missing, "
                     "sometimes a type spelled differently.")
        lines.append("")
        lines.extend("- `%s(%s)`" % (display(symbol), ", ".join(parameter_types(symbol)))
                     for symbol in sorted(partial, key=display))
        lines.append("")
    if excluded:
        lines.append("## Excluded (%d)" % sum(len(m) for _, m in excluded))
        lines.append("")
        lines.append("Not planned, for the reasons [%s.md](../%s.md) gives; listed so the decision can be "
                     "revisited." % (name, name))
        lines.append("")
        for group, members in excluded:
            lines.append("### %s (%d)" % (group["title"], len(members)))
            lines.append("")
            lines.extend(by_type(members, 4))
    os.makedirs(os.path.join(OUT_DIR, "missing"), exist_ok=True)
    with open(os.path.join(OUT_DIR, "missing", name + ".md"), "w") as f:
        f.write("\n".join(lines).rstrip() + "\n")
    return True


# What the other builds' modules are compared as: Android's, as the wasm
# build's (the same sources, their own hosts and #if branches), and the
# CLI's SwiftUI (the core with the terminal host, on macOS).
OTHER_BUILDS = [
    ("Android", ISOMER_ANDROID_DIR, ["SwiftUI", "PhotosUI", "Foundation", "CoreGraphics", "ImageIO",
                                     "CoreTransferable", "UniformTypeIdentifiers"]),
    ("The CLI (macOS)", ISOMER_CLI_DIR, ["SwiftUI"]),
]

# Linux's and Windows' `SwiftUI` modules are the shared core with these host
# files, which cannot be compiled here (Linux builds in a container, Windows
# only on Windows): what they declare public is read from the source.
SOURCE_ONLY_HOSTS = [
    ("Linux", ["linux/libraries/swift_ui/LinuxHost.swift", "linux/libraries/swift_ui/LinuxWasmHost.swift"]),
    ("Windows", ["windows/libraries/swift_ui/WindowsHost.swift", "windows/libraries/swift_ui/WindowsWasmHost.swift"]),
]

# The modules an app gets from `import Isomer` beside Apple's: the intended
# superset.
ISOMER_MODULES = ["Isomer", "IsomerSwiftUI", "IsomerFoundation", "IsomerMetal", "IsomerFFI", "IsomerNetworkHost"]

PUBLIC_LINE = re.compile(r"^\s*(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*(?:(?:final|static|class|nonisolated|mutating|override)\s+)*"
                         r"(?:public|open)\s")


def other_builds():
    """[(build, [(module, own declarations, other signatures, conformances)])]
    for the builds in OTHER_BUILDS whose graphs are there."""
    results = []
    for build, directory, names in OTHER_BUILDS:
        if not os.path.isdir(directory) or not os.listdir(directory):
            results.append((build, None))
            continue
        rows = []
        for spec in MODULES:
            if spec["name"] not in names:
                continue
            apple, apple_macos = [], []
            for module, path_filter in spec["apple"]:
                apple.extend(load(APPLE_DIR, module, path_filter))
                if os.path.exists(os.path.join(APPLE_MAC_DIR, module + ".symbols.json")):
                    apple_macos.extend(load(APPLE_MAC_DIR, module, path_filter))
            isomer = []
            for module in spec["isomer"]:
                isomer.extend(load(directory, module, own_only=True))
            if not isomer:
                continue
            _, _, _, additions, _, retyped = compare(apple, isomer, apple_macos)
            by_path = {tuple(symbol["pathComponents"]): symbol for symbol in isomer}
            additions = [a for a in additions if not from_upstream(a, by_path)]
            rows.append((spec["name"], additions, retyped, extra_conformances(spec, (directory,)), spec.get("known_gap")))
        results.append((build, rows))
    return results


def write_superset(superset, builds, sdk_version, commit):
    """docs/parity/superset.md: where Isomer has more than Apple's
    interfaces, or other than them: what --check keeps out and what it does
    not see, and what Isomer adds beside them in modules of its own."""
    lines = ["# Where Isomer is a superset of Apple's interfaces", ""]
    lines.append("The other half of [missing/](missing/), which lists what Isomer lacks. An app written "
                 "against Isomer's Apple-named modules should build with Apple's; this page lists what could "
                 "keep one from doing so, and what Isomer adds beside them. Generated by "
                 "`tools/parity/parity.py` on %s from Apple's iOS %s SDK and Isomer at `%s`."
                 % (datetime.date.today().isoformat(), sdk_version, commit))
    lines.append("")
    lines.append("## What `--check --strict` keeps out (the wasm build)")
    lines.append("")
    lines.append("Each Apple-named module as wasm builds it: declarations Apple's (iOS's or macOS's) lacks "
                 "(SPI and underscored names included), declarations Apple has with other parameter or result "
                 "types, and conformances Apple's same type lacks (Sendable and the other marker protocols "
                 "aside, below). `tools/parity/parity.py --check --strict` fails on any of them except in a "
                 "module marked as a known gap.")
    lines.append("")
    lines.append("| Module | Own declarations | Other signatures | Conformances Apple's types lack | Sendable where Apple's is not |")
    lines.append("|---|---|---|---|---|")
    for entry in superset:
        spec = entry["spec"]
        if spec.get("toolchain"):
            continue
        own = len(entry["additions"]) + len(spec.get("underscored", {})) + len(spec.get("upstream", []))
        lines.append("| %s%s | %d | %d | %d | %d |" % (
            spec["name"], " (known gap)" if spec.get("known_gap") else "", own, len(entry["retyped"]),
            len(spec.get("conformances", [])), len(entry["sendable"])))
    lines.append("")
    for entry in superset:
        spec = entry["spec"]
        if not spec.get("known_gap"):
            continue
        lines.append("### %s: not a subset yet" % spec["name"])
        lines.append("")
        lines.append(entry["reasons"].get("gap", "Its declarations are not all Apple's yet."))
        lines.append("")
        shown = ["`%s`" % display(symbol) for symbol in entry["additions"]]
        shown += ["`%s` (%s)" % (name, where) for name, where in sorted(spec.get("underscored", {}).items())]
        if shown:
            lines.append("Declarations Apple's lacks: " + ", ".join(shown) + ".")
            lines.append("")
        if entry["retyped"]:
            lines.append("Declared with other types than Apple's: " + ", ".join(
                "`%s`" % display(symbol) for symbol in sorted(entry["retyped"], key=display)) + ".")
            lines.append("")
    sendable = [(entry["spec"]["name"], entry["sendable"]) for entry in superset if entry["sendable"]]
    lines.append("## Sendable where Apple's type is not (%d)" % sum(len(s) for _, s in sendable))
    lines.append("")
    lines.append("Not failed by `--check`: Sendable adds no members, but code that sends one of these across "
                 "actors, or keeps one in a Sendable type, builds with Isomer only (Swift 6 language mode). "
                 "Apple marks some `~Sendable` outright (its button and form styles); the reverse, Sendable on "
                 "Apple and not in Isomer, is in each module's missing list.")
    lines.append("")
    for name, paths in sendable:
        lines.append("- **%s**: %s" % (name, ", ".join("`%s`" % p for p in paths)))
    lines.append("")
    lines.append("## The other builds")
    lines.append("")
    lines.append("`--check` reads the wasm build. The other platforms compile the same sources with their own "
                 "hosts and `#if` branches; the same comparison, of their builds:")
    lines.append("")
    for build, rows in builds:
        if rows is None:
            lines.append("- **%s**: not built in this run (`parity.py` without `--no-build` builds it)." % build)
            continue
        found = [(name, additions, retyped, conformances, gap) for name, additions, retyped, conformances, gap in rows
                 if (additions or retyped or conformances) and not gap]
        checked = ", ".join(name for name, *_ in rows)
        if not found:
            lines.append("- **%s** (%s): nothing Apple's lacks%s." % (
                build, checked, " beyond the known gaps above" if any(gap for *_, gap in rows) else ""))
            continue
        lines.append("- **%s** (%s):" % (build, checked))
        for name, additions, retyped, conformances, _ in found:
            parts = []
            if additions:
                parts.append("declarations Apple's lacks: " + ", ".join("`%s`" % display(a) for a in additions))
            if retyped:
                parts.append("other signatures: " + ", ".join("`%s`" % display(r) for r in retyped))
            if conformances:
                parts.append("conformances: " + ", ".join("`%s`: `%s`" % c for c in conformances))
            lines.append("  - %s: %s." % (name, "; ".join(parts)))
    for build, files in SOURCE_ONLY_HOSTS:
        public = []
        for path in files:
            full = os.path.join(ROOT, path)
            if os.path.exists(full):
                public += ["%s:%d" % (path, n) for n, line in enumerate(open(full, errors="ignore"), 1)
                           if PUBLIC_LINE.match(line)]
        lines.append("- **%s** (`SwiftUI`, read from its host files: %s): %s." % (
            build, ", ".join("`%s`" % os.path.basename(f) for f in files),
            "public declarations at " + ", ".join(public) if public else
            "no public declarations; the rest is the shared core, as compiled above"))
    lines.append("")
    deviations = [(entry["spec"]["name"], entry["reasons"].get("deviations", [])) for entry in superset]
    deviations = [(name, items) for name, items in deviations if items]
    if deviations:
        lines.append("## Behaviour that differs")
        lines.append("")
        lines.append("Declarations Isomer has, behaving otherwise than Apple's (from tools/parity/reasons):")
        lines.append("")
        for name, items in deviations:
            for item in items:
                lines.append("- **%s**: %s" % (name, item))
        lines.append("")
    lines.append("## What Isomer adds beside Apple's modules")
    lines.append("")
    lines.append("The intended superset: `import Isomer` brings the Isomer module and the Isomer* modules beneath "
                 "it (shared/isomer/Exports.swift), with Isomer's own API under its own names. Code that uses it "
                 "builds with Isomer only, on Apple platforms too (where `import Isomer` is the Apple build of "
                 "the Isomer module). Public declarations as wasm builds them, by type (or the type they extend):")
    lines.append("")
    for module in ISOMER_MODULES:
        # What a type inherits from a protocol's extensions (a view's
        # modifiers) is the protocol's, not the type's: left out.
        symbols = [s for s in load(ISOMER_DIR, module, own_only=True)
                   if not private(s) and "::SYNTHESIZED::" not in s["identifier"]["precise"]]
        if not symbols:
            continue
        lines.append("### %s (%d)" % (module, len(symbols)))
        lines.append("")
        containers = collections.defaultdict(list)
        kinds = {}
        for symbol in symbols:
            path = symbol["pathComponents"]
            if len(path) == 1:
                kinds[path[0]] = symbol["kind"]["displayName"].lower()
                containers.setdefault(path[0], [])
            else:
                containers[path[0]].append(".".join(path[1:]))
        for container in sorted(containers, key=str.lower):
            members = sorted(set(containers[container]), key=str.lower)
            what = kinds.get(container)
            head = "`%s`" % container + (" (%s)" % what if what else " (extended)")
            lines.append("- %s%s" % (head, ": " + ", ".join("`%s`" % m for m in members) if members else ""))
        lines.append("")
    with open(os.path.join(OUT_DIR, "superset.md"), "w") as f:
        f.write("\n".join(lines).rstrip() + "\n")


def write_index(rows, sdk_version):
    lines = ["# What Isomer implements of Apple's frameworks", ""]
    lines.append("On Apple platforms an Isomer app uses Apple's frameworks. Elsewhere `import SwiftUI`, "
                 "`Foundation`, `CoreGraphics`, `Metal`, `CoreTransferable`, `UniformTypeIdentifiers`, "
                 "`PhotosUI`, `ImageIO`, `Observation` and `Synchronization` are Isomer's (or, for Observation "
                 "and Synchronization, the Swift toolchain's own), with Apple's names and as much of Apple's "
                 "interface as can be written in Swift. Each page says what is implemented, what is not, why, "
                 "and whether it is planned, and would list what the module has that Apple's does not: "
                 "declarations, other signatures or conformances. None has any but ImageIO, a known gap "
                 "(superset.md): each other interface is a strict subset of Apple's, and "
                 "`tools/parity/parity.py --check --strict` keeps it so.")
    lines.append("")
    lines.append("Against Apple's iOS %s SDK. Regenerate with `tools/parity/parity.py`." % sdk_version)
    lines.append("")
    lines.append("missing/<Module>.md lists each module's missing declarations one by one, with Apple's "
                 "signatures, by area and type (and the conformances, Sendable and overloads its types lack): "
                 "what to choose the next work from. [superset.md](superset.md) is the other direction: what "
                 "Isomer has beyond Apple's interfaces, checked or not, and what its own modules add.")
    lines.append("")
    lines.append("| Module | Counted | Implemented | Excluded | Not yet | Unclassified | Missing, listed |")
    lines.append("|---|---|---|---|---|---|---|")
    for row in rows:
        lines.append("| [%s](%s.md) | %d | %d (%.0f%%) | %d | %d | %d | %s |" % (
            row["name"], row["name"], row["counted"], row["implemented"], row["percent"],
            row["excluded"], row["planned"], row["unclassified"],
            "[missing/%s.md](missing/%s.md)" % (row["name"], row["name"]) if row.get("missing_list") else "none"))
    with open(os.path.join(OUT_DIR, "README.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def main(argv):
    if "--no-build" not in argv:
        isomer_graphs()
    _, sdk_version = apple_graphs()
    apple_text = apple_interface_text()
    failures = []
    commit = run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT).strip()
    os.makedirs(OUT_DIR, exist_ok=True)
    rows, superset = [], []
    for spec in MODULES:
        apple = []
        for module, path_filter in spec["apple"]:
            apple.extend(load(APPLE_DIR, module, path_filter))
        isomer = []
        for module in spec["isomer"]:
            isomer.extend(load(ISOMER_DIR, module, own_only=not spec.get("toolchain")))
        # The stubs (tools/parity/stubs.py) are left out of symbol graphs,
        # unavailable as they are: counted from the file they are in.
        stub_file = os.path.join(ROOT, "shared", "swift_ui_core", "NotYet.swift")
        spec["stubs"] = (open(stub_file).read().count("@available(*, unavailable")
                         if spec["name"] == "SwiftUI" and os.path.exists(stub_file) else 0)
        reasons_path = os.path.join(REASONS_DIR, spec["name"] + ".json")
        reasons = json.load(open(reasons_path)) if os.path.exists(reasons_path) else {}
        apple_macos = []
        for module, path_filter in spec["apple"]:
            if os.path.exists(os.path.join(APPLE_MAC_DIR, module + ".symbols.json")):
                apple_macos.extend(load(APPLE_MAC_DIR, module, path_filter))
        implemented, missing, set_aside, additions, partial, retyped = compare(apple, isomer, apple_macos)
        spec["retyped"] = [] if spec.get("toolchain") else retyped
        by_path = {tuple(symbol["pathComponents"]): symbol for symbol in isomer}
        spec["upstream"] = [a for a in additions if from_upstream(a, by_path)]
        additions = [a for a in additions if not from_upstream(a, by_path)]
        spec["underscored"] = underscored_additions(spec, apple_text)
        differences = {} if spec.get("toolchain") else conformance_differences(spec)
        spec["conformances"] = differences.get("extra", [])
        rows.append(write_report(spec, sdk_version, implemented, missing, set_aside, additions, partial, reasons, commit))
        rows[-1]["missing_list"] = write_missing(spec, sdk_version, missing, isomer, reasons, commit,
                                                 partial, differences)
        own = 0 if spec.get("toolchain") else (len(additions) + len(spec["underscored"]) + len(spec["upstream"])
                                               + len(spec["conformances"]))
        retyped_count = len(spec["retyped"])
        superset.append({"spec": spec, "additions": additions, "retyped": spec["retyped"],
                         "sendable": differences.get("sendable_extra", []), "reasons": reasons})
        if (own or ("--strict" in argv and retyped_count)) and not spec.get("known_gap"):
            failures.append(spec["name"])
        print("%-16s %5d counted, %5d implemented (%.0f%%)%s%s" % (
            spec["name"], rows[-1]["counted"], rows[-1]["implemented"], rows[-1]["percent"],
            ", %d of Isomer's own" % own if own else "",
            ", %d with other types than Apple's" % retyped_count if retyped_count else ""))
    write_index(rows, sdk_version)
    write_superset(superset, other_builds(), sdk_version, commit)
    # The rule (2026-10-12): the Apple-named modules have nothing of
    # Isomer's own, SPI included, swift-foundation's own and conformances
    # Apple's types lack too. `--check` fails when one does; `--check
    # --strict` also when a declaration's types are not Apple's.
    if "--check" in argv and failures:
        print("Isomer's own declarations in: %s (docs/parity/<Module>.md lists them)" % ", ".join(failures))
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
