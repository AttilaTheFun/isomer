#!/usr/bin/env python3
"""A proof's comparison with the prior release's, made once: proof-diff.json.

docs/PROOF_FORMAT.md, "The comparison: proof-diff.json" (the owner, 2026-11-11).
One script, copied byte for byte into every repository's tools/ci (as
shireworks.sh is), Python's standard library alone: the pictures are PNGs
decoded here, so no Mac is needed.

    proof_diff.py make <proof dir or proof.zip> [--out FILE] [--base-tag TAG]
        The comparison of a proof (verify's folder, or a release's zip)
        with its prior release's proof.zip, written as proof-diff.json
        (default: beside proof.json, or beside the zip).
    proof_diff.py backfill [--dry-run]
        Every published release of the repository with a proof.zip and no
        proof-diff.json, oldest first: its comparison made against the
        release before it and uploaded as the asset proof-diff.json.

    GITHUB_REPOSITORY  owner/name (CI sets it)
    GH_TOKEN           the job's token: contents: read to make, write to backfill
    GITHUB_API_URL     https://api.github.com unless set
    PROOF_TAG_PREFIX   a release's tag before its version ("v"; "shireworks-v"
                       in a repository of several apps)

`make` never fails its job over the comparison: where the base can't be
fetched or a picture can't be read, the manifest says so in a `note` and
it exits 0. Only a missing proof.json is an error.
"""

import datetime
import hashlib
import io
import json
import os
import re
import struct
import sys
import time
import urllib.error
import urllib.request
import zipfile
import zlib

FORMAT = 1
TOLERANCE = 24


# MARK: The proof, from a folder or a zip


class Proof:
    """proof.json and its files, from verify's folder or a proof.zip."""

    def __init__(self, path=None, data=None):
        self.zip = None
        self.root = None
        if data is not None:
            self.zip = zipfile.ZipFile(io.BytesIO(data))
        elif path.endswith(".zip"):
            self.zip = zipfile.ZipFile(path)
        else:
            self.root = path
        self.document = json.loads(self.read("proof.json"))

    def read(self, name):
        if self.zip is not None:
            return self.zip.read(name)
        with open(os.path.join(self.root, name), "rb") as handle:
            return handle.read()

    def file(self, item):
        try:
            return self.read(item["file"]) if item.get("file") else None
        except (KeyError, OSError):
            return None

    @property
    def items(self):
        return self.document.get("items", []) if self.document.get("format") == 2 else []


# MARK: PNG, decoded


