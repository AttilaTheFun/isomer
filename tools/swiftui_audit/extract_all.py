"""Extract public API records from Apple's SwiftUI/SwiftUICore interfaces (iOS +
macOS), Isomer's SwiftUI module sources, and OpenSwiftUI's sources, into JSON
files next to this script."""
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from swiftdecl import extract, platform_status, introduced  # noqa: E402

OUT = os.path.dirname(os.path.abspath(__file__))
XC = "/Applications/Xcode.app/Contents/Developer/Platforms"
INTERFACES = [
    ("SwiftUICore", "iOS", f"{XC}/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-ios.swiftinterface"),
    ("SwiftUI", "iOS", f"{XC}/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-ios.swiftinterface"),
    ("SwiftUICore", "macOS", f"{XC}/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"),
    ("SwiftUI", "macOS", f"{XC}/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/SwiftUI.framework/Versions/A/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface"),
]

ISO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ISOMER_SWIFTUI_SRCS = (
    sorted(glob.glob(f"{ISO}/shared/swift_ui_core/*.swift"))
    + sorted(glob.glob(f"{ISO}/shared/renderers/*.swift"))
    + [f"{ISO}/wasm/libraries/swift_ui/WasmHost.swift", f"{ISO}/wasm/libraries/swift_ui/WebBridge.swift",
       f"{ISO}/android/libraries/swift_ui/AndroidBridge.swift", f"{ISO}/android/libraries/swift_ui/AndroidHost.swift"]
)
# Separate modules (not the `SwiftUI` surface), scanned for SwiftUI-named API.
ISOMER_EXTRA_SRCS = (
    sorted(glob.glob(f"{ISO}/shared/swift_ui_extensions/*.swift"))
    + sorted(glob.glob(f"{ISO}/shared/platform_services/*.swift"))
    + [f"{ISO}/wasm/libraries/swift_ui/IsomerBridge.swift", f"{ISO}/android/libraries/swift_ui/IsomerBridge.swift"]
)
OSUI = os.path.expanduser("~/Developer/OpenSwiftUI/Sources")
OSUI_SRCS = sorted(glob.glob(f"{OSUI}/OpenSwiftUI/**/*.swift", recursive=True)
                   + glob.glob(f"{OSUI}/OpenSwiftUICore/**/*.swift", recursive=True))


def slim(r, plat=None):
    d = {k: v for k, v in r.items() if k not in ("av_layers",)}
    if plat:
        d["status"] = platform_status(r, plat)
        d["introduced"] = introduced(r, plat)
    else:
        # sources: unavailable if any layer says `*, unavailable`
        st = "ok"
        for av in r["av_layers"]:
            star = av.get("*", {})
            if star.get("unavailable"):
                st = "unavailable"
            elif star.get("deprecated") and st == "ok":
                st = "deprecated"
        d["status"] = st
    d["params"] = [list(p) for p in r.get("params", [])]
    return d


def main():
    apple = []
    for mod, plat, path in INTERFACES:
        recs = extract(open(path).read(), mod, plat, path, interface=True)
        apple += [slim(r, plat) for r in recs]
        print(mod, plat, len(recs), file=sys.stderr)
    json.dump(apple, open(f"{OUT}/apple_api.json", "w"))

    iso = []
    for path in ISOMER_SWIFTUI_SRCS:
        if os.path.exists(path):
            iso += [slim(r) for r in extract(open(path).read(), "Isomer", "all", path, interface=False)]
    json.dump(iso, open(f"{OUT}/isomer_api.json", "w"))
    extra = []
    for path in ISOMER_EXTRA_SRCS:
        if os.path.exists(path):
            extra += [slim(r) for r in extract(open(path).read(), "IsomerExtras", "all", path, interface=False)]
    json.dump(extra, open(f"{OUT}/isomer_extras_api.json", "w"))
    print("isomer", len(iso), "extras", len(extra), file=sys.stderr)

    osui = []
    for path in OSUI_SRCS:
        try:
            osui += [slim(r) for r in extract(open(path).read(), "OpenSwiftUI", "all", path, interface=False)]
        except Exception as e:  # keep going on parser trouble
            print("osui parse error", path, e, file=sys.stderr)
    json.dump(osui, open(f"{OUT}/openswiftui_api.json", "w"))
    print("openswiftui", len(osui), file=sys.stderr)


if __name__ == "__main__":
    main()
