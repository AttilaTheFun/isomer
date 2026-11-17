"""How an Apple app is signed on Linux (tools/ci/apple_sign.sh): which code,
in what order, with which provisioning profile and entitlements. It's
Shireworks' signing service's logic (Libraries/Signing/AppleSigning:
Signer.iPhoneSteps, Signer.entitlements, ProfileFolder), with the Python
standard library alone, for rcodesign to carry out.

    python3 -I apple_profiles.py --bundle <X.app> --platform ios|mac --profiles <dir> --certificate <sha1>
        [--kind development|production] --rcodesign <rcodesign> --work <dir>

Prints a JSON list of steps, the deepest code first and the app last:
{"path": <code>, "bundle": true|false, "entitlements": <plist file>|null,
"profile": <profile file>|null, "embed": <where the profile goes>|null}.
A bundle with a profile is signed with its entitlements; any other code
keeps the entitlements and identifier its signature has (rcodesign carries
them over). Refuses, saying why, when a bundle has no profile here that
names the certificate, or its entitlements ask for one its profile doesn't
allow (an iPhone app iOS would refuse to install).
"""

import argparse
import datetime
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys

PROVISIONED = {"app", "appex"}
CODE_BUNDLES = {"app", "appex", "framework", "xpc", "bundle", "plugin", "kext", "systemextension", "dext", "qlgenerator", "mdimporter"}


def fail(message):
    sys.exit(f"apple_profiles: {message}")


def profile_plist(data):
    """A profile's property list, out of its CMS envelope: the XML it carries as is."""
    start, end = data.find(b"<?xml"), data.rfind(b"</plist>")
    if start < 0 or end < 0:
        return None
    try:
        return plistlib.loads(data[start:end + len(b"</plist>")])
    except Exception:
        return None


class Profile:
    def __init__(self, path, info):
        entitlements = info.get("Entitlements") or {}
        identifier = entitlements.get("application-identifier") or entitlements.get("com.apple.application-identifier")
        expires = info.get("ExpirationDate")
        if not isinstance(identifier, str) or not isinstance(expires, datetime.datetime):
            raise ValueError("not a profile")
        prefixes = info.get("ApplicationIdentifierPrefix") or []
        self.prefix = prefixes[0] if prefixes else identifier.split(".", 1)[0]
        if not identifier.startswith(self.prefix + "."):
            raise ValueError("its identifier isn't its prefix's")
        self.path = path
        self.name = info.get("Name") or os.path.basename(path)
        self.bundle_id = identifier[len(self.prefix) + 1:]
        teams = info.get("TeamIdentifier") or []
        self.team = teams[0] if teams else self.prefix
        self.platforms = info.get("Platform") or ["iOS"]
        self.mac = "OSX" in self.platforms
        self.certificates = {hashlib.sha1(der).hexdigest().upper() for der in info.get("DeveloperCertificates") or []}
        self.entitlements = entitlements
        self.expires = expires if expires.tzinfo else expires.replace(tzinfo=datetime.timezone.utc)
        debuggable = (entitlements.get("get-task-allow") or entitlements.get("com.apple.security.get-task-allow")) is True
        if info.get("ProvisionsAllDevices") is True:
            self.kind = "developer-id" if self.mac else "enterprise"
        elif "ProvisionedDevices" in info:
            self.kind = "development" if debuggable else "ad-hoc"
        else:
            self.kind = "app-store"


def profiles_in(folder):
    """Every profile under `folder`, at any depth (a .tar of a folder of them as much as of them)."""
    found = []
    for root, _, files in os.walk(folder):
        for name in sorted(files):
            if not name.endswith((".mobileprovision", ".provisionprofile")):
                continue
            path = os.path.join(root, name)
            with open(path, "rb") as file:
                info = profile_plist(file.read())
            if info is None:
                sys.stderr.write(f"apple_profiles: {os.path.relpath(path, folder)} isn't a profile it can read\n")
                continue
            try:
                found.append(Profile(path, info))
            except ValueError as error:
                sys.stderr.write(f"apple_profiles: {os.path.relpath(path, folder)} left out: {error}\n")
    return found