def png_rgba(data):
    """A PNG's width, height and RGBA rows (bytes each): 8 bits a channel,
    grey, grey and alpha, RGB, RGBA or a palette, not interlaced."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    position, chunks, palette, alpha = 8, [], None, None
    width = height = depth = color = interlace = None
    while position < len(data):
        length, kind = struct.unpack(">I4s", data[position:position + 8])
        body = data[position + 8:position + 8 + length]
        position += 12 + length
        if kind == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif kind == b"PLTE":
            palette = body
        elif kind == b"tRNS":
            alpha = body
        elif kind == b"IDAT":
            chunks.append(body)
        elif kind == b"IEND":
            break
    if depth != 8 or interlace != 0 or color not in (0, 2, 3, 4, 6):
        raise ValueError("a PNG of depth %s, color type %s, interlace %s" % (depth, color, interlace))
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]
    stride = width * channels
    raw = zlib.decompress(b"".join(chunks))
    rows, previous = [], bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind, line = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        if kind == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif kind == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif kind == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif kind == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = previous[i]
                c = previous[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
        elif kind != 0:
            raise ValueError("a PNG row filter %d" % kind)
        rows.append(bytes(line))
        previous = line
    if color == 6:
        return width, height, rows
    converted = []
    for line in rows:
        out = bytearray(width * 4)
        for x in range(width):
            if color == 2:
                r, g, b = line[3 * x:3 * x + 3]
                a = 255
            elif color == 0:
                r = g = b = line[x]
                a = 255
            elif color == 4:
                r = g = b = line[2 * x]
                a = line[2 * x + 1]
            else:
                index = line[x]
                r, g, b = palette[3 * index:3 * index + 3]
                a = alpha[index] if alpha is not None and index < len(alpha) else 255
            out[4 * x:4 * x + 4] = bytes((r, g, b, a))
        converted.append(bytes(out))
    return width, height, converted


def compare_pictures(now, then):
    """How many pixels differ by more than TOLERANCE in a channel (RGBA, as
    Reviews and the snapshot tests count them), and the smallest rectangle
    around them; pictures of different sizes differ everywhere."""
    width, height, rows = png_rgba(now)
    then_width, then_height, then_rows = png_rgba(then)
    if (width, height) != (then_width, then_height):
        return max(width * height, then_width * then_height), {
            "x": 0, "y": 0, "width": max(width, then_width), "height": max(height, then_height)}
    changed, left, top, right, bottom = 0, width, height, -1, -1
    for y in range(height):
        row, then_row = rows[y], then_rows[y]
        if row == then_row:
            continue
        for x in range(width):
            i = 4 * x
            if row[i:i + 4] == then_row[i:i + 4]:
                continue
            if (abs(row[i] - then_row[i]) > TOLERANCE or abs(row[i + 1] - then_row[i + 1]) > TOLERANCE
                    or abs(row[i + 2] - then_row[i + 2]) > TOLERANCE or abs(row[i + 3] - then_row[i + 3]) > TOLERANCE):
                changed += 1
                left, top, right, bottom = min(left, x), min(top, y), max(right, x), max(bottom, y)
    if changed == 0:
        return 0, None
    return changed, {"x": left, "y": top, "width": right - left + 1, "height": bottom - top + 1}


# MARK: The comparison


def shown(item):
    """What an item's row shows, as the manifest repeats it."""
    keys = ("id", "kind", "title", "sha256", "width", "height", "result", "tests", "failures")
    return {key: item[key] for key in keys if key in item}


def side(item):
    keys = ("sha256", "width", "height", "result", "tests", "failures")
    return {key: item[key] for key in keys if key in item}


def compared(proof, base_proof):
    """Every item with its status, this proof's in its order then the
    removed ones in the base's."""
    base_items = {}
    for item in (base_proof.items if base_proof else []):
        base_items.setdefault(item["id"], item)
    ids = {item["id"] for item in proof.items}
    out = []
    for item in proof.items:
        entry = shown(item)
        before = base_items.get(item["id"])
        if base_proof is None or before is None:
            entry["status"] = "added"
        else:
            entry["base"] = side(before)
            entry["status"], extra = status(proof, item, base_proof, before)
            entry.update(extra)
        out.append(entry)
    for item in (base_proof.items if base_proof else []):
        if item["id"] not in ids:
            entry = shown(item)
            entry["status"] = "removed"
            out.append(entry)
    return out


def status(proof, item, base_proof, before):
    if item.get("kind") != before.get("kind"):
        return "changed", {}
    if item.get("kind") == "screen":
        if item.get("sha256") and item.get("sha256") == before.get("sha256"):
            return "unchanged", {}
        now, then = proof.file(item), base_proof.file(before)
        if now is None or then is None:
            return "changed", {"note": "a picture is missing from a proof"}
        try:
            pixels, bounds = compare_pictures(now, then)
        except (ValueError, zlib.error, struct.error) as error:
            return "changed", {"note": "not compared: %s" % error}
        extra = {"changedPixels": pixels}
        if bounds:
            extra["bounds"] = bounds
        return ("unchanged" if pixels == 0 else "changed"), extra
    if item.get("kind") == "tests":
        same = all(item.get(key) == before.get(key) for key in ("result", "tests", "failures"))
        return ("unchanged" if same else "changed"), {}
    return ("unchanged" if item == before else "changed"), {}


