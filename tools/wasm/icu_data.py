"""Writes a wasm object holding a module's ICU data, less what it is told to drop.

    icu_data.py <module.wasm> <out.o> [locales=en,fr,…] <pattern>...

The full Foundation links ICU with all of its data (`icudt<N>_dat`, 34 MB in
Visor's reactor: every locale, every legacy character set). Read from a
module linked with every symbol exported (whose exports give the data's
address and the next symbol's), the package's items whose names match a
pattern (fnmatch, against the name without the package's own prefix:
`*.cnv`, `brkitr/*.dict`) are left out, and the rest is written as a
relocatable wasm object defining the same symbol. Linked ahead of the SDK's
ICU archive (whole, so it is loaded first), it is the data the program
finds; the archive's member holding the original is then never loaded. A
module without ICU gets an object defining nothing.

The package is ICU's common data format ("CmnD"): a header, a table of
contents (a count, then for each item the offsets of its name and its data,
both from the table's start), the names, then the items, each at a 16-byte
boundary. ICU finds items by a binary search of the names, which stay in
their order.

`locales=en,fr` keeps the locale data of those languages only (every
region and script of each: `fr_CA`, `zh_Hant`), with `root` and the
indexes: a locale left out formats as its nearest kept parent does, root's
when there is none. Items that are not a locale's (supplemental data,
time zones, units' definitions) all stay.
"""

import re

import fnmatch
import struct
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