def described(profiles, bundle, certificate, now):
    """What there is for `bundle`, and why none of it fits: each profile's kind, end, and whether it names the
    certificate (its SHA-1 alone, never anything of the key)."""
    mine = [p for p in profiles if p.bundle_id == bundle]
    if not mine:
        return f"no profile here is for {bundle} (there are {len(profiles)}: {', '.join(sorted({p.bundle_id for p in profiles})) or 'none'})"
    return "; ".join(f"{p.name} ({p.kind}, {'expired' if p.expires <= now else 'until ' + p.expires.date().isoformat()}, "
                     f"{'names' if certificate in p.certificates else 'does not name'} the signing certificate {certificate[:8]}…)"
                     for p in mine)


def bundle_info(bundle):
    # A Mac app's, an iPhone app's or framework's, a Mac framework's (Versions/Current/Resources, by its link).
    for relative in ("Contents/Info.plist", "Info.plist", "Resources/Info.plist"):
        path = os.path.join(bundle, relative)
        if os.path.isfile(path):
            with open(path, "rb") as file:
                return plistlib.load(file)
    return None


def bundle_id(bundle):
    info = bundle_info(bundle) or {}
    identifier = info.get("CFBundleIdentifier")
    if not identifier:
        fail(f"{os.path.basename(bundle)} names no CFBundleIdentifier")
    return identifier


def executable(bundle):
    info = bundle_info(bundle) or {}
    name = info.get("CFBundleExecutable")
    if not name:
        return None
    for relative in (os.path.join("Contents", "MacOS", name), name):
        path = os.path.join(bundle, relative)
        if os.path.isfile(path):
            return path
    return None


def is_macho(path):
    try:
        with open(path, "rb") as file:
            head = file.read(8)
    except OSError:
        return False
    if len(head) < 8:
        return False
    magic, following = int.from_bytes(head[:4], "big"), int.from_bytes(head[4:8], "big")
    if magic in (0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE):
        return True
    # A universal binary's count of architectures; a Java class file's version (45 or more) begins the same.
    return magic in (0xCAFEBABE, 0xCAFEBABF) and 1 <= following < 45


def has_code(bundle):
    extension = bundle.rsplit(".", 1)[-1]
    return extension not in ("bundle", "plugin") or executable(bundle) is not None


def nested_code(bundle):
    """The code inside a bundle, the deepest first (Signer.nestedCode): bundles of code, and every Mach-O file but a
    bundle's own executable; links never followed."""
    executables = set()
    found = []
    for root, folders, files in os.walk(bundle, followlinks=False):
        for name in folders:
            path = os.path.join(root, name)
            if os.path.islink(path):
                continue
            if name.rsplit(".", 1)[-1] in CODE_BUNDLES and "." in name and has_code(path):
                # A Mac framework with versions is signed as its current version (Versions/A): rcodesign takes that for
                # a bundle nested in the framework, which --shallow leaves alone, so signing the framework itself left
                # its binary as it was (0.10's second run: "not signed with a valid Developer ID certificate").
                current = os.path.join(path, "Versions", "Current")
                if os.path.islink(current) and os.path.isdir(current):
                    path = os.path.realpath(current)
                found.append(path)
                main = executable(path)
                if main:
                    executables.add(os.path.realpath(main))
        for name in files:
            path = os.path.join(root, name)
            if not os.path.islink(path) and is_macho(path):
                found.append(path)
    own = executable(bundle)
    if own:
        executables.add(os.path.realpath(own))
    found = [path for path in found if os.path.isdir(path) or os.path.realpath(path) not in executables]
    return sorted(found, key=lambda path: (-len(path.split(os.sep)), path))


