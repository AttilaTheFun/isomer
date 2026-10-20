#!/usr/bin/env python3
"""Builds the portable symbol table: SF Symbol names → Lucide icons (ISC
licensed, https://lucide.dev) as single SVG path strings, for hosts without
SF Symbols (the web renderer draws them inline; Android parses them into
ImageVectors). Run with a lucide-static checkout:

    tools/symbols/generate.py <lucide-static/icons dir>

Writes wasm/libraries/swift_ui/runtime/symbols.js and
android/libraries/swift_ui/kotlin/dev/isomer/runtime/Symbols.kt.
"""
import json, math, os, re, sys

# SF Symbol name → (lucide icon, filled?). A `.fill` variant of a mapped
# name falls back to its base icon drawn filled.
MAP = {
    "plus": "plus", "minus": "minus", "xmark": "x", "checkmark": "check", "gearshape": "settings", "gear": "settings",
    "magnifyingglass": "search", "trash": "trash-2", "pencil": "pencil", "square": "square", "circle": "circle",
    "chevron": "chevron-right", "arrow": "arrow-right", "ellipsis": "ellipsis", "ellipsis.circle": "circle-ellipsis",
    "paperplane": "send", "person": "user", "bell": "bell", "star": "star", "heart": "heart", "envelope": "mail",
    "calendar": "calendar", "camera": "camera", "photo": "image", "mic": "mic", "phone": "phone", "house": "house",
    "info": "info", "questionmark": "circle-help", "exclamationmark": "circle-alert",
    "chevron.left": "chevron-left", "chevron.right": "chevron-right", "chevron.up": "chevron-up", "chevron.down": "chevron-down",
    "chevron.compact.forward": "chevron-right", "chevron.up.chevron.down": "chevrons-up-down", "chevron.right.circle": "circle-chevron-right",
    "arrow.left": "arrow-left", "arrow.right": "arrow-right", "arrow.up": "arrow-up", "arrow.down": "arrow-down",
    "line.3.horizontal": "menu", "line.3.horizontal.decrease": "list-filter", "square.and.arrow.up": "share",
    "square.and.arrow.down": "download", "arrow.down.app": "download", "square.and.pencil": "square-pen", "cloud": "cloud", "chart.bar.xaxis": "chart-bar",
    "sidebar.left": "panel-left", "sidebar.leading": "panel-left", "sidebar.right": "panel-right", "sidebar.trailing": "panel-right",
    "chart": "chart-line", "chart.pie": "chart-pie", "chart.bar": "chart-bar", "chart.line.uptrend.xyaxis": "trending-up",
    "shippingbox": "package", "arrow.clockwise": "rotate-cw", "arrow.counterclockwise": "rotate-ccw",
    "arrow.triangle.2.circlepath": "refresh-cw", "creditcard": "credit-card", "doc": "file", "doc.text": "file-text",
    "doc.on.doc": "copy", "folder": "folder", "folder.badge.plus": "folder-plus", "lock": "lock", "lock.open": "lock-open",
    "key": "key", "globe": "globe", "globe.americas": "globe", "globe.europe.africa": "globe", "globe.asia.australia": "globe",
    "bolt": "zap", "flame": "flame", "drop": "droplet", "wifi": "wifi", "network": "network", "cpu": "cpu",
    "memorychip": "memory-stick", "externaldrive": "hard-drive", "server.rack": "server", "terminal": "terminal",
    "tray": "inbox", "tray.and.arrow.up": "upload", "clock": "clock", "eye": "eye", "eye.slash": "eye-off", "link": "link",
    "tag": "tag", "map": "map", "gauge": "gauge", "speedometer": "gauge", "play": "play", "pause": "pause", "stop": "square",
    "backward": "skip-back", "forward": "skip-forward", "speaker": "volume", "speaker.wave.2": "volume-2", "speaker.slash": "volume-x",
    "music.note": "music", "sun.max": "sun", "moon": "moon", "moon.stars": "moon-star", "cloud.rain": "cloud-rain",
    "cloud.sun": "cloud-sun", "snowflake": "snowflake", "wind": "wind", "thermometer": "thermometer", "umbrella": "umbrella",
    "leaf": "leaf", "sparkles": "sparkles", "sparkle": "sparkle", "wand.and.stars": "wand-sparkles", "lightbulb": "lightbulb",
    "cart": "shopping-cart", "bag": "shopping-bag", "gift": "gift", "bookmark": "bookmark", "book": "book",
    "newspaper": "newspaper", "paperclip": "paperclip", "scissors": "scissors", "hammer": "hammer", "wrench": "wrench",
    "screwdriver": "wrench", "gamecontroller": "gamepad-2", "dice": "dice-5", "trophy": "trophy", "medal": "medal",
    "flag": "flag", "crown": "crown", "location": "navigation", "mappin": "map-pin", "compass": "compass", "car": "car",
    "airplane": "plane", "bicycle": "bike", "bus": "bus", "tram": "train-front", "figure.walk": "footprints",
    "figure.run": "footprints", "fork.knife": "utensils", "cup.and.saucer": "coffee", "pills": "pill", "cross": "plus",
    "bandage": "bandage", "stethoscope": "stethoscope", "brain": "brain", "pawprint": "paw-print",
    "hand.thumbsup": "thumbs-up", "hand.thumbsdown": "thumbs-down", "hand.wave": "hand", "hand.raised": "hand",
    "face.smiling": "smile", "message": "message-circle", "bubble": "message-circle", "bubble.left": "message-square",
    "text.bubble": "message-square-text", "quote.bubble": "message-square-quote", "at": "at-sign", "number": "hash",
    "dollarsign": "dollar-sign", "percent": "percent", "plus.circle": "circle-plus", "minus.circle": "circle-minus",
    "xmark.circle": "circle-x", "checkmark.circle": "circle-check", "checkmark.seal": "badge-check",
    "exclamationmark.triangle": "triangle-alert", "exclamationmark.circle": "circle-alert",
    "questionmark.circle": "circle-help", "info.circle": "info", "lightning": "zap", "battery.100": "battery-full",
    "battery.25": "battery-low", "antenna.radiowaves.left.and.right": "radio-tower", "iphone": "smartphone",
    "ipad": "tablet", "laptopcomputer": "laptop", "desktopcomputer": "monitor", "display": "monitor",
    "keyboard": "keyboard", "keyboard.chevron.compact.down": "keyboard", "printer": "printer", "headphones": "headphones",
    "tv": "tv", "video": "video", "video.fill": "video", "film": "film", "photo.on.rectangle": "images", "square.grid.2x2": "layout-grid",
    "list.bullet": "list", "list.dash": "list", "text.alignleft": "align-left", "slider.horizontal.3": "sliders-horizontal",
    "arrow.up.arrow.down": "arrow-up-down", "arrow.left.arrow.right": "arrow-left-right", "arrow.uturn.left": "undo-2",
    "arrow.uturn.right": "redo-2", "arrow.up.right": "arrow-up-right", "arrow.down.left": "arrow-down-left",
    "arrow.down.to.line": "arrow-down-to-line", "arrow.up.to.line": "arrow-up-to-line", "icloud": "cloud", "checkmark.icloud": "cloud-check", "icloud.and.arrow.up": "cloud-upload",
    "icloud.and.arrow.down": "cloud-download", "icloud.slash": "cloud-off", "checklist": "list-checks",
    "arrow.down.circle": "circle-arrow-down", "arrow.up.circle": "circle-arrow-up", "shuffle": "shuffle", "repeat": "repeat",
    "timer": "timer", "stopwatch": "timer", "alarm": "alarm-clock", "hourglass": "hourglass",
    "calendar.badge.plus": "calendar-plus", "person.2": "users", "person.2.wave.2": "users", "person.3": "users", "person.crop.circle": "circle-user",
    "person.circle": "circle-user", "building": "building", "building.2": "building-2", "storefront": "store",
    "graduationcap": "graduation-cap", "briefcase": "briefcase", "banknote": "banknote", "list.clipboard": "clipboard-list",
    "note.text": "notebook-pen", "text.justify": "align-justify", "textformat": "type", "bold": "bold", "italic": "italic",
    "underline": "underline", "paintbrush": "paintbrush", "paintpalette": "palette", "eyedropper": "pipette",
    "hare": "rabbit", "tortoise": "turtle", "ant": "bug", "bird": "bird", "fish": "fish", "cat": "cat", "dog": "dog",
    "power": "power", "shield": "shield", "waveform": "audio-waveform", "recordingtape": "disc", "radio": "radio",
    "target": "target", "scope": "crosshair", "arrow.triangle.branch": "git-branch", "square.on.square": "copy",
    "rectangle": "rectangle-horizontal", "capsule": "rectangle-horizontal", "triangle": "triangle", "diamond": "diamond",
    "hexagon": "hexagon", "octagon": "octagon", "seal": "badge", "sunrise": "sunrise", "sunset": "sunset",
    "sparkles.rectangle.stack": "sparkles", "archivebox": "archive", "swift": "bird", "phone.down": "phone-off",
    "app.dashed": "square-dashed", "play.circle": "circle-play", "checkmark.seal.fill": "badge-check",
    "shippingbox.fill": "package", "stop.fill": "square", "hand.raised.fill": "hand", "exclamationmark.triangle.fill": "triangle-alert",
    "xmark.circle.fill": "circle-x", "plus.circle.fill": "circle-plus", "ellipsis.circle.fill": "circle-ellipsis", "cloud.fill": "cloud", "play.fill": "play",
    "phone.fill": "phone", "phone.down.fill": "phone-off", "square.and.arrow.up.fill": "share",
}
FILLED_OK = {"circle", "square", "star", "heart", "bell", "flame", "drop", "bolt", "trash", "play", "stop", "pause",
             "cloud", "hand.raised", "shippingbox", "checkmark.seal", "xmark.circle", "plus.circle", "checkmark.circle",
             "exclamationmark.triangle", "phone", "phone.down", "person", "moon", "sun.max", "bookmark", "flag", "tag",
             "lock", "house", "envelope", "camera", "mic", "square.fill", "circle.fill", "star.fill", "heart.fill",
             "bell.fill", "flame.fill", "drop.fill", "bolt.fill", "trash.fill",
             "folder", "arrow.down.circle", "play.circle"}