def manifest(proof, base, base_proof, note=None):
    items = compared(proof, base_proof)
    counts = {key: 0 for key in ("added", "removed", "changed", "unchanged")}
    for entry in items:
        counts[entry["status"]] += 1
    document = proof.document
    out = {
        "format": FORMAT,
        "made": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "tolerance": TOLERANCE,
        "proof": {key: document[key] for key in ("repository", "app", "version", "commit", "run") if key in document},
        "base": base,
        "counts": counts,
        "items": items,
    }
    if note:
        out["note"] = note
    return out


# MARK: GitHub


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def api(path, method="GET", body=None, accept="application/vnd.github+json", content_type=None, host=None):
    base = host or os.environ.get("GITHUB_API_URL", "https://api.github.com")
    request = urllib.request.Request(base + path, data=body, method=method)
    request.add_header("Accept", accept)
    request.add_header("X-GitHub-Api-Version", "2022-11-28")
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    if content_type:
        request.add_header("Content-Type", content_type)
    with urllib.request.urlopen(request, timeout=120) as answer:
        return answer.read()


def releases(repository):
    found = []
    for page in range(1, 11):
        some = json.loads(api("/repos/%s/releases?per_page=100&page=%d" % (repository, page)))
        found += some
        if len(some) < 100:
            break
    return found


def asset_data(repository, asset):
    """An asset's bytes: GitHub answers with a redirect to its storage,
    which is asked without the token."""
    base = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    request = urllib.request.Request("%s/repos/%s/releases/assets/%d" % (base, repository, asset))
    request.add_header("Accept", "application/octet-stream")
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(request, timeout=300) as answer:
            return answer.read()
    except urllib.error.HTTPError as redirect:
        if redirect.code not in (301, 302, 303, 307, 308):
            raise
        with urllib.request.urlopen(redirect.headers["Location"], timeout=300) as answer:
            return answer.read()


def version(tag, prefix):
    if not tag.startswith(prefix):
        return None
    parts = re.findall(r"\d+", tag[len(prefix):])
    if not parts or not tag[len(prefix):][:1].isdigit():
        return None
    numbers = [int(part) for part in parts]
    return numbers + [0] * max(0, 3 - len(numbers))


def base_release(listed, below, prefix, tag=None):
    """The release before (docs/PROOF_FORMAT.md, "The release before", as
    Reviews takes it): of the published, not pre-release releases whose
    tag's version is below `below` (a version's numbers), the one
    published last; or the one named `tag`."""
    candidates = []
    for release in listed:
        if release.get("draft") or release.get("prerelease"):
            continue
        if tag is not None:
            if release.get("tag_name") == tag:
                return release
            continue
        numbers = version(release.get("tag_name", ""), prefix)
        if numbers is not None and (below is None or numbers < below):
            candidates.append((release.get("published_at") or "", release))
    return max(candidates, key=lambda pair: pair[0])[1] if candidates else None


def commit_of(repository, tag):
    try:
        return json.loads(api("/repos/%s/commits/%s" % (repository, tag)))["sha"]
    except (urllib.error.URLError, KeyError, ValueError):
        return None


def base_for(repository, proof, prefix, tag=None, listed=None):
    """The base's description and its proof, or (None, None, note)."""
    try:
        listed = listed if listed is not None else releases(repository)
    except urllib.error.URLError as error:
        return None, None, "the releases weren't listed: %s" % error
    below = version(prefix + str(proof.document.get("version", "")), prefix) if proof.document.get("version") else None
    release = base_release(listed, below, prefix, tag)
    if release is None:
        return None, None, "no release before this one"
    asset = next((a for a in release.get("assets", []) if a.get("name") == "proof.zip"), None)
    if asset is None:
        return None, None, "%s has no proof.zip" % release["tag_name"]
    try:
        data = asset_data(repository, asset["id"])
        base_proof = Proof(data=data)
    except (urllib.error.URLError, zipfile.BadZipFile, KeyError, ValueError) as error:
        return None, None, "%s's proof.zip wasn't read: %s" % (release["tag_name"], error)
    if base_proof.document.get("format") != 2:
        return None, None, "%s's proof is not of format 2" % release["tag_name"]
    base = {
        "tag": release["tag_name"],
        "release": release["id"],
        "commit": base_proof.document.get("commit") or commit_of(repository, release["tag_name"]),
        "asset": asset["id"],
        "sha256": hashlib.sha256(data).hexdigest(),
    }
    return base, base_proof, None