def own_entitlements(rcodesign, code):
    """The entitlements a piece of code's signature carries (rcodesign's print-signature-info), {} when none."""
    target = executable(code) if os.path.isdir(code) else code
    if not target:
        return {}
    answer = subprocess.run([rcodesign, "print-signature-info", target], capture_output=True, text=True)
    if answer.returncode != 0:
        return {}
    lines, collecting = [], False
    for line in answer.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("entitlements_plist:"):
            collecting = True
            continue
        if not collecting:
            continue
        match = re.match(r"^- (.*)$", stripped)
        if not match:
            break
        item = match.group(1)
        if item.startswith("'") and item.endswith("'"):
            item = item[1:-1].replace("''", "'")
        elif item.startswith('"') and item.endswith('"'):
            item = json.loads(item)
        lines.append(item)
        if item.strip() == "</plist>":
            break
    if not lines:
        return {}
    try:
        return plistlib.loads("\n".join(lines).encode())
    except Exception:
        fail(f"{os.path.basename(code)}'s entitlements couldn't be read")


def restricted_on_mac(key, value):
    """Whether a Mac app's entitlement needs a provisioning profile: its identity, keychain groups, push and every
    other com.apple.developer one, and app groups not named by the team (group.*, since macOS 15)."""
    if key in ("com.apple.application-identifier", "keychain-access-groups", "com.apple.developer.team-identifier"):
        return True
    if key.startswith("com.apple.developer."):
        return True
    if key == "com.apple.security.application-groups":
        return any(isinstance(group, str) and group.startswith("group.") for group in (value or []))
    return False


def concrete(allowed, prefix, bundle):
    """A profile's entitlements for a bundle that came with none: the team's wildcard keychain group made the bundle's
    own, other wildcards left out (Signer.concrete)."""
    result = {}
    for key, value in allowed.items():
        if isinstance(value, str):
            if "*" not in value:
                result[key] = value
        elif isinstance(value, list) and all(isinstance(item, str) for item in value):
            kept = [prefix + "." + bundle if item == prefix + ".*" else item for item in value if item == prefix + ".*" or "*" not in item]
            if kept:
                result[key] = kept
        else:
            result[key] = value
    return result


def entitlements(own, bundle, profile):
    """A bundle's entitlements made its profile's (Signer.entitlements)."""
    allowed = profile.entitlements
    mac = profile.mac
    identifier_key = "com.apple.application-identifier" if mac else "application-identifier"
    push_key = "com.apple.developer.aps-environment" if mac else "aps-environment"
    debug_key = "com.apple.security.get-task-allow" if mac else "get-task-allow"
    result = dict(own) if own else concrete(allowed, profile.prefix, bundle)
    built = own.get(identifier_key)
    built = built.split(".", 1)[0] + "." if isinstance(built, str) and "." in built else None
    result[identifier_key] = profile.prefix + "." + bundle
    if "com.apple.developer.team-identifier" in allowed:
        result["com.apple.developer.team-identifier"] = profile.team
    groups = result.get("keychain-access-groups")
    if isinstance(groups, list):
        rewritten = []
        for group in groups:
            for old in ["$(AppIdentifierPrefix)"] + ([built] if built else []):
                if group.startswith(old):
                    group = profile.prefix + "." + group[len(old):]
                    break
            rewritten.append(group)
        result["keychain-access-groups"] = rewritten
    if push_key in result and push_key in allowed:
        result[push_key] = allowed[push_key]
    if debug_key in allowed:
        result[debug_key] = allowed[debug_key]
    else:
        result.pop(debug_key, None)
    # On an iPhone every key must be one its profile allows; on a Mac those a profile gates (restricted_on_mac), the
    # hardened runtime's and the sandbox's being no profile's (NCH's review of #438: a Push the profile lacks would
    # otherwise keep the build's development value, and be killed at launch).
    refused = sorted(key for key, value in result.items() if key not in allowed and (not mac or restricted_on_mac(key, value)))
    if refused:
        fail(f"{bundle}'s profile ({profile.name}) does not allow {', '.join(refused)}: give its App ID those capabilities "
             "and make the profile again")
    return result


