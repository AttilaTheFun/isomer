#!/usr/bin/env python3
"""Stamps a build's version into the Storybook apps' working tree, as CI does
for a build of a commit (the commit itself keeps MAJOR.MINOR.0):

    tools/stamp_storybook.py 0.38.7      # from examples/

The visible version wherever the app shows or reports it: Android's
versionName and versionCode (MAJOR x 1,000,000 + MINOR x 1,000 + BUILD), the
iPhone's and the Mac's CFBundleShortVersionString (their build number stays
1), and the web page's isomer-version. `git checkout` the files after.
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def stamp(path, pattern, replacement):
    path = os.path.join(ROOT, path)
    text = open(path).read()
    stamped, count = re.subn(pattern, replacement, text)
    if count != 1:
        sys.exit(f"stamp: {path}: expected one match of {pattern!r}, found {count}")
    open(path, "w").write(stamped)


def main():
    if len(sys.argv) != 2 or not re.fullmatch(r"\d+\.\d+\.\d+", sys.argv[1]):
        sys.exit("usage: stamp_storybook.py MAJOR.MINOR.BUILD")
    version = sys.argv[1]
    major, minor, build = (int(part) for part in version.split("."))
    code = major * 1_000_000 + minor * 1_000 + build
    android = "android/storybook_android_application/BUILD.bazel"
    stamp(android, r'version_name = "[^"]*"', f'version_name = "{version}"')
    stamp(android, r"version_code = \d+", f"version_code = {code}")
    for plist in ("apple/storybook_ios_application/Info.plist", "apple/storybook_macos_application/Info.plist"):
        stamp(plist, r"(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)", rf"\g<1>{version}\g<2>")
    stamp("web/storybook_web_application/index.html",
          r'(<meta name="isomer-version" content=")[^"]*(")', rf"\g<1>{version}\g<2>")
    print(f"stamped {version} (Android versionCode {code})")


if __name__ == "__main__":
    main()