NUM = r"[-+]?(?:\d+\.?\d*|\.\d+)(?:e[-+]?\d+)?"

def fmt(v):
    s = ("%.3f" % v).rstrip("0").rstrip(".")
    return s if s not in ("", "-0") else "0"

def element_to_path(tag, attrs):
    a = lambda k, d="0": float(attrs.get(k, d))
    if tag == "path":
        return attrs.get("d", "")
    if tag == "circle":
        cx, cy, r = a("cx"), a("cy"), a("r")
        return f"M{fmt(cx - r)} {fmt(cy)}a{fmt(r)} {fmt(r)} 0 1 0 {fmt(2*r)} 0a{fmt(r)} {fmt(r)} 0 1 0 {fmt(-2*r)} 0"
    if tag == "ellipse":
        cx, cy, rx, ry = a("cx"), a("cy"), a("rx"), a("ry")
        return f"M{fmt(cx - rx)} {fmt(cy)}a{fmt(rx)} {fmt(ry)} 0 1 0 {fmt(2*rx)} 0a{fmt(rx)} {fmt(ry)} 0 1 0 {fmt(-2*rx)} 0"
    if tag == "line":
        return f"M{fmt(a('x1'))} {fmt(a('y1'))}L{fmt(a('x2'))} {fmt(a('y2'))}"
    if tag in ("polyline", "polygon"):
        pts = re.findall(NUM, attrs.get("points", ""))
        pairs = list(zip(pts[0::2], pts[1::2]))
        d = "M" + "L".join(f"{x} {y}" for x, y in pairs)
        return d + ("Z" if tag == "polygon" else "")
    if tag == "rect":
        x, y, w, hgt = a("x"), a("y"), a("width"), a("height")
        rx = a("rx", attrs.get("ry", "0")); ry = a("ry", str(rx))
        if rx <= 0:
            return f"M{fmt(x)} {fmt(y)}h{fmt(w)}v{fmt(hgt)}h{fmt(-w)}Z"
        return (f"M{fmt(x + rx)} {fmt(y)}h{fmt(w - 2*rx)}a{fmt(rx)} {fmt(ry)} 0 0 1 {fmt(rx)} {fmt(ry)}v{fmt(hgt - 2*ry)}"
                f"a{fmt(rx)} {fmt(ry)} 0 0 1 {fmt(-rx)} {fmt(ry)}h{fmt(-(w - 2*rx))}a{fmt(rx)} {fmt(ry)} 0 0 1 {fmt(-rx)} {fmt(-ry)}"
                f"v{fmt(-(hgt - 2*ry))}a{fmt(rx)} {fmt(ry)} 0 0 1 {fmt(rx)} {fmt(-ry)}Z")
    return ""