def choose(profiles, bundles, kinds, certificate, now):
    """One profile per bundle id, all of one kind, the first kind that has one for each, every one naming the
    certificate (ProfileFolder.iPhoneProfiles, without experiments' wildcard)."""
    for kind in kinds:
        chosen = {}
        for identifier in bundles:
            candidates = [p for p in profiles if p.bundle_id == identifier and p.kind == kind and p.expires > now
                          and certificate in p.certificates]
            if candidates:
                chosen[identifier] = max(candidates, key=lambda p: p.expires)
        if len(chosen) == len(set(bundles)):
            return chosen
    missing = next((i for i in bundles if not any(p.bundle_id == i and p.kind in kinds and p.expires > now and certificate in p.certificates
                                                   for p in profiles)), bundles[0])
    fail(f"no {' or '.join(kinds)} profile for {missing} here naming the signing certificate: {described(profiles, missing, certificate, now)}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--platform", choices=["ios", "mac"], required=True)
    parser.add_argument("--profiles", required=True)
    parser.add_argument("--certificate", required=True, help="the signing certificate's SHA-1")
    parser.add_argument("--kind", choices=["development", "production"], default="production")
    parser.add_argument("--rcodesign", required=True)
    parser.add_argument("--work", required=True)
    arguments = parser.parse_args()
    app = os.path.abspath(arguments.bundle)
    certificate = arguments.certificate.replace(":", "").upper()
    now = datetime.datetime.now(datetime.timezone.utc)
    profiles = [p for p in profiles_in(arguments.profiles) if p.mac == (arguments.platform == "mac")]
    nested = nested_code(app)
    steps = []

    def written(values, name):
        path = os.path.join(arguments.work, name)
        with open(path, "wb") as file:
            plistlib.dump(values, file)
        return path

    if arguments.platform == "ios":
        app_id = bundle_id(app)
        bundles = [app_id]
        for code in nested:
            if code.rsplit(".", 1)[-1] in PROVISIONED and os.path.isdir(code):
                identifier = bundle_id(code)
                if not identifier.startswith(app_id + "."):
                    fail(f"{os.path.basename(code)} in {app_id} is {identifier}, not one of {app_id}'s own")
                bundles.append(identifier)
        kinds = ["development"] if arguments.kind == "development" else ["ad-hoc", "enterprise", "development"]
        chosen = choose(profiles, bundles, kinds, certificate, now)
        for index, code in enumerate(nested + [app]):
            provisioned = code == app or (os.path.isdir(code) and code.rsplit(".", 1)[-1] in PROVISIONED)
            if not provisioned:
                steps.append({"path": code, "bundle": os.path.isdir(code), "entitlements": None, "profile": None, "embed": None})
                continue
            identifier = app_id if code == app else bundle_id(code)
            profile = chosen[identifier]
            values = entitlements(own_entitlements(arguments.rcodesign, code), identifier, profile)
            steps.append({"path": code, "bundle": True, "entitlements": written(values, f"entitlements-{index}.plist"),
                          "profile": profile.path, "embed": os.path.join(code, "embedded.mobileprovision")})
    else:
        app_id = bundle_id(app)
        for code in nested:
            steps.append({"path": code, "bundle": os.path.isdir(code), "entitlements": None, "profile": None, "embed": None})
        # A Mac app's Developer ID profile, if it has one here: only an app whose entitlements Apple restricts needs one.
        candidates = [p for p in profiles if p.bundle_id == app_id and p.kind == "developer-id" and p.expires > now
                      and certificate in p.certificates]
        own = own_entitlements(arguments.rcodesign, app)
        if candidates:
            profile = max(candidates, key=lambda p: p.expires)
            steps.append({"path": app, "bundle": True, "entitlements": written(entitlements(own, app_id, profile), "entitlements-app.plist"),
                          "profile": profile.path, "embed": os.path.join(app, "Contents", "embedded.provisionprofile")})
        else:
            # Without a profile, an entitlement Apple restricts has macOS kill the app at launch (AMFI), which notarizing
            # doesn't catch (NCH's review of #438): refused here instead.
            restricted = sorted(key for key, value in own.items() if restricted_on_mac(key, value))
            if restricted:
                fail(f"{app_id} asks for {', '.join(restricted)}, which only a Developer ID profile allows, and there's no "
                     f"profile for it here naming the signing certificate: {described(profiles, app_id, certificate, now)}")
            steps.append({"path": app, "bundle": True, "entitlements": written(own, "entitlements-app.plist") if own else None,
                          "profile": None, "embed": None})
    json.dump(steps, sys.stdout, indent=1)


if __name__ == "__main__":
    main()