# MARK: Commands


def make(arguments):
    source, out, tag = arguments[0], None, None
    rest = arguments[1:]
    while rest:
        flag = rest.pop(0)
        if flag == "--out":
            out = rest.pop(0)
        elif flag == "--base-tag":
            tag = rest.pop(0)
        else:
            raise SystemExit("proof_diff: unknown %s" % flag)
    repository = os.environ.get("GITHUB_REPOSITORY")
    proof = Proof(path=source)
    repository = repository or proof.document.get("repository")
    prefix = os.environ.get("PROOF_TAG_PREFIX", "v")
    started = time.monotonic()
    base, base_proof, note = base_for(repository, proof, prefix, tag)
    fetched = time.monotonic()
    document = manifest(proof, base, base_proof, note)
    compared_at = time.monotonic()
    out = out or os.path.join(source if proof.root else os.path.dirname(os.path.abspath(source)), "proof-diff.json")
    with open(out, "w") as handle:
        json.dump(document, handle, indent=1)
    counts = document["counts"]
    print("proof_diff: against %s: %d added, %d removed, %d changed, %d unchanged%s" % (
        base["tag"] if base else "nothing", counts["added"], counts["removed"], counts["changed"], counts["unchanged"],
        " (%s)" % note if note else ""))
    screens = sum(1 for entry in document["items"] if "changedPixels" in entry)
    print("proof_diff: %.1f s fetching the base's proof, %.1f s comparing (%d screens' pixels)" % (
        fetched - started, compared_at - fetched, screens))


def backfill(arguments):
    dry = "--dry-run" in arguments
    repository = os.environ.get("GITHUB_REPOSITORY") or (sys.exit("proof_diff: GITHUB_REPOSITORY is owner/name"))
    prefix = os.environ.get("PROOF_TAG_PREFIX", "v")
    listed = releases(repository)
    published = [r for r in listed if not r.get("draft") and not r.get("prerelease") and version(r.get("tag_name", ""), prefix)]
    published.sort(key=lambda r: version(r["tag_name"], prefix))
    for release in published:
        names = {a.get("name") for a in release.get("assets", [])}
        if "proof.zip" not in names or "proof-diff.json" in names:
            continue
        asset = next(a for a in release["assets"] if a.get("name") == "proof.zip")
        proof = Proof(data=asset_data(repository, asset["id"]))
        if proof.document.get("format") != 2:
            print("proof_diff: %s: its proof is not of format 2, passed over" % release["tag_name"])
            continue
        # Its base: the release before its tag, whatever its proof.json's
        # version says (a verify proof says the line).
        below = version(release["tag_name"], prefix)
        before = base_release([r for r in listed if version(r.get("tag_name", ""), prefix) and
                               version(r["tag_name"], prefix) < below], None, prefix)
        if before is None:
            base, base_proof, note = None, None, "no release before this one"
        else:
            base, base_proof, note = base_for(repository, proof, prefix, before["tag_name"], listed)
        document = manifest(proof, base, base_proof, note)
        counts = document["counts"]
        print("proof_diff: %s against %s: %s" % (release["tag_name"], base["tag"] if base else "nothing", counts))
        if dry:
            continue
        body = json.dumps(document, indent=1).encode()
        api("/repos/%s/releases/%d/assets?name=proof-diff.json" % (repository, release["id"]), method="POST", body=body,
            content_type="application/json", host="https://uploads.github.com")
        print("proof_diff: %s: proof-diff.json attached" % release["tag_name"])


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("make", "backfill"):
        raise SystemExit(__doc__)
    if sys.argv[1] == "make":
        if len(sys.argv) < 3:
            raise SystemExit(__doc__)
        make(sys.argv[2:])
    else:
        backfill(sys.argv[2:])


if __name__ == "__main__":
    main()