def icon_paths(svg_text):
    """One path string per SVG element, in order (the outer shape first in
    Lucide's badge icons)."""
    body = re.sub(r"<!--.*?-->", "", svg_text, flags=re.S)
    parts = []
    for m in re.finditer(r"<(path|circle|ellipse|line|polyline|polygon|rect)\b([^>]*)/?>", body):
        attrs = dict(re.findall(r'([a-zA-Z0-9:-]+)="([^"]*)"', m.group(2)))
        d = element_to_path(m.group(1), attrs)
        # An element's first `m` is absolute in SVG; joined after another
        # element it would be relative, so spell it `M` — and keep the pairs
        # that follow it relative (`m` implies `l`, `M` implies `L`).
        m2 = re.match(r"m\s*(-?[\d.]+)[\s,]+(-?[\d.]+)(.*)$", d, flags=re.S) if d and d[0] == "m" else None
        if m2: d = "M" + m2.group(1) + " " + m2.group(2) + " l" + m2.group(3)
        if d: parts.append((m.group(1), d))
    return parts



def main():
    icons_dir = sys.argv[1]
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    table = {}
    def entry(lucide, filled):
        path = os.path.join(icons_dir, lucide + ".svg")
        if not os.path.exists(path):
            print("missing lucide icon:", lucide, file=sys.stderr); return None
        elements = icon_paths(open(path).read())
        parts = [d for _, d in elements]
        if filled and len(parts) > 1:
            # A filled badge keeps its glyph: the outer shape (a closed
            # primitive when there is one, else the longest path) is filled,
            # the rest is drawn in the contrasting colour (SF's plus.circle.fill).
            closed = [i for i, (tag, _) in enumerate(elements) if tag in ("rect", "circle", "ellipse", "polygon")]
            outer = closed[0] if closed else max(range(len(parts)), key=lambda i: (len(parts[i]), -i))
            return {"d": parts[outer], "inner": " ".join(p for i, p in enumerate(parts) if i != outer), "fill": True}
        return {"d": " ".join(parts), "fill": filled}
    for sf, lucide in MAP.items():
        e = entry(lucide, sf.endswith(".fill") or sf in ("stop.fill",))
        if e: table[sf] = e
    # `.fill` variants of mapped names share the base icon, filled.
    for sf in list(MAP):
        if not sf.endswith(".fill") and sf + ".fill" not in table and sf in FILLED_OK:
            e = entry(MAP[sf], True)
            if e: table[sf + ".fill"] = e
    js = os.path.join(root, "wasm/libraries/swift_ui/runtime/symbols.js")
    with open(js, "w") as f:
        f.write("// Generated by tools/symbols/generate.py from Lucide (ISC, https://lucide.dev):\n"
                "// SF Symbol names as 24×24 outline path data for hosts without SF Symbols.\n"
                "export const SYMBOLS = " + json.dumps(table, separators=(",", ":"), sort_keys=True) + ";\n")
    kt = os.path.join(root, "android/libraries/swift_ui/kotlin/dev/isomer/runtime/Symbols.kt")
    with open(kt, "w") as f:
        f.write("// Generated by tools/symbols/generate.py from Lucide (ISC, https://lucide.dev):\n"
                "// SF Symbol names as 24x24 outline path data for hosts without SF Symbols.\n"
                "package dev.isomer.runtime\n\n"
                "/** Path data for the outer shape, the inner glyph (drawn in the contrasting\n"
                " *  colour when filled), and whether the shape is filled. */\n"
                "data class Symbol(val d: String, val inner: String, val filled: Boolean)\n\n"
                "object Symbols {\n"
                "    val table: Map<String, Symbol> = mapOf(\n")
        for name in sorted(table):
            d = table[name]["d"].replace("\\", "\\\\").replace('"', '\\"')
            inner = table[name].get("inner", "").replace("\\", "\\\\").replace('"', '\\"')
            f.write('        "%s" to Symbol("%s", "%s", %s),\n' % (name, d, inner, "true" if table[name]["fill"] else "false"))
        f.write("    )\n}\n")
    print("wrote", len(table), "symbols")

if __name__ == "__main__":
    main()
