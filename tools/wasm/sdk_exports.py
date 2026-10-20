"""Writes an SDK bundle's manifest with the exports a program linked from it
needs added: the entries its hosts call by name, read from the archives' symbol
indexes (the GNU ar `/` member) and matched against patterns (`prefix*` or a
name; a name is exported when defined).

    sdk_exports.py <base manifest.json> <out manifest.json> <archive>... -- <pattern>...

A link with these exports and `--gc-sections` keeps what the hosts reach and
drops the rest, where `--export-all` kept every function of every archive
(Foundation's included).
"""

import fnmatch
import json
import struct
import sys


def archive_symbols(path):
    """The global symbols an archive's index lists."""
    data = open(path, "rb").read()
    if data[:8] != b"!<arch>\n":
        return []
    position = 8
    while position + 60 <= len(data):
        header = data[position:position + 60]
        name = header[:16].decode().strip()
        size = int(header[48:58].decode().strip())
        body = data[position + 60:position + 60 + size]
        if name == "/":
            count = struct.unpack(">I", body[:4])[0]
            return [s.decode() for s in body[4 + 4 * count:].split(b"\0")[:count]]
        position += 60 + size + (size & 1)
    return []


def main(argv):
    base_path, out_path = argv[1], argv[2]
    separator = argv.index("--")
    archives, patterns = argv[3:separator], argv[separator + 1:]
    symbols = set()
    for archive in archives:
        symbols.update(archive_symbols(archive))
    exports = set()
    for pattern in patterns:
        if "*" in pattern:
            exports.update(s for s in symbols if fnmatch.fnmatchcase(s, pattern))
        else:
            exports.add(pattern)
    manifest = json.load(open(base_path))
    manifest["exports"] = sorted(exports)
    json.dump(manifest, open(out_path, "w"), indent=2)


if __name__ == "__main__":
    main(sys.argv)
