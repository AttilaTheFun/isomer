"""Writes a link response file exporting only a module's host entries.

    export_list.py <module.wasm> <out.rsp> <prefix-or-name>...

Reads the exports of a module linked with every symbol exported
(`--export-all`) and writes `-Wl,--export-if-defined=<name>` (for the clang
driver rules_swift links through, which expands the file itself) for each
one whose name starts with one of the prefixes given (an argument ending in
`*`) or is one of the names given: the list a second link of the same
objects takes with `--gc-sections`, which then drops whatever no export
reaches. Hosts
look their entries up by name (swift_ffi's `swift_ffi_*`, the `iso_hot_*`
bridge), so the names cannot be listed while the build is planned; read
from the first link, they cannot drift from the code either.
"""

import sys


def _leb(data, i):
    result = shift = 0
    while True:
        byte = data[i]
        i += 1
        result |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return result, i


def exports(data):
    if data[:4] != b"\0asm":
        raise SystemExit("export_list: not a wasm module")
    i = 8
    while i < len(data):
        section = data[i]
        size, i = _leb(data, i + 1)
        end = i + size
        if section == 7:
            count, i = _leb(data, i)
            for _ in range(count):
                length, i = _leb(data, i)
                yield data[i:i + length].decode()
                i += length + 1  # the kind
                _, i = _leb(data, i)  # the index
        i = end


def main(argv):
    module, out, *wanted = argv[1:]
    prefixes = tuple(w[:-1] for w in wanted if w.endswith("*"))
    names = {w for w in wanted if not w.endswith("*")}
    with open(module, "rb") as f:
        found = sorted({n for n in exports(f.read()) if n in names or n.startswith(prefixes)})
    missing = names - set(found)
    if missing:
        raise SystemExit("export_list: %s does not export %s" % (module, ", ".join(sorted(missing))))
    with open(out, "w") as f:
        f.write("".join("-Wl,--export-if-defined=%s\n" % n for n in found))


if __name__ == "__main__":
    main(sys.argv)