def _uleb(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def _sleb(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        done = (value == 0 and not byte & 0x40) or (value == -1 and byte & 0x40)
        out.append(byte if done else byte | 0x80)
        if done:
            return bytes(out)


def _module(data):
    """The module's exported globals' addresses (by name) and its memory."""
    if data[:4] != b"\0asm":
        raise SystemExit("icu_data: not a wasm module")
    imported_globals = 0
    globals_ = []
    exports = {}
    memory = bytearray()
    i = 8
    while i < len(data):
        section = data[i]
        size, i = _leb(data, i + 1)
        end = i + size
        if section == 2:  # imports: count the globals, which come first
            count, i = _leb(data, i)
            for _ in range(count):
                for _ in range(2):
                    length, i = _leb(data, i)
                    i += length
                kind = data[i]
                i += 1
                if kind == 0:
                    _, i = _leb(data, i)
                elif kind == 1:
                    i += 1
                    flags, i = _leb(data, i)
                    _, i = _leb(data, i)
                    if flags & 1:
                        _, i = _leb(data, i)
                elif kind == 2:
                    flags, i = _leb(data, i)
                    _, i = _leb(data, i)
                    if flags & 1:
                        _, i = _leb(data, i)
                elif kind == 3:
                    imported_globals += 1
                    i += 2
        elif section == 6:  # globals: i32.const initializers are addresses
            count, i = _leb(data, i)
            for _ in range(count):
                i += 2  # the type, mutability
                opcode = data[i]
                value = None
                if opcode == 0x41:  # i32.const
                    value, i = _leb(data, i + 1)
                elif opcode in (0x42, 0x23):  # i64.const, global.get
                    _, i = _leb(data, i + 1)
                elif opcode == 0x43:  # f32.const
                    i += 5
                elif opcode == 0x44:  # f64.const
                    i += 9
                else:
                    raise SystemExit("icu_data: a global's initializer is not read (0x%02x)" % opcode)
                if data[i] != 0x0B:
                    raise SystemExit("icu_data: a global's initializer is longer than one instruction")
                globals_.append(value)
                i += 1
        elif section == 7:
            count, i = _leb(data, i)
            for _ in range(count):
                length, i = _leb(data, i)
                name = data[i:i + length].decode()
                i += length
                kind = data[i]
                index, i = _leb(data, i + 1)
                if kind == 3 and index >= imported_globals:
                    exports[name] = globals_[index - imported_globals]
        elif section == 11:
            count, i = _leb(data, i)
            for _ in range(count):
                flags, i = _leb(data, i)
                if flags != 0:
                    raise SystemExit("icu_data: passive or indexed data segments are not read")
                if data[i] != 0x41:
                    raise SystemExit("icu_data: a data segment's offset is not a constant")
                offset, i = _leb(data, i + 1)
                i += 1
                length, i = _leb(data, i)
                if len(memory) < offset + length:
                    memory.extend(bytes(offset + length - len(memory)))
                memory[offset:offset + length] = data[i:i + length]
                i += length
        i = end
    return exports, memory


def _package(exports, memory):
    names = [n for n in exports if n.startswith("icudt") and n.endswith("_dat")]
    if not names:
        return None, None
    if len(names) != 1:
        raise SystemExit("icu_data: more than one icudt*_dat export (%s)" % names)
    symbol = names[0]
    start = exports[symbol]
    following = [a for a in exports.values() if a is not None and a > start]
    end = min(following) if following else len(memory)
    return symbol, bytes(memory[start:end])


_LOCALE = re.compile(r"^([a-z]{2,3})(_[A-Za-z0-9]+)*\.res$")
_ALWAYS = {"root.res", "res_index.res", "pool.res"}


def _dropped_locale(name, languages):
    """Whether an item is locale data of a language not in `languages`."""
    if languages is None:
        return False
    base = name.split("/")[-1]
    if base in _ALWAYS:
        return False
    match = _LOCALE.match(base)
    return bool(match) and match.group(1) not in languages


def trim(package, drop, languages=None):
    header_size = struct.unpack_from("<H", package, 0)[0]
    if package[2:4] != b"\xda\x27" or package[12:16] != b"CmnD":
        raise SystemExit("icu_data: not ICU common data")
    toc = header_size
    count = struct.unpack_from("<I", package, toc)[0]
    entries = [struct.unpack_from("<II", package, toc + 4 + 8 * k) for k in range(count)]
    items = []
    for k, (name_offset, data_offset) in enumerate(entries):
        name_end = package.index(b"\0", toc + name_offset)
        name = package[toc + name_offset:name_end].decode()
        end = toc + entries[k + 1][1] if k + 1 < count else len(package)
        items.append((name, package[toc + data_offset:end]))
    kept = [(n, d) for n, d in items
            if not any(fnmatch.fnmatchcase(n.split("/", 1)[-1], p) for p in drop)
            and not _dropped_locale(n.split("/", 1)[-1], languages)]

    names = b"".join(n.encode() + b"\0" for n, _ in kept)
    table = 4 + 8 * len(kept)
    first = table + len(names)
    first += -(header_size + first) % 16
    name_offsets, data_offsets, body = [], [], bytearray()
    at = table
    for n, _ in kept:
        name_offsets.append(at)
        at += len(n) + 1
    for _, d in kept:
        pad = -(header_size + first + len(body)) % 16
        body.extend(bytes(pad))
        data_offsets.append(first + len(body))
        body.extend(d)
    out = bytearray(package[:header_size])
    out += struct.pack("<I", len(kept))
    for no, do in zip(name_offsets, data_offsets):
        out += struct.pack("<II", no, do)
    out += names
    out += bytes(header_size + first - len(out))
    out += body
    return bytes(out), len(items) - len(kept)


def _section(kind, payload):
    return bytes([kind]) + _uleb(len(payload)) + payload


def _name(text):
    raw = text.encode()
    return _uleb(len(raw)) + raw


def empty_object_file():
    """A relocatable wasm object defining nothing (a module without ICU)."""
    return b"\0asm\x01\0\0\0" + _section(0, _name("linking") + _uleb(2))


def object_file(symbol, package):
    """A relocatable wasm object (as clang writes one) with one read-only
    data segment, `.rodata.<symbol>`, and one data symbol over it."""
    imports = _uleb(1) + _name("env") + _name("__linear_memory") + b"\x02\x00\x00"
    datacount = _uleb(1)
    data = _uleb(1) + b"\x00\x41\x00\x0b" + _uleb(len(package)) + package
    symbols = _uleb(1) + b"\x01" + _uleb(0) + _name(symbol) + _uleb(0) + _uleb(0) + _uleb(len(package))
    segments = _uleb(1) + _name(".rodata." + symbol) + _uleb(4) + _uleb(0)
    linking = (_name("linking") + _uleb(2)
               + bytes([8]) + _uleb(len(symbols)) + symbols
               + bytes([5]) + _uleb(len(segments)) + segments)
    return (b"\0asm\x01\0\0\0"
            + _section(2, imports)
            + _section(12, datacount)
            + _section(11, data)
            + _section(0, linking))


def main(argv):
    module, out, *drop = argv[1:]
    languages = None
    for argument in list(drop):
        if argument.startswith("locales="):
            languages = set(argument[len("locales="):].split(","))
            drop.remove(argument)
    with open(module, "rb") as f:
        exports, memory = _module(f.read())
    symbol, package = _package(exports, memory)
    if symbol is None:
        with open(out, "wb") as f:
            f.write(empty_object_file())
        print("icu_data: %s has no ICU data" % module)
        return
    trimmed, dropped = trim(package, drop, languages)
    with open(out, "wb") as f:
        f.write(object_file(symbol, trimmed))
    print("icu_data: %s %.1f MB -> %.1f MB (%d items dropped)"
          % (symbol, len(package) / 1e6, len(trimmed) / 1e6, dropped))


if __name__ == "__main__":
    main(sys.argv)
